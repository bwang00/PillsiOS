import Combine
import Foundation
import SwiftData

@MainActor
final class AuthManager: ObservableObject {
    enum State: Equatable {
        case restoring
        case signedOut
        case signingIn
        case signedIn
        case failed
    }

    @Published private(set) var currentUser: User?
    @Published private(set) var state: State = .restoring
    @Published private(set) var authErrorMessage: String?

    var isSigningIn: Bool { state == .signingIn }

    private let appleSignInProvider: AppleSignInProvider
    private let api: AuthAPIProtocol
    private let tokenStore: AuthTokenStore
    private let cacheDeleter: @MainActor (ModelContext) throws -> Void
    private var modelContext: ModelContext?
    private var authOperationGeneration: UInt64 = 0
    private var tokenRevokedDuringSignIn: String?

    init(
        appleSignInProvider: AppleSignInProvider? = nil,
        api: AuthAPIProtocol = APIClient.shared,
        tokenStore: AuthTokenStore? = nil,
        cacheDeleter: (@MainActor (ModelContext) throws -> Void)? = nil
    ) {
        self.appleSignInProvider = appleSignInProvider ?? AppleAuthorizationSignInProvider()
        self.api = api
        self.tokenStore = tokenStore ?? KeychainAuthTokenStore()
        self.cacheDeleter = cacheDeleter ?? Self.deleteUserOwnedCaches
    }

    func configure(modelContext: ModelContext) async throws {
        self.modelContext = modelContext
        await api.setUnauthorizedHandler { [weak self] rejectedToken in
            await self?.handleUnauthorized(rejectedToken: rejectedToken)
        }
        try await restoreSession()
    }

    func restoreSession() async throws {
        guard modelContext != nil else { throw AuthError.notConfigured }
        let generation = beginAuthOperation()
        state = .restoring
        currentUser = nil
        authErrorMessage = nil

        do {
            try await performSessionRestore(generation: generation)
        } catch {
            guard isCurrentAuthOperation(generation) else { return }
            if state == .restoring {
                currentUser = nil
                authErrorMessage = error.localizedDescription
                state = .failed
            }
            throw error
        }
    }

    private func performSessionRestore(generation: UInt64) async throws {
        guard let token = try tokenStore.loadToken(), !token.isEmpty else {
            try await invalidateSession(generation: generation)
            return
        }

        await api.setAuthToken(token)
        guard isCurrentAuthOperation(generation) else { return }
        do {
            let user = try await api.fetchCurrentUser()
            guard isCurrentAuthOperation(generation) else { return }
            currentUser = try upsertSingleUser(user)
            state = .signedIn
        } catch {
            guard isCurrentAuthOperation(generation) else { return }
            if isUnauthorized(error) {
                try await invalidateSession(generation: generation)
                return
            }
            if isConnectivityFailure(error) {
                if let cachedUser = try safelyMatchedCachedUser(for: token) {
                    currentUser = cachedUser
                    state = .signedIn
                } else {
                    try await invalidateSession(generation: generation)
                }
                return
            }
            try await invalidateSession(generation: generation)
            throw error
        }
    }

