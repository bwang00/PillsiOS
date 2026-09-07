import XCTest
@testable import Pills

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var _handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    private static var _requests: [URLRequest] = []

    static var requests: [URLRequest] {
        lock.withLock { _requests }
    }

    static func configure(handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) {
        lock.withLock {
            _requests = []
            _handler = handler
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            var capturedRequest = request
            if capturedRequest.httpBody == nil, let stream = capturedRequest.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var body = Data()
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let count = stream.read(buffer, maxLength: 4_096)
                    guard count > 0 else { break }
                    body.append(buffer, count: count)
                }
                capturedRequest.httpBody = body
            }
            let handler = Self.lock.withLock { () -> ((URLRequest) throws -> (HTTPURLResponse, Data))? in
                Self._requests.append(capturedRequest)
                return Self._handler
            }
            guard let handler else { throw URLError(.badServerResponse) }
            let (response, data) = try handler(capturedRequest)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class APIClientTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        super.tearDown()
    }

    func testAppleExchangeIsPublicAndSendsContractPayload() async throws {
        URLProtocolStub.configure { request in
            let data = try JSONSerialization.data(withJSONObject: [
                "token": "backend-token", "id": "user-id", "username": "alice",
                "display_name": "Alice", "is_admin": false, "auth_provider": "apple"
            ])
            return (self.response(for: request, status: 200), data)
        }
        let client = APIClient(baseURL: URL(string: "https://unit.test")!, session: session)
        let payload = AppleSignInPayload(
            identityToken: "identity-token", authorizationCode: "code", userIdentifier: "apple-user",
            email: "alice@example.com", displayName: "Alice Example", givenName: "Alice", familyName: "Example"
        )

        let result = try await client.exchangeAppleCredential(AppleAuthRequest(payload: payload))

        XCTAssertEqual(result.token, "backend-token")
        let request = try XCTUnwrap(URLProtocolStub.requests.first)
        XCTAssertEqual(request.url?.path, "/api/auth/apple")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["identity_token"] as? String, "identity-token")
        XCTAssertEqual(json["authorization_code"] as? String, "code")
        XCTAssertEqual(json["display_name"] as? String, "Alice Example")
        XCTAssertEqual(json["given_name"] as? String, "Alice")
        XCTAssertEqual(json["family_name"] as? String, "Example")
        XCTAssertNil(json["email"])
        XCTAssertNil(json["user_identifier"])
    }

    func testAuthenticatedRequestAddsBearerCentrally() async throws {
        URLProtocolStub.configure { request in
            let data = try JSONSerialization.data(withJSONObject: [
                "id": "user-id", "username": "alice", "display_name": "Alice",
                "is_admin": false, "auth_provider": "apple"
            ])
            return (self.response(for: request, status: 200), data)
        }
        let client = APIClient(baseURL: URL(string: "https://unit.test")!, session: session)
        await client.setAuthToken("secret-token")

        _ = try await client.fetchCurrentUser()

        let request = try XCTUnwrap(URLProtocolStub.requests.first)
        XCTAssertEqual(request.url?.path, "/api/auth/me")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
    }

    func testAuthenticatedRequestWithoutTokenFailsBeforeNetwork() async {
        URLProtocolStub.configure { request in
            XCTFail("Network should not be reached")
            return (self.response(for: request, status: 500), Data())
        }
        let client = APIClient(baseURL: URL(string: "https://unit.test")!, session: session)

        do {
            _ = try await client.fetchCurrentUser()
            XCTFail("Expected unauthorized")
        } catch {
            XCTAssertEqual(error as? APIError, .unauthorized)
        }
        XCTAssertTrue(URLProtocolStub.requests.isEmpty)
    }

    func test401IsNotRetriedAndUnauthorizedCallbackRunsOnlyOnce() async throws {
        URLProtocolStub.configure { request in
            (self.response(for: request, status: 401), Data("unauthorized".utf8))
        }
        let callback = expectation(description: "unauthorized callback")
        callback.assertForOverFulfill = true
        let count = LockedCounter()
        let client = APIClient(baseURL: URL(string: "https://unit.test")!, session: session)
        await client.setAuthToken("secret-token")
        await client.setUnauthorizedHandler { _ in
            count.increment()
            callback.fulfill()
            await client.setAuthToken(nil)
        }

        let first = Task { try? await client.fetchGuides() }
        let second = Task { try? await client.fetchGuides() }
        _ = await first.value
        _ = await second.value
        await fulfillment(of: [callback], timeout: 1)

        XCTAssertEqual(URLProtocolStub.requests.count, 2)
        XCTAssertEqual(count.value, 1)
    }

    func testConcurrentSuccessIsRejectedAfterSameTokenTriggersUnauthorized() async {
        URLProtocolStub.configure { request in
            if URLProtocolStub.requests.count == 1 {
                return (self.response(for: request, status: 401), Data("unauthorized".utf8))
            }
            return (self.response(for: request, status: 200), Data("[]".utf8))
        }
        let callbackStarted = expectation(description: "unauthorized callback started")
        let callbackGate = AsyncGate()
        let client = APIClient(baseURL: URL(string: "https://unit.test")!, session: session)
        await client.setAuthToken("secret-token")
        await client.setUnauthorizedHandler { _ in
            callbackStarted.fulfill()
            await callbackGate.wait()
        }

        let unauthorizedRequest = Task { try await client.fetchGuides() }
        await fulfillment(of: [callbackStarted], timeout: 1)

        do {
            _ = try await client.fetchGuides()
            XCTFail("Expected concurrent response from invalidated token to be rejected")
        } catch {
            XCTAssertEqual(error as? APIError, .unauthorized)
        }

        await callbackGate.open()
        do {
            _ = try await unauthorizedRequest.value
            XCTFail("Expected unauthorized")
        } catch {
            XCTAssertEqual(error as? APIError, .unauthorized)
        }
    }

    func testResettingSameTokenRearmsUnauthorizedCallback() async {
        URLProtocolStub.configure { request in
            (self.response(for: request, status: 401), Data("unauthorized".utf8))
        }
        let count = LockedCounter()
        let client = APIClient(baseURL: URL(string: "https://unit.test")!, session: session)
        await client.setAuthToken("secret-token")
        await client.setUnauthorizedHandler { _ in count.increment() }

        _ = try? await client.fetchGuides()
        await client.setAuthToken("secret-token")
        _ = try? await client.fetchGuides()

        XCTAssertEqual(count.value, 2)
    }

    func testAuthenticatedRequestDoesNotRetryAfterTokenChanges() async {
        let firstAttempt = expectation(description: "first attempt")
        URLProtocolStub.configure { request in
            if URLProtocolStub.requests.count == 1 {
                firstAttempt.fulfill()
                throw URLError(.timedOut)
            }
            let data = try JSONSerialization.data(withJSONObject: ["sessions": [], "total": 0])
            return (self.response(for: request, status: 200), data)
        }
        let client = APIClient(baseURL: URL(string: "https://unit.test")!, session: session)
        await client.setAuthToken("user-a-token")

        let request = Task { try await client.fetchSessions() }
        await fulfillment(of: [firstAttempt], timeout: 1)
        await client.setAuthToken("user-b-token")

        do {
            _ = try await request.value
            XCTFail("Expected the stale request to be rejected")
        } catch {
            XCTAssertEqual(error as? APIError, .unauthorized)
        }
        XCTAssertEqual(URLProtocolStub.requests.count, 1)
        XCTAssertEqual(
            URLProtocolStub.requests.first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer user-a-token"
        )
    }

    func testDelayed401FromOldTokenDoesNotNotifyUnauthorizedHandler() async {
        let requestStarted = expectation(description: "request started")
        let allowResponse = DispatchSemaphore(value: 0)
        URLProtocolStub.configure { request in
            requestStarted.fulfill()
            _ = allowResponse.wait(timeout: .now() + 2)
            return (self.response(for: request, status: 401), Data("unauthorized".utf8))
        }
        let count = LockedCounter()
        let client = APIClient(baseURL: URL(string: "https://unit.test")!, session: session)
        await client.setAuthToken("user-a-token")
        await client.setUnauthorizedHandler { _ in count.increment() }

        let request = Task { try await client.fetchGuides() }
        await fulfillment(of: [requestStarted], timeout: 1)
        await client.setAuthToken("user-b-token")
        allowResponse.signal()

        do {
            _ = try await request.value
            XCTFail("Expected unauthorized")
        } catch {
            XCTAssertEqual(error as? APIError, .unauthorized)
        }
        XCTAssertEqual(count.value, 0)
    }

    func testPublicEndpoint401DoesNotNotifyGlobalUnauthorizedHandler() async {
        URLProtocolStub.configure { request in
            (self.response(for: request, status: 401), Data("unauthorized".utf8))
        }
        let count = LockedCounter()
        let client = APIClient(baseURL: URL(string: "https://unit.test")!, session: session)
        await client.setUnauthorizedHandler { _ in count.increment() }
        let payload = AppleSignInPayload(
            identityToken: "identity-token", authorizationCode: "code", userIdentifier: "apple-user",
            email: nil, displayName: nil, givenName: nil, familyName: nil
        )

        do {
            _ = try await client.exchangeAppleCredential(AppleAuthRequest(payload: payload))
            XCTFail("Expected unauthorized")
        } catch {
            XCTAssertEqual(error as? APIError, .unauthorized)
        }

        await Task.yield()
        XCTAssertEqual(count.value, 0)
    }

    func testSessionValidation401DoesNotNotifyGlobalUnauthorizedHandler() async {
        URLProtocolStub.configure { request in
            (self.response(for: request, status: 401), Data("unauthorized".utf8))
        }
        let count = LockedCounter()
        let client = APIClient(baseURL: URL(string: "https://unit.test")!, session: session)
        await client.setAuthToken("secret-token")
        await client.setUnauthorizedHandler { _ in count.increment() }

        do {
            _ = try await client.fetchCurrentUser()
            XCTFail("Expected unauthorized")
        } catch {
            XCTAssertEqual(error as? APIError, .unauthorized)
        }

        await Task.yield()
        XCTAssertEqual(count.value, 0)
    }

    func testDirectProductionClientIsBlockedDuringTests() async {
        URLProtocolStub.configure { request in
            XCTFail("Production request must be rejected before reaching URLSession")
            let data = try! JSONSerialization.data(withJSONObject: ["status": "ok"])
            return (self.response(for: request, status: 200), data)
        }
        let client = APIClient(
            baseURL: URL(string: "https://pills.blueping.xyz")!,
            session: session
        )

        do {
            _ = try await client.healthCheck()
            XCTFail("Expected unsafe test base URL")
        } catch {
            XCTAssertEqual(error as? APIConfigurationError, .unsafeTestBaseURL)
        }
        XCTAssertTrue(URLProtocolStub.requests.isEmpty)
    }

    func testNonLoopbackTestClientRequiresInjectedSession() async {
        let client = APIClient(baseURL: URL(string: "https://unit.test")!)

        do {
            _ = try await client.healthCheck()
            XCTFail("Expected unsafe test session")
        } catch {
            XCTAssertEqual(error as? APIConfigurationError, .unsafeTestSession)
        }
    }

    func testEnvironmentDataNamespacesAreDistinctAndStable() {
        let development = APIConfiguration.dataNamespace(configuredEnvironment: "Development")
        let staging = APIConfiguration.dataNamespace(configuredEnvironment: "Staging")
        let production = APIConfiguration.dataNamespace(configuredEnvironment: "Production")

        XCTAssertEqual(development, "pills-development")
        XCTAssertEqual(staging, "pills-staging")
        XCTAssertEqual(production, "pills-production")
        XCTAssertEqual(Set([development, staging, production]).count, 3)
    }

    func testTestConfigurationRejectsProductionButAllowsLoopback() throws {
        XCTAssertThrowsError(
            try APIConfiguration.resolveBaseURL(
                configuredValue: "https://pills.blueping.xyz",
                isRunningTests: true
            )
        ) { error in
            XCTAssertEqual(error as? APIConfigurationError, .unsafeTestBaseURL)
        }

        let local = try APIConfiguration.resolveBaseURL(
            configuredValue: "http://127.0.0.1:8001",
            isRunningTests: true
        )
        XCTAssertEqual(local.absoluteString, "http://127.0.0.1:8001")
    }

    func testNonIdempotentPostIsNotRetriedOnAmbiguousTimeout() async {
        URLProtocolStub.configure { _ in
            throw URLError(.timedOut)
        }
        let client = APIClient(baseURL: URL(string: "https://unit.test")!, session: session)
        await client.setAuthToken("secret-token")

        do {
            _ = try await client.createSession(guideSlug: "4-7-8-breathing")
            XCTFail("Expected the ambiguous timeout to surface")
        } catch {
            XCTAssertEqual(error as? APIError, .timeout)
        }
        // A timed-out POST may have committed server-side; retrying would risk
        // creating a duplicate session, so exactly one attempt is allowed.
        XCTAssertEqual(URLProtocolStub.requests.count, 1)
    }

    func testNonIdempotentPostRetriesOnPreDeliveryFailure() async {
        URLProtocolStub.configure { _ in
            throw URLError(.notConnectedToInternet)
        }
        let client = APIClient(baseURL: URL(string: "https://unit.test")!, session: session)
        await client.setAuthToken("secret-token")

        do {
            _ = try await client.createSession(guideSlug: "4-7-8-breathing")
            XCTFail("Expected the offline failure to surface")
        } catch {
            XCTAssertEqual(error as? APIError, .networkUnavailable)
        }
        // The request never reached the server, so retrying cannot duplicate it.
        XCTAssertEqual(URLProtocolStub.requests.count, 3)
    }

    func testIdempotentGetRetriesOnAmbiguousTimeout() async {
        URLProtocolStub.configure { _ in
            throw URLError(.timedOut)
        }
        let client = APIClient(baseURL: URL(string: "https://unit.test")!, session: session)
        await client.setAuthToken("secret-token")

        do {
            _ = try await client.fetchSessions()
            XCTFail("Expected the timeout to surface")
        } catch {
            XCTAssertEqual(error as? APIError, .timeout)
        }
        XCTAssertEqual(URLProtocolStub.requests.count, 3)
    }

    private func response(for request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
