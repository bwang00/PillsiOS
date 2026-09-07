import Foundation

actor APIClient {
    static let shared = APIClient(baseURL: APIConfiguration.defaultBaseURL())

    private enum Authentication: Equatable {
        case publicEndpoint
        case sessionValidation
        case required

        var requiresBearerToken: Bool {
            self != .publicEndpoint
        }

        var notifiesGlobalUnauthorizedHandler: Bool {
            self == .required
        }
    }

    private let baseURL: URL
    private let session: URLSession
    private let configurationError: APIConfigurationError?
    private var authToken: String?
    private var unauthorizedHandler: (@Sendable (String) async -> Void)?
    private var didNotifyUnauthorized = false

    init(baseURL: URL, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.configurationError = APIConfiguration.clientConfigurationError(
            baseURL: baseURL,
            hasInjectedSession: session != nil
        )
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 120
            self.session = URLSession(configuration: configuration)
        }
    }

    func setAuthToken(_ token: String?) {
        authToken = token
        didNotifyUnauthorized = false
    }

    func clearAuthToken(ifMatching token: String) -> Bool {
        guard authToken == token else { return false }
        setAuthToken(nil)
        return true
    }

    func setUnauthorizedHandler(_ handler: (@Sendable (String) async -> Void)?) {
        unauthorizedHandler = handler
    }

    func exchangeAppleCredential(_ request: AppleAuthRequest) async throws -> AuthResponse {
        try await post("/api/auth/apple", body: request, authentication: .publicEndpoint)
    }

    func fetchCurrentUser() async throws -> AuthUserResponse {
        try await get("/api/auth/me", authentication: .sessionValidation)
    }

    func healthCheck() async throws -> Bool {
        let data: [String: String] = try await get("/api/health", authentication: .publicEndpoint)
        return data["status"] == "ok"
    }

    func fetchGuides(category: String? = nil) async throws -> [GuideDTO] {
        var path = "/api/guides"
        if let category,
           let escaped = category.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "?category=\(escaped)"
        }
        return try await get(path, authentication: .required)
    }

    func createSession(guideSlug: String, idempotencyKey: String? = nil) async throws -> SessionDTO {
        var headers: [String: String] = [:]
        if let idempotencyKey {
            headers["Idempotency-Key"] = idempotencyKey
        }
        return try await post(
            "/api/sessions",
            body: CreateSessionRequest(guide_slug: guideSlug),
            authentication: .required,
            extraHeaders: headers
        )
    }

    func completeSession(id: String, durationSeconds: Int) async throws -> SessionDTO {
        let body = CompleteSessionRequest(
            completed_at: ISO8601DateFormatter().string(from: Date()),
            duration_seconds: durationSeconds
        )
        return try await patch("/api/sessions/\(id)", body: body, authentication: .required)
    }

    func fetchSessions(limit: Int = 20, offset: Int = 0) async throws -> [SessionDTO] {
        let response: SessionsListResponse = try await get(
            "/api/sessions?limit=\(limit)&offset=\(offset)",
            authentication: .required
        )
        return response.sessions
    }

    func synthesizeSpeech(_ text: String) async throws -> Data {
        let response: TTSResponse = try await post(
            "/api/tts",
            body: ["text": text],
            authentication: .required
        )
        guard let audioData = Data(base64Encoded: response.audio_data) else {
            throw APIError.invalidResponse
        }
        return audioData
    }

    func createConversation() async throws -> ConversationDTO {
        try await postWithoutBody("/api/conversations", authentication: .required)
    }

    func sendMessage(conversationId: String, role: String, content: String) async throws -> MessageDTO {
        let body = SendMessageBody(role: role, content: content)
        return try await post(
            "/api/conversations/messages?conversation_id=\(conversationId)",
            body: body,
            authentication: .required
        )
    }

    func fetchConversationDetail(_ id: String) async throws -> ConversationDetailDTO {
        try await get("/api/conversations/\(id)", authentication: .required)
    }

    func fetchConversations(limit: Int = 20) async throws -> [ConversationDTO] {
        try await get("/api/conversations?limit=\(limit)", authentication: .required)
    }

    func sendAIChat(message: String, history: [AIChatHistoryEntry]) async throws -> AIChatResponse {
        try await post(
            "/api/ai-chat",
            body: AIChatRequest(message: message, history: history),
            authentication: .required
        )
    }

    private func get<T: Decodable>(_ path: String, authentication: Authentication) async throws -> T {
        try await perform(path: path, method: "GET", body: nil, authentication: authentication, isIdempotent: true)
    }

    private func post<T: Decodable, Body: Encodable>(
        _ path: String,
        body: Body,
        authentication: Authentication,
        extraHeaders: [String: String] = [:]
    ) async throws -> T {
        let encodedBody: Data
        do {
            encodedBody = try JSONEncoder().encode(body)
        } catch {
            throw APIError.from(error)
        }
        return try await perform(path: path, method: "POST", body: encodedBody, authentication: authentication, isIdempotent: false, extraHeaders: extraHeaders)
    }

    private func postWithoutBody<T: Decodable>(
        _ path: String,
        authentication: Authentication
    ) async throws -> T {
        try await perform(path: path, method: "POST", body: nil, authentication: authentication, isIdempotent: false)
    }

    private func patch<T: Decodable, Body: Encodable>(
        _ path: String,
        body: Body,
        authentication: Authentication
    ) async throws -> T {
        let encodedBody: Data
        do {
            encodedBody = try JSONEncoder().encode(body)
        } catch {
            throw APIError.from(error)
        }
        return try await perform(path: path, method: "PATCH", body: encodedBody, authentication: authentication, isIdempotent: true)
    }

    private func perform<T: Decodable>(
        path: String,
        method: String,
        body: Data?,
        authentication: Authentication,
        isIdempotent: Bool,
        extraHeaders: [String: String] = [:]
    ) async throws -> T {
        if let configurationError { throw configurationError }
        let requestToken = try tokenSnapshot(for: authentication)
        return try await withRetry(isIdempotent: isIdempotent) {
            try self.ensureCurrentAuthentication(authentication, requestToken: requestToken)
            let request = try self.makeRequest(
                path: path,
                method: method,
                body: body,
                authentication: authentication,
                requestToken: requestToken,
                extraHeaders: extraHeaders
            )
            let (data, response) = try await self.session.data(for: request)
            try self.ensureCurrentAuthentication(authentication, requestToken: requestToken)
            try await self.validateResponse(
                response,
                data: data,
                authentication: authentication,
                requestToken: requestToken
            )
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw APIError.from(error)
            }
        }
    }

    private func withRetry<T>(
        isIdempotent: Bool,
        maxRetries: Int = 2,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 0...maxRetries {
            do {
                return try await operation()
            } catch {
                guard attempt < maxRetries,
                      Self.shouldRetry(error, isIdempotent: isIdempotent) else {
                    throw APIError.from(error)
                }
                lastError = error
                try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 1_000_000_000))
            }
        }
        throw APIError.from(lastError ?? APIError.unknown)
    }

    /// Decides whether a failed request can be re-issued without risking a
    /// duplicate side effect.
    ///
    /// Errors that prove the request never reached the server (offline, DNS,
    /// connection refused) and 429 rate-limit rejections are always safe to
    /// retry. Ambiguous failures — timeouts, dropped connections, and 5xx
    /// responses where the server may have committed before the response was
    /// lost — are only retried for idempotent requests. Retrying an ambiguous
    /// non-idempotent POST (e.g. `createSession`) could create a duplicate
    /// server-side record.
    private static func shouldRetry(_ error: Error, isIdempotent: Bool) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return true
            case .timedOut, .networkConnectionLost:
                return isIdempotent
            default:
                return false
            }
        }
        if let apiError = error as? APIError {
            switch apiError {
            case .httpError(let code, _):
                if code == 429 { return true }
                if code >= 500 { return isIdempotent }
                return false
            case .networkUnavailable, .timeout:
                return isIdempotent
            default:
                return false
            }
        }
        return false
    }

    private func tokenSnapshot(for authentication: Authentication) throws -> String? {
        guard authentication.requiresBearerToken else { return nil }
        guard let authToken else { throw APIError.unauthorized }
        return authToken
    }

    private func ensureCurrentAuthentication(
        _ authentication: Authentication,
        requestToken: String?
    ) throws {
        guard authentication.requiresBearerToken else { return }
        guard authToken == requestToken else { throw APIError.unauthorized }
        if authentication.notifiesGlobalUnauthorizedHandler,
           didNotifyUnauthorized {
            throw APIError.unauthorized
        }
    }

    private func makeRequest(
        path: String,
        method: String,
        body: Data?,
        authentication: Authentication,
        requestToken: String?,
        extraHeaders: [String: String] = [:]
    ) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw APIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authentication.requiresBearerToken {
            guard let requestToken else { throw APIError.unauthorized }
            request.setValue("Bearer \(requestToken)", forHTTPHeaderField: "Authorization")
        }
        for (field, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = body
        return request
    }

    private func validateResponse(
        _ response: URLResponse,
        data: Data,
        authentication: Authentication,
        requestToken: String?
    ) async throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        if http.statusCode == 401 {
            if authentication.notifiesGlobalUnauthorizedHandler,
               let requestToken {
                await notifyUnauthorizedOnce(for: requestToken)
            }
            throw APIError.unauthorized
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpError(statusCode: http.statusCode, body: body)
        }
    }

    private func notifyUnauthorizedOnce(for requestToken: String) async {
        guard authToken == requestToken, !didNotifyUnauthorized else { return }
        didNotifyUnauthorized = true
        guard let unauthorizedHandler else { return }
        await unauthorizedHandler(requestToken)
    }
}