    func signInWithApple() async throws {
        guard state != .signingIn else { throw AuthError.signInAlreadyInProgress }
        guard modelContext != nil else { throw AuthError.notConfigured }

        let previousUser = currentUser
        let previousToken = try tokenStore.loadToken()
        let generation = beginAuthOperation()
        var didPersistBackendToken = false
        var didBeginLocalMutation = false
        tokenRevokedDuringSignIn = nil
        state = .signingIn
        authErrorMessage = nil

        do {
            let payload = try await appleSignInProvider.signIn()
            guard isCurrentAuthOperation(generation) else { return }
            let response = try await api.exchangeAppleCredential(AppleAuthRequest(payload: payload))
            guard isCurrentAuthOperation(generation) else { return }
            try tokenStore.saveToken(response.token)
            didPersistBackendToken = true
            await api.setAuthToken(response.token)
            guard isCurrentAuthOperation(generation) else { return }
            didBeginLocalMutation = true
            currentUser = try upsertSingleUser(response.user, appleUserIdentifier: payload.userIdentifier)
            state = .signedIn
        } catch {
            guard isCurrentAuthOperation(generation) else { return }
            if didBeginLocalMutation {
                modelContext?.rollback()
            }
            if didPersistBackendToken {
                do {
                    if let previousToken,
                       let previousUser,
                       tokenRevokedDuringSignIn != previousToken {
                        try tokenStore.saveToken(previousToken)
                        await api.setAuthToken(previousToken)
                        guard isCurrentAuthOperation(generation) else { return }
                        currentUser = previousUser
                        state = .signedIn
                    } else {
                        try await invalidateSession(generation: generation)
                    }
                } catch {
                    guard isCurrentAuthOperation(generation) else { return }
                    try? tokenStore.removeToken()
                    guard isCurrentAuthOperation(generation) else { return }
                    await api.setAuthToken(nil)
                    guard isCurrentAuthOperation(generation) else { return }

                    currentUser = nil
                    state = .failed
                    try? clearUserOwnedCaches()
                    authErrorMessage = error.localizedDescription
                    throw AuthError.cleanupFailed(error.localizedDescription)
                }
            } else {
                do {
                    if let previousToken,
                       let previousUser,
                       tokenRevokedDuringSignIn != previousToken,
                       try tokenStore.loadToken() == previousToken {
                        await api.setAuthToken(previousToken)
                        guard isCurrentAuthOperation(generation) else { return }
                        currentUser = previousUser
                        state = .signedIn
                    } else {
                        try await invalidateSession(generation: generation)
                    }
                } catch {
                    guard isCurrentAuthOperation(generation) else { return }
                    try? tokenStore.removeToken()
                    guard isCurrentAuthOperation(generation) else { return }
                    await api.setAuthToken(nil)
                    guard isCurrentAuthOperation(generation) else { return }
                    currentUser = nil
                    state = .failed
                    try? clearUserOwnedCaches()
                    authErrorMessage = error.localizedDescription
                    throw AuthError.cleanupFailed(error.localizedDescription)
                }
            }
            throw error
        }
    }

    func signOut() async throws {
        let generation = beginAuthOperation()
        do {
            try await invalidateSession(generation: generation)
        } catch {
            authErrorMessage = error.localizedDescription
            throw error
        }
    }

    private func handleUnauthorized(rejectedToken: String) async {
        guard state != .signingIn else {
            tokenRevokedDuringSignIn = rejectedToken
            return
        }

        do {
            guard try tokenStore.loadToken() == rejectedToken else { return }
        } catch {
            await finishFailedUnauthorizedCleanup(
                rejectedToken: rejectedToken,
                error: error,
                generation: nil,
                runtimeTokenAlreadyCleared: false
            )
            return
        }

        let generation = beginAuthOperation()
        var runtimeTokenAlreadyCleared = false
        do {
            try tokenStore.removeToken()
            guard isCurrentAuthOperation(generation) else { return }
            guard await api.clearAuthToken(ifMatching: rejectedToken),
                  isCurrentAuthOperation(generation) else { return }
            runtimeTokenAlreadyCleared = true
            guard try tokenStore.loadToken() == nil else { return }
            try clearUserOwnedCaches()
            currentUser = nil
            authErrorMessage = nil
            state = .signedOut
        } catch {
            await finishFailedUnauthorizedCleanup(
                rejectedToken: rejectedToken,
                error: error,
                generation: generation,
                runtimeTokenAlreadyCleared: runtimeTokenAlreadyCleared
            )
        }
    }

    private func finishFailedUnauthorizedCleanup(
        rejectedToken: String,
        error: Error,
        generation existingGeneration: UInt64?,
        runtimeTokenAlreadyCleared: Bool
    ) async {
        let generation: UInt64
        if let existingGeneration {
            guard isCurrentAuthOperation(existingGeneration) else { return }
            generation = existingGeneration
        } else {
            generation = beginAuthOperation()
        }

        if !runtimeTokenAlreadyCleared {
            guard await api.clearAuthToken(ifMatching: rejectedToken),
                  isCurrentAuthOperation(generation) else { return }
        }
        guard isCurrentAuthOperation(generation) else { return }
        if let persistedToken = try? tokenStore.loadToken(),
           persistedToken != rejectedToken {
            return
        }
        try? clearUserOwnedCaches()
        currentUser = nil
        authErrorMessage = error.localizedDescription
        state = .failed
    }

