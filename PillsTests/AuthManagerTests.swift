import XCTest
import SwiftData
@testable import Pills

@MainActor
private final class MockAppleSignInProvider: AppleSignInProvider {
    var results: [Result<AppleSignInPayload, Error>]
    private(set) var signInCallCount = 0
    private var pauseContinuation: CheckedContinuation<Void, Never>?
    private(set) var isPaused = false
    private var shouldPause = false

    init(results: [Result<AppleSignInPayload, Error>]) {
        self.results = results
    }

    func pauseNextSignIn() {
        shouldPause = true
    }

    func resumeSignIn() {
        isPaused = false
        pauseContinuation?.resume()
        pauseContinuation = nil
    }

    func signIn() async throws -> AppleSignInPayload {
        signInCallCount += 1
        if shouldPause {
            shouldPause = false
            isPaused = true
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                pauseContinuation = continuation
            }
        }
        guard !results.isEmpty else { throw AuthError.invalidCredential }
        return try results.removeFirst().get()
    }
}

private actor MockAuthAPI: AuthAPIProtocol {
    private var exchangeResults: [Result<AuthResponse, Error>]
    private var currentUserResult: Result<AuthUserResponse, Error>
    private var unauthorizedHandler: (@Sendable (String) async -> Void)?
    private var currentToken: String?
    private var shouldPauseCurrentUserFetch = false
    private var currentUserFetchContinuation: CheckedContinuation<Void, Never>?
    private(set) var isCurrentUserFetchPaused = false
    private var shouldPauseConditionalClear = false
    private var conditionalClearContinuation: CheckedContinuation<Void, Never>?
    private(set) var isConditionalClearPaused = false
    private(set) var configuredTokens: [String?] = []
    private(set) var exchangeRequests: [AppleAuthRequest] = []
    private(set) var currentUserCallCount = 0

    init(
        exchangeResults: [Result<AuthResponse, Error>] = [],
        currentUserResult: Result<AuthUserResponse, Error> = .failure(APIError.unauthorized)
    ) {
        self.exchangeResults = exchangeResults
        self.currentUserResult = currentUserResult
    }

    func exchangeAppleCredential(_ request: AppleAuthRequest) async throws -> AuthResponse {
        exchangeRequests.append(request)
        guard !exchangeResults.isEmpty else { throw APIError.invalidResponse }
        return try exchangeResults.removeFirst().get()
    }

    func fetchCurrentUser() async throws -> AuthUserResponse {
        currentUserCallCount += 1
        let result = currentUserResult
        if shouldPauseCurrentUserFetch {
            shouldPauseCurrentUserFetch = false
            isCurrentUserFetchPaused = true
            await withCheckedContinuation { continuation in
                currentUserFetchContinuation = continuation
            }
            isCurrentUserFetchPaused = false
        }
        return try result.get()
    }

    func pauseNextCurrentUserFetch() {
        shouldPauseCurrentUserFetch = true
    }

    func resumeCurrentUserFetch() {
        currentUserFetchContinuation?.resume()
        currentUserFetchContinuation = nil
    }

    func setAuthToken(_ token: String?) async {
        currentToken = token
        configuredTokens.append(token)
    }

    func clearAuthToken(ifMatching token: String) async -> Bool {
        guard currentToken == token else { return false }
        currentToken = nil
        configuredTokens.append(nil)
        if shouldPauseConditionalClear {
            shouldPauseConditionalClear = false
            isConditionalClearPaused = true
            await withCheckedContinuation { continuation in
                conditionalClearContinuation = continuation
            }
            isConditionalClearPaused = false
        }
        return true
    }

    func pauseNextConditionalClear() {
        shouldPauseConditionalClear = true
    }

    func resumeConditionalClear() {
        conditionalClearContinuation?.resume()
        conditionalClearContinuation = nil
    }

    func setUnauthorizedHandler(_ handler: (@Sendable (String) async -> Void)?) async {
        unauthorizedHandler = handler
    }

    func triggerUnauthorized(token: String? = nil) async {
        guard let rejectedToken = token ?? currentToken else { return }
        await unauthorizedHandler?(rejectedToken)
    }

    func lastConfiguredToken() -> String? {
        configuredTokens.last ?? nil
    }

    func recordedExchangeRequests() -> [AppleAuthRequest] {
        exchangeRequests
    }

    func recordedCurrentUserCallCount() -> Int {
        currentUserCallCount
    }
}

private enum TokenStoreStubError: Error {
    case loadFailed
    case saveFailed
    case removeFailed
}