extension APIClient: AuthAPIProtocol {}

enum APIConfigurationError: Error, Equatable {
    case missingBaseURL
    case invalidBaseURL
    case insecureBaseURL
    case unsafeTestBaseURL
    case unsafeTestSession
}

enum APIConfiguration {
    private static let productionHost = "pills.blueping.xyz"

    static func defaultBaseURL(bundle: Bundle = .main) -> URL {
        do {
            return try resolveBaseURL(
                configuredValue: bundle.object(forInfoDictionaryKey: "PILLSAPIBaseURL") as? String,
                isRunningTests: isRunningTests
            )
        } catch {
            assertionFailure("Invalid PILLSAPIBaseURL configuration: \(error)")
            return URL(string: "http://127.0.0.1:1")!
        }
    }

    static func dataNamespace(configuredEnvironment: String?) -> String {
        switch configuredEnvironment?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "development":
            return "pills-development"
        case "staging":
            return "pills-staging"
        case "production":
            return "pills-production"
        default:
            return "pills-unknown"
        }
    }

    static func defaultDataNamespace(bundle: Bundle = .main) -> String {
        dataNamespace(
            configuredEnvironment: bundle.object(forInfoDictionaryKey: "PILLSAPIEnvironment") as? String
        )
    }

    static func resolveBaseURL(configuredValue: String?, isRunningTests: Bool) throws -> URL {
        guard let value = configuredValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              !value.contains("$(") else {
            throw APIConfigurationError.missingBaseURL
        }
        guard let url = URL(string: value) else {
            throw APIConfigurationError.invalidBaseURL
        }
        try validateBaseURL(url, isRunningTests: isRunningTests)
        return url
    }

    static func clientConfigurationError(
        baseURL: URL,
        hasInjectedSession: Bool
    ) -> APIConfigurationError? {
        do {
            try validateBaseURL(baseURL, isRunningTests: isRunningTests)
            if isRunningTests && !isLoopback(baseURL) && !hasInjectedSession {
                throw APIConfigurationError.unsafeTestSession
            }
            return nil
        } catch let error as APIConfigurationError {
            return error
        } catch {
            return .invalidBaseURL
        }
    }

    private static func validateBaseURL(_ url: URL, isRunningTests: Bool) throws {
        guard let scheme = url.scheme, let host = url.host else {
            throw APIConfigurationError.invalidBaseURL
        }
        guard scheme == "https" || (scheme == "http" && isLoopback(url)) else {
            throw APIConfigurationError.insecureBaseURL
        }
        if isRunningTests && host == productionHost {
            throw APIConfigurationError.unsafeTestBaseURL
        }
    }

    private static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil ||
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