    private func invalidateSession(generation: UInt64) async throws {
        guard isCurrentAuthOperation(generation) else { return }
        try tokenStore.removeToken()
        guard isCurrentAuthOperation(generation) else { return }
        await api.setAuthToken(nil)
        guard isCurrentAuthOperation(generation) else { return }

        currentUser = nil
        state = .failed
        do {
            try clearUserOwnedCaches()
        } catch {
            authErrorMessage = error.localizedDescription
            throw error
        }

        authErrorMessage = nil
        state = .signedOut
    }

    private func beginAuthOperation() -> UInt64 {
        authOperationGeneration &+= 1
        return authOperationGeneration
    }

    private func isCurrentAuthOperation(_ generation: UInt64) -> Bool {
        authOperationGeneration == generation
    }

    private func upsertSingleUser(
        _ response: AuthUserResponse,
        appleUserIdentifier: String? = nil
    ) throws -> User {
        guard let modelContext else { throw AuthError.notConfigured }
        var users = try modelContext.fetch(FetchDescriptor<User>())
        if users.contains(where: { $0.id != response.id }) {
            try cacheDeleter(modelContext)
            users = []
        }

        let user: User
        if let existing = users.first(where: { $0.id == response.id }) {
            user = existing
        } else {
            user = User(id: response.id, username: response.username)
            modelContext.insert(user)
        }

        user.username = response.username
        user.displayName = response.displayName
        user.isAdmin = response.isAdmin
        user.authProvider = response.authProvider
        if let appleUserIdentifier { user.appleUserIdentifier = appleUserIdentifier }

        for duplicate in users where duplicate !== user {
            modelContext.delete(duplicate)
        }
        try modelContext.save()
        return user
    }

    private func safelyMatchedCachedUser(for token: String, now: Date = Date()) throws -> User? {
        guard let claims = Self.claims(fromJWT: token),
              claims.expiresAt > now,
              let modelContext else {
            return nil
        }
        let users = try modelContext.fetch(FetchDescriptor<User>())
        guard users.count == 1, users[0].id == claims.subject else { return nil }
        return users[0]
    }

    private func clearUserOwnedCaches() throws {
        guard let modelContext else { throw AuthError.notConfigured }
        try cacheDeleter(modelContext)
        try modelContext.save()
    }

    private static func deleteUserOwnedCaches(in modelContext: ModelContext) throws {
        for message in try modelContext.fetch(FetchDescriptor<ChatMessage>()) {
            modelContext.delete(message)
        }
        for conversation in try modelContext.fetch(FetchDescriptor<Conversation>()) {
            modelContext.delete(conversation)
        }
        for session in try modelContext.fetch(FetchDescriptor<Session>()) {
            modelContext.delete(session)
        }
        for user in try modelContext.fetch(FetchDescriptor<User>()) {
            modelContext.delete(user)
        }
    }

    private func isUnauthorized(_ error: Error) -> Bool {
        guard let apiError = error as? APIError else { return false }
        if apiError == .unauthorized { return true }
        if case .httpError(let statusCode, _) = apiError { return statusCode == 401 }
        return false
    }

    private func isConnectivityFailure(_ error: Error) -> Bool {
        guard let apiError = error as? APIError else { return false }
        switch apiError {
        case .networkUnavailable, .timeout:
            return true
        default:
            return false
        }
    }

    private struct JWTClaims {
        let subject: String
        let expiresAt: Date
    }

    private static func claims(fromJWT token: String) -> JWTClaims? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = object["sub"] as? String,
              !subject.isEmpty,
              let expiration = object["exp"] as? NSNumber else {
            return nil
        }
        return JWTClaims(
            subject: subject,
            expiresAt: Date(timeIntervalSince1970: expiration.doubleValue)
        )
    }
}

enum AuthError: LocalizedError, Equatable {
    case invalidCredential
    case notConfigured
    case signInAlreadyInProgress
    case cleanupFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredential:
            return "Sign in failed"
        case .notConfigured:
            return "Authentication is not configured"
        case .signInAlreadyInProgress:
            return "Sign in is already in progress"
        case .cleanupFailed(let detail):
            return "Authentication cleanup failed: \(detail)"
        }
    }
}