private enum CacheStubError: Error {
    case deletionFailed
}

@MainActor
private final class ControllableCacheDeleter {
    var error: Error?
    var deletesBeforeThrow = false

    func delete(in modelContext: ModelContext) throws {
        if deletesBeforeThrow {
            for session in try modelContext.fetch(FetchDescriptor<Session>()) {
                modelContext.delete(session)
            }
            for user in try modelContext.fetch(FetchDescriptor<User>()) {
                modelContext.delete(user)
            }
        }
        if let error { throw error }
    }
}

@MainActor
private final class ControllableAuthTokenStore: AuthTokenStore {
    var token: String?
    var loadError: Error?
    var removeError: Error?
    var loadErrorOnCall: Int?
    var saveErrorOnCall: Int?
    private(set) var loadCallCount = 0
    private(set) var saveCallCount = 0

    init(token: String? = nil, loadError: Error? = nil, removeError: Error? = nil) {
        self.token = token
        self.loadError = loadError
        self.removeError = removeError
    }

    func loadToken() throws -> String? {
        loadCallCount += 1
        if loadCallCount == loadErrorOnCall { throw TokenStoreStubError.loadFailed }
        if let loadError { throw loadError }
        return token
    }

    func saveToken(_ token: String) throws {
        saveCallCount += 1
        if saveCallCount == saveErrorOnCall { throw TokenStoreStubError.saveFailed }
        self.token = token
    }

    func removeToken() throws {
        if let removeError { throw removeError }
        token = nil
    }
}