enum APIError: LocalizedError, Equatable {
    case invalidResponse
    case unauthorized
    case httpError(statusCode: Int, body: String)
    case networkUnavailable
    case timeout
    case decodingFailed(String)
    case unknown

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "服务器响应异常，请稍后重试"
        case .unauthorized:
            return "登录已过期，请重新登录"
        case .httpError(let code, _):
            switch code {
            case 401: return "登录已过期，请重新登录"
            case 403: return "没有权限执行此操作"
            case 404: return "请求的资源不存在"
            case 429: return "请求太频繁，请稍后再试"
            case 500...599: return "服务器暂时不可用，请稍后重试"
            default: return "请求失败 (\(code))"
            }
        case .networkUnavailable:
            return "网络连接不可用，请检查网络设置"
        case .timeout:
            return "请求超时，请检查网络后重试"
        case .decodingFailed(let detail):
            return "数据解析失败：\(detail)"
        case .unknown:
            return "发生未知错误，请稍后重试"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .networkUnavailable, .timeout:
            return true
        case .httpError(let code, _):
            return code >= 500 || code == 429
        default:
            return false
        }
    }

    static func from(_ error: Error) -> APIError {
        if let apiError = error as? APIError { return apiError }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return .networkUnavailable
            case .timedOut:
                return .timeout
            default:
                return .unknown
            }
        }
        if error is DecodingError { return .decodingFailed("数据格式不匹配") }
        return .unknown
    }
}