@MainActor
final class AuthManagerTests: XCTestCase {
    private var container: ModelContainer!
    private var tokenStore: InMemoryAuthTokenStore!

    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(
            for: Guide.self, Session.self, Conversation.self, ChatMessage.self, User.self,
            configurations: config
        )
        tokenStore = InMemoryAuthTokenStore()
    }

    func testInitialStateIsRestoring() {
        let manager = makeManager()

        XCTAssertEqual(manager.state, .restoring)
        XCTAssertNil(manager.currentUser)
        XCTAssertFalse(manager.isSigningIn)
    }

    func testSuccessfulAppleSignInStoresBackendTokenAndUpsertsOneBackendUser() async throws {
        let response = authResponse(id: "backend-user", username: "alice", displayName: "Alice")
        let provider = MockAppleSignInProvider(results: [.success(applePayload())])
        let api = MockAuthAPI(exchangeResults: [.success(response)])
        let manager = makeManager(provider: provider, api: api)
        try await manager.configure(modelContext: container.mainContext)

        try await manager.signInWithApple()

        XCTAssertEqual(manager.state, .signedIn)
        XCTAssertEqual(manager.currentUser?.id, "backend-user")
        XCTAssertEqual(manager.currentUser?.displayName, "Alice")
        XCTAssertEqual(try tokenStore.loadToken(), "backend-token")
        let configuredToken = await api.lastConfiguredToken()
        XCTAssertEqual(configuredToken, "backend-token")
        let requests = await api.recordedExchangeRequests()
        XCTAssertEqual(requests.first?.identityToken, "identity-token")
        XCTAssertEqual(requests.first?.authorizationCode, "authorization-code")
        XCTAssertEqual(requests.first?.givenName, "Alice")
        XCTAssertEqual(requests.first?.familyName, "Example")
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<User>()).count, 1)
    }

    func testRepeatedSignInUpdatesSameBackendUserWithoutDuplicates() async throws {
        let first = authResponse(id: "backend-user", username: "alice", displayName: "Alice")
        let second = authResponse(id: "backend-user", username: "alice-2", displayName: "Alice Updated")
        let provider = MockAppleSignInProvider(results: [.success(applePayload()), .success(applePayload())])
        let api = MockAuthAPI(exchangeResults: [.success(first), .success(second)])
        let manager = makeManager(provider: provider, api: api)
        try await manager.configure(modelContext: container.mainContext)

        try await manager.signInWithApple()
        try await manager.signInWithApple()

        let users = try container.mainContext.fetch(FetchDescriptor<User>())
        XCTAssertEqual(users.count, 1)
        XCTAssertEqual(users.first?.username, "alice-2")
        XCTAssertEqual(users.first?.displayName, "Alice Updated")
    }

    func testSignInAsDifferentBackendUserClearsPriorOwnedCachesButPreservesGuides() async throws {
        let first = authResponse(id: "user-a", username: "alice", displayName: "Alice")
        let second = authResponse(id: "user-b", username: "bob", displayName: "Bob")
        let provider = MockAppleSignInProvider(results: [.success(applePayload()), .success(applePayload())])
        let api = MockAuthAPI(exchangeResults: [.success(first), .success(second)])
        let manager = makeManager(provider: provider, api: api)
        try await manager.configure(modelContext: container.mainContext)
        try await manager.signInWithApple()

        let guide = Guide(
            id: "guide", slug: "calm", category: "breathing", title: "Calm",
            summary: "", sortOrder: 0, isActive: true, configJSON: "{}"
        )
        let message = ChatMessage(id: "message", role: "user", content: "hello", createdAt: Date())
        let conversation = Conversation(id: "conversation", createdAt: Date(), updatedAt: Date(), messages: [message])
        container.mainContext.insert(guide)
        container.mainContext.insert(Session(id: "session", guideSlug: "calm", startedAt: Date()))
        container.mainContext.insert(conversation)
        try container.mainContext.save()

        try await manager.signInWithApple()

        XCTAssertEqual(manager.currentUser?.id, "user-b")
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<User>()).map(\.id), ["user-b"])
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<Session>()).isEmpty)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<Conversation>()).isEmpty)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<ChatMessage>()).isEmpty)
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<Guide>()).count, 1)
    }

    func testRestoreSuccessValidatesTokenAndUpsertsExactlyOneUser() async throws {
        try tokenStore.saveToken(jwt(subject: "backend-user"))
        container.mainContext.insert(User(id: "stale", username: "stale"))
        container.mainContext.insert(User(id: "backend-user", username: "old"))
        try container.mainContext.save()
        let api = MockAuthAPI(currentUserResult: .success(authUser(id: "backend-user")))
        let manager = makeManager(api: api)

        try await manager.configure(modelContext: container.mainContext)

        XCTAssertEqual(manager.state, .signedIn)
        XCTAssertEqual(manager.currentUser?.id, "backend-user")
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<User>()).count, 1)
        let currentUserCallCount = await api.recordedCurrentUserCallCount()
        XCTAssertEqual(currentUserCallCount, 1)
    }

    func testOldRestoreUnauthorizedDoesNotInvalidateNewerSignIn() async throws {
        let oldToken = jwt(subject: "user-a")
        try tokenStore.saveToken(oldToken)
        let provider = MockAppleSignInProvider(results: [.success(applePayload())])
        let api = MockAuthAPI(
            exchangeResults: [.success(authResponse(id: "user-b", username: "bob", displayName: "Bob"))],
            currentUserResult: .failure(APIError.unauthorized)
        )
        await api.pauseNextCurrentUserFetch()
        let manager = makeManager(provider: provider, api: api)

        let restore = Task {
            try await manager.configure(modelContext: container.mainContext)
        }
        while await !api.isCurrentUserFetchPaused {
            await Task.yield()
        }

        try await manager.signInWithApple()
        container.mainContext.insert(Session(id: "user-b-session", guideSlug: "calm", startedAt: Date()))
        try container.mainContext.save()
        await api.resumeCurrentUserFetch()
        try await restore.value

        XCTAssertEqual(manager.state, .signedIn)
        XCTAssertEqual(manager.currentUser?.id, "user-b")
        XCTAssertEqual(try tokenStore.loadToken(), "backend-token")
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<User>()).map(\.id), ["user-b"])
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<Session>()).map(\.id), ["user-b-session"])
    }

    func testRestoreDifferentBackendUserClearsPriorOwnedCachesButPreservesGuides() async throws {
        try tokenStore.saveToken(jwt(subject: "user-b"))
        try seedAllCaches()
        let api = MockAuthAPI(currentUserResult: .success(authUser(id: "user-b")))
        let manager = makeManager(api: api)

        try await manager.configure(modelContext: container.mainContext)

        XCTAssertEqual(manager.currentUser?.id, "user-b")
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<User>()).map(\.id), ["user-b"])
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<Session>()).isEmpty)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<Conversation>()).isEmpty)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<ChatMessage>()).isEmpty)
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<Guide>()).count, 1)
    }

    func testRestoreTransientFailureRetainsTokenAndMatchingCachedUser() async throws {
        let token = jwt(subject: "backend-user")
        try tokenStore.saveToken(token)
        container.mainContext.insert(User(id: "backend-user", username: "cached"))
        try container.mainContext.save()
        let api = MockAuthAPI(currentUserResult: .failure(APIError.timeout))
        let manager = makeManager(api: api)

        try await manager.configure(modelContext: container.mainContext)

        XCTAssertEqual(manager.state, .signedIn)
        XCTAssertEqual(manager.currentUser?.id, "backend-user")
        XCTAssertEqual(try tokenStore.loadToken(), token)
    }

    func testRestoreNetworkFailureRejectsExpiredCachedToken() async throws {
        let token = jwt(subject: "backend-user", expiresAt: Date().addingTimeInterval(-60))
        try tokenStore.saveToken(token)
        container.mainContext.insert(User(id: "backend-user", username: "cached"))
        try container.mainContext.save()
        let api = MockAuthAPI(currentUserResult: .failure(APIError.networkUnavailable))
        let manager = makeManager(api: api)

        try await manager.configure(modelContext: container.mainContext)

        XCTAssertEqual(manager.state, .signedOut)
        XCTAssertNil(manager.currentUser)
        XCTAssertNil(try tokenStore.loadToken())
    }

    func testRestoreServerFailureDoesNotUseOfflineCache() async {
        for expectedError in [
            APIError.httpError(statusCode: 429, body: "rate limited"),
            APIError.httpError(statusCode: 503, body: "unavailable"),
        ] {
            let isolatedContainer = try! ModelContainer(
                for: Guide.self, Session.self, Conversation.self, ChatMessage.self, User.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
            let isolatedStore = InMemoryAuthTokenStore(token: jwt(subject: "backend-user"))
            isolatedContainer.mainContext.insert(User(id: "backend-user", username: "cached"))
            try! isolatedContainer.mainContext.save()
            let manager = makeManager(
                api: MockAuthAPI(currentUserResult: .failure(expectedError)),
                tokenStore: isolatedStore
            )

            do {
                try await manager.configure(modelContext: isolatedContainer.mainContext)
                XCTFail("Expected server failure to propagate")
            } catch {
                XCTAssertEqual(error as? APIError, expectedError)
            }

            XCTAssertEqual(manager.state, .signedOut)
            XCTAssertNil(manager.currentUser)
            XCTAssertNil(try? isolatedStore.loadToken())
        }
    }

    func testRestoreTokenLoadFailureLeavesRecoverableNonRestoringState() async {
        let failingStore = ControllableAuthTokenStore(loadError: TokenStoreStubError.loadFailed)
        let manager = makeManager(tokenStore: failingStore)

        do {
            try await manager.configure(modelContext: container.mainContext)
            XCTFail("Expected token load failure")
        } catch {
            XCTAssertTrue(error is TokenStoreStubError)
        }

        XCTAssertEqual(manager.state, .failed)
        XCTAssertNil(manager.currentUser)
        XCTAssertNotNil(manager.authErrorMessage)
    }

    func testRetryAfterRestoreFailureReturnsToRecoverableFailureState() async {
        let failingStore = ControllableAuthTokenStore(loadError: TokenStoreStubError.loadFailed)
        let manager = makeManager(tokenStore: failingStore)
        try? await manager.configure(modelContext: container.mainContext)

        do {
            try await manager.restoreSession()
            XCTFail("Expected token load failure")
        } catch {
            XCTAssertTrue(error is TokenStoreStubError)
        }

        XCTAssertEqual(manager.state, .failed)
        XCTAssertNotNil(manager.authErrorMessage)
    }

    func testRestoreTransientFailureClearsUnsafeMismatchedCacheAndToken() async throws {
        let token = jwt(subject: "different-user")
        try tokenStore.saveToken(token)
        container.mainContext.insert(User(id: "cached-user", username: "cached"))
        container.mainContext.insert(Session(id: "session", guideSlug: "calm", startedAt: Date()))
        try container.mainContext.save()
        let api = MockAuthAPI(currentUserResult: .failure(APIError.networkUnavailable))
        let manager = makeManager(api: api)

        try await manager.configure(modelContext: container.mainContext)

        XCTAssertEqual(manager.state, .signedOut)
        XCTAssertNil(manager.currentUser)
        XCTAssertNil(try tokenStore.loadToken())
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<User>()).isEmpty)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<Session>()).isEmpty)
    }

    func testRestoreWithoutTokenClearsStaleOwnedCaches() async throws {
        try seedAllCaches()
        let manager = makeManager()

        try await manager.configure(modelContext: container.mainContext)

        try assertSignedOutCachesCleared(manager)
    }

    func testRestoreUnauthorizedClearsTokenAndOwnedCachesButPreservesGuides() async throws {
        try tokenStore.saveToken(jwt(subject: "backend-user"))
        try seedAllCaches()
        let api = MockAuthAPI(currentUserResult: .failure(APIError.unauthorized))
        let manager = makeManager(api: api)

        try await manager.configure(modelContext: container.mainContext)

        try assertSignedOutCachesCleared(manager)
    }

    func testSignOutClearsTokenClientAuthAndOwnedCachesButPreservesGuides() async throws {
        try tokenStore.saveToken(jwt(subject: "backend-user"))
        try seedAllCaches()
        let api = MockAuthAPI(currentUserResult: .success(authUser(id: "backend-user")))
        let manager = makeManager(api: api)
        try await manager.configure(modelContext: container.mainContext)

        try await manager.signOut()

        try assertSignedOutCachesCleared(manager)
        let configuredToken = await api.lastConfiguredToken()
        XCTAssertNil(configuredToken)
    }

    func testFailedSignInReconfiguresStillValidPreviousToken() async throws {
        let oldToken = jwt(subject: "backend-user")
        try tokenStore.saveToken(oldToken)
        let provider = MockAppleSignInProvider(results: [.failure(AuthError.invalidCredential)])
        let api = MockAuthAPI(currentUserResult: .success(authUser(id: "backend-user")))
        let manager = makeManager(provider: provider, api: api)
        try await manager.configure(modelContext: container.mainContext)

        do {
            try await manager.signInWithApple()
            XCTFail("Expected sign-in failure")
        } catch {
            XCTAssertEqual(error as? AuthError, .invalidCredential)
        }

        XCTAssertEqual(manager.state, .signedIn)
        XCTAssertEqual(manager.currentUser?.id, "backend-user")
        XCTAssertEqual(try tokenStore.loadToken(), oldToken)
        let configuredTokens = await api.configuredTokens
        XCTAssertEqual(configuredTokens, [oldToken, oldToken])
    }

    func testFailedSignInRollbackRestoresStagedCacheChanges() async throws {
        let oldToken = jwt(subject: "user-a")
        try tokenStore.saveToken(oldToken)
        container.mainContext.insert(User(id: "user-a", username: "alice"))
        container.mainContext.insert(Session(id: "user-a-session", guideSlug: "calm", startedAt: Date()))
        try container.mainContext.save()
        let cacheDeleter = ControllableCacheDeleter()
        let provider = MockAppleSignInProvider(results: [.success(applePayload())])
        let api = MockAuthAPI(
            exchangeResults: [.success(authResponse(id: "user-b", username: "bob", displayName: "Bob"))],
            currentUserResult: .success(authUser(id: "user-a"))
        )
        let manager = makeManager(
            provider: provider,
            api: api,
            cacheDeleter: cacheDeleter.delete
        )
        try await manager.configure(modelContext: container.mainContext)
        cacheDeleter.deletesBeforeThrow = true
        cacheDeleter.error = CacheStubError.deletionFailed

        do {
            try await manager.signInWithApple()
            XCTFail("Expected cache deletion failure")
        } catch {
            XCTAssertTrue(error is CacheStubError)
        }

        XCTAssertEqual(manager.state, .signedIn)
        XCTAssertEqual(manager.currentUser?.id, "user-a")
        XCTAssertEqual(try tokenStore.loadToken(), oldToken)
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<User>()).map(\.id), ["user-a"])
        XCTAssertEqual(
            try container.mainContext.fetch(FetchDescriptor<Session>()).map(\.id),
            ["user-a-session"]
        )
        let configuredToken = await api.lastConfiguredToken()
        XCTAssertEqual(configuredToken, oldToken)
    }

    func testPreTokenSignInFailureWithInvalidationErrorDoesNotLeaveSigningIn() async throws {
        let store = ControllableAuthTokenStore()
        let provider = MockAppleSignInProvider(results: [.failure(AuthError.invalidCredential)])
        let api = MockAuthAPI()
        let manager = makeManager(provider: provider, api: api, tokenStore: store)
        try await manager.configure(modelContext: container.mainContext)
        store.removeError = TokenStoreStubError.removeFailed

        do {
            try await manager.signInWithApple()
            XCTFail("Expected sign-in failure")
        } catch {
            // After fix: inner rollback failure produces cleanupFailed; before fix: removeFailed escapes
        }

        XCTAssertNotEqual(manager.state, .signingIn)
        XCTAssertEqual(manager.state, .failed)
        XCTAssertNil(manager.currentUser)
        XCTAssertNotNil(manager.authErrorMessage)
    }

    func testPreTokenSignInRollbackLoadFailureDoesNotLeaveSigningIn() async throws {
        let oldToken = jwt(subject: "backend-user")
        let store = ControllableAuthTokenStore(token: oldToken)
        let provider = MockAppleSignInProvider(results: [.failure(AuthError.invalidCredential)])
        let api = MockAuthAPI(currentUserResult: .success(authUser(id: "backend-user")))
        let manager = makeManager(provider: provider, api: api, tokenStore: store)
        try await manager.configure(modelContext: container.mainContext)
        // loadToken calls: 1=configure/restore, 2=signInWithApple/previousToken, 3=catch/loadToken
        store.loadErrorOnCall = store.loadCallCount + 2

        do {
            try await manager.signInWithApple()
            XCTFail("Expected sign-in failure")
        } catch {
            // After fix: cleanupFailed; before fix: loadFailed escapes
        }

        XCTAssertNotEqual(manager.state, .signingIn)
        XCTAssertEqual(manager.state, .failed)
        XCTAssertNil(manager.currentUser)
        XCTAssertNotNil(manager.authErrorMessage)
    }

    func testFailedSignInRollbackFailureRevokesRuntimeSessionAndHidesUser() async throws {
        let oldToken = jwt(subject: "user-a")
        let store = ControllableAuthTokenStore(token: oldToken)
        let cacheDeleter = ControllableCacheDeleter()
        let provider = MockAppleSignInProvider(results: [.success(applePayload())])
        let api = MockAuthAPI(
            exchangeResults: [.success(authResponse(id: "user-b", username: "bob", displayName: "Bob"))],
            currentUserResult: .success(authUser(id: "user-a"))
        )
        let manager = makeManager(
            provider: provider,
            api: api,
            tokenStore: store,
            cacheDeleter: cacheDeleter.delete
        )
        try await manager.configure(modelContext: container.mainContext)
        cacheDeleter.error = CacheStubError.deletionFailed
        store.saveErrorOnCall = 2
        store.removeError = TokenStoreStubError.removeFailed

        do {
            try await manager.signInWithApple()
            XCTFail("Expected rollback failure")
        } catch {
            guard case .cleanupFailed = error as? AuthError else {
                return XCTFail("Expected cleanup failure, got \(error)")
            }
        }

        XCTAssertEqual(manager.state, .failed)
        XCTAssertNil(manager.currentUser)
        XCTAssertEqual(store.token, "backend-token")
        let configuredToken = await api.lastConfiguredToken()
        XCTAssertNil(configuredToken)
        XCTAssertNotNil(manager.authErrorMessage)
    }

    func testSignOutTokenDeletionFailureDoesNotPresentSignedOutOrClearActiveSession() async throws {
        let token = jwt(subject: "backend-user")
        let failingStore = ControllableAuthTokenStore(token: token)
        try seedAllCaches()
        let api = MockAuthAPI(currentUserResult: .success(authUser(id: "backend-user")))
        let manager = makeManager(api: api, tokenStore: failingStore)
        try await manager.configure(modelContext: container.mainContext)
        failingStore.removeError = TokenStoreStubError.removeFailed

        do {
            try await manager.signOut()
            XCTFail("Expected token deletion failure")
        } catch {
            XCTAssertTrue(error is TokenStoreStubError)
        }

        XCTAssertEqual(manager.state, .signedIn)
        XCTAssertEqual(manager.currentUser?.id, "backend-user")
        XCTAssertEqual(failingStore.token, token)
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<User>()).count, 1)
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<Session>()).count, 1)
        XCTAssertNotNil(manager.authErrorMessage)
    }

    func testSignOutCacheDeletionFailureHidesRevokedSession() async throws {
        let token = jwt(subject: "backend-user")
        let store = ControllableAuthTokenStore(token: token)
        let cacheDeleter = ControllableCacheDeleter()
        try seedAllCaches()
        let api = MockAuthAPI(currentUserResult: .success(authUser(id: "backend-user")))
        let manager = makeManager(
            api: api,
            tokenStore: store,
            cacheDeleter: cacheDeleter.delete
        )
        try await manager.configure(modelContext: container.mainContext)
        cacheDeleter.error = CacheStubError.deletionFailed

        do {
            try await manager.signOut()
            XCTFail("Expected cache deletion failure")
        } catch {
            XCTAssertTrue(error is CacheStubError)
        }

        XCTAssertEqual(manager.state, .failed)
        XCTAssertNil(manager.currentUser)
        XCTAssertNil(store.token)
        let configuredToken = await api.lastConfiguredToken()
        XCTAssertNil(configuredToken)
        XCTAssertNotNil(manager.authErrorMessage)
    }

    func testUnauthorizedCallbackClearsSessionOnceConfigured() async throws {
        try tokenStore.saveToken(jwt(subject: "backend-user"))
        try seedAllCaches()
        let api = MockAuthAPI(currentUserResult: .success(authUser(id: "backend-user")))
        let manager = makeManager(api: api)
        try await manager.configure(modelContext: container.mainContext)

        await api.triggerUnauthorized()

        try assertSignedOutCachesCleared(manager)
    }

    func testUnauthorizedTokenDeletionFailureEntersFailedStateAndHidesOwnedCaches() async throws {
        let token = jwt(subject: "backend-user")
        let failingStore = ControllableAuthTokenStore(token: token)
        try seedAllCaches()
        let api = MockAuthAPI(currentUserResult: .success(authUser(id: "backend-user")))
        let manager = makeManager(api: api, tokenStore: failingStore)
        try await manager.configure(modelContext: container.mainContext)
        failingStore.removeError = TokenStoreStubError.removeFailed

        await api.triggerUnauthorized()

        XCTAssertEqual(manager.state, .failed)
        XCTAssertNil(manager.currentUser)
        XCTAssertEqual(failingStore.token, token)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<User>()).isEmpty)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<Session>()).isEmpty)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<Conversation>()).isEmpty)
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<Guide>()).count, 1)
        let configuredToken = await api.lastConfiguredToken()
        XCTAssertNil(configuredToken)
        XCTAssertNotNil(manager.authErrorMessage)
    }

    func testUnauthorizedPostRevocationKeychainReadFailureEntersFailedState() async throws {
        let token = jwt(subject: "backend-user")
        let store = ControllableAuthTokenStore(token: token)
        try seedAllCaches()
        let api = MockAuthAPI(currentUserResult: .success(authUser(id: "backend-user")))
        let manager = makeManager(api: api, tokenStore: store)
        try await manager.configure(modelContext: container.mainContext)
        store.loadErrorOnCall = store.loadCallCount + 2

        await api.triggerUnauthorized()

        XCTAssertEqual(manager.state, .failed)
        XCTAssertNil(manager.currentUser)
        XCTAssertNil(store.token)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<User>()).isEmpty)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<Session>()).isEmpty)
        let configuredToken = await api.lastConfiguredToken()
        XCTAssertNil(configuredToken)
    }

    func testFailedSignInDoesNotRestoreUserWhoseTokenWasRevokedByOlderUnauthorizedCleanup() async throws {
        let oldToken = jwt(subject: "user-a")
        let store = ControllableAuthTokenStore(token: oldToken)
        let provider = MockAppleSignInProvider(results: [.failure(AuthError.invalidCredential)])
        let api = MockAuthAPI(currentUserResult: .success(authUser(id: "user-a")))
        let manager = makeManager(provider: provider, api: api, tokenStore: store)
        try await manager.configure(modelContext: container.mainContext)
        container.mainContext.insert(Session(id: "user-a-session", guideSlug: "calm", startedAt: Date()))
        try container.mainContext.save()
        await api.pauseNextConditionalClear()

        let oldUnauthorized = Task {
            await api.triggerUnauthorized(token: oldToken)
        }
        while await !api.isConditionalClearPaused {
            await Task.yield()
        }

        do {
            try await manager.signInWithApple()
            XCTFail("Expected sign-in failure")
        } catch {
            XCTAssertEqual(error as? AuthError, .invalidCredential)
        }
        await api.resumeConditionalClear()
        await oldUnauthorized.value

        XCTAssertEqual(manager.state, .signedOut)
        XCTAssertNil(manager.currentUser)
        XCTAssertNil(store.token)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<User>()).isEmpty)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<Session>()).isEmpty)
        let configuredToken = await api.lastConfiguredToken()
        XCTAssertNil(configuredToken)
    }

    func testFailedSignInDoesNotRestoreTokenRevokedDuringSigningInWindow() async throws {
        let oldToken = jwt(subject: "user-a")
        let store = ControllableAuthTokenStore(token: oldToken)
        let provider = MockAppleSignInProvider(results: [.failure(AuthError.invalidCredential)])
        let api = MockAuthAPI(currentUserResult: .success(authUser(id: "user-a")))
        let manager = makeManager(provider: provider, api: api, tokenStore: store)
        try await manager.configure(modelContext: container.mainContext)
        container.mainContext.insert(Session(id: "user-a-session", guideSlug: "calm", startedAt: Date()))
        try container.mainContext.save()
        provider.pauseNextSignIn()

        let signInTask = Task { try await manager.signInWithApple() }
        while !provider.isPaused {
            await Task.yield()
        }

        // 401 arrives while state == .signingIn
        await api.triggerUnauthorized(token: oldToken)

        provider.resumeSignIn()
        do {
            try await signInTask.value
            XCTFail("Expected sign-in failure")
        } catch {
            // Original error or cleanupFailed
        }

        // Must NOT restore .signedIn with a server-revoked token
        XCTAssertNotEqual(manager.state, .signedIn)
        XCTAssertNil(manager.currentUser)
    }

    func testFailedOldUnauthorizedCleanupDoesNotClearNewerSignedInSession() async throws {
        let oldToken = jwt(subject: "user-a")
        let store = ControllableAuthTokenStore(token: oldToken)
        let provider = MockAppleSignInProvider(results: [.success(applePayload())])
        let api = MockAuthAPI(
            exchangeResults: [.success(authResponse(id: "user-b", username: "bob", displayName: "Bob"))],
            currentUserResult: .success(authUser(id: "user-a"))
        )
        let manager = makeManager(provider: provider, api: api, tokenStore: store)
        try await manager.configure(modelContext: container.mainContext)
        await api.pauseNextConditionalClear()
        store.loadError = TokenStoreStubError.loadFailed

        let oldUnauthorized = Task {
            await api.triggerUnauthorized(token: oldToken)
        }
        while await !api.isConditionalClearPaused {
            await Task.yield()
        }

        store.loadError = nil
        try await manager.signInWithApple()
        container.mainContext.insert(Session(id: "user-b-session", guideSlug: "calm", startedAt: Date()))
        try container.mainContext.save()
        await api.resumeConditionalClear()
        await oldUnauthorized.value

        XCTAssertEqual(manager.state, .signedIn)
        XCTAssertEqual(manager.currentUser?.id, "user-b")
        XCTAssertEqual(store.token, "backend-token")
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<User>()).map(\.id), ["user-b"])
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<Session>()).map(\.id), ["user-b-session"])
    }

    private func makeManager(
        provider: AppleSignInProvider? = nil,
        api: AuthAPIProtocol = MockAuthAPI(),
        tokenStore: AuthTokenStore? = nil,
        cacheDeleter: (@MainActor (ModelContext) throws -> Void)? = nil
    ) -> AuthManager {
        AuthManager(
            appleSignInProvider: provider ?? MockAppleSignInProvider(results: []),
            api: api,
            tokenStore: tokenStore ?? self.tokenStore,
            cacheDeleter: cacheDeleter
        )
    }

    private func applePayload() -> AppleSignInPayload {
        AppleSignInPayload(
            identityToken: "identity-token",
            authorizationCode: "authorization-code",
            userIdentifier: "apple-user",
            email: "alice@example.com",
            displayName: "Alice Example",
            givenName: "Alice",
            familyName: "Example"
        )
    }

    private func authResponse(id: String, username: String, displayName: String) -> AuthResponse {
        AuthResponse(
            token: "backend-token",
            id: id,
            username: username,
            displayName: displayName,
            isAdmin: false,
            authProvider: "apple"
        )
    }

    private func authUser(id: String) -> AuthUserResponse {
        AuthUserResponse(
            id: id,
            username: "alice",
            displayName: "Alice",
            isAdmin: false,
            authProvider: "apple"
        )
    }

    private func jwt(
        subject: String,
        expiresAt: Date = Date().addingTimeInterval(3_600)
    ) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [
            "sub": subject,
            "exp": Int(expiresAt.timeIntervalSince1970),
        ])
        let payload = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(payload).signature"
    }

    private func seedAllCaches() throws {
        let guide = Guide(
            id: "guide", slug: "calm", category: "breathing", title: "Calm",
            summary: "", sortOrder: 0, isActive: true, configJSON: "{}"
        )
        let message = ChatMessage(id: "message", role: "user", content: "hello", createdAt: Date())
        let conversation = Conversation(id: "conversation", createdAt: Date(), updatedAt: Date(), messages: [message])
        container.mainContext.insert(guide)
        container.mainContext.insert(Session(id: "session", guideSlug: "calm", startedAt: Date()))
        container.mainContext.insert(conversation)
        container.mainContext.insert(User(id: "backend-user", username: "alice"))
        try container.mainContext.save()
    }

    private func assertSignedOutCachesCleared(_ manager: AuthManager) throws {
        XCTAssertEqual(manager.state, .signedOut)
        XCTAssertNil(manager.currentUser)
        XCTAssertNil(try tokenStore.loadToken())
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<User>()).isEmpty)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<Session>()).isEmpty)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<Conversation>()).isEmpty)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<ChatMessage>()).isEmpty)
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<Guide>()).count, 1)
    }
}
