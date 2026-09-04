import Foundation

/// Centralised API client.
/// Thread-safe actor that handles all HTTP communication with the Pills backend.
actor APIClient {
    static let shared = APIClient()

    private let baseURL: URL
    private let session: URLSession
    private var authToken: String?

    private init() {
        let urlString = ProcessInfo.processInfo.environment["PILLS_API_URL"]
            ?? "https://pills.blueping.xyz"
        self.baseURL = URL(string: urlString)!
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    func setAuthToken(_ token: String?) {
        self.authToken = token
    }

    // MARK: - Health

    func healthCheck() async throws -> Bool {
        let data: [String: String] = try await get("/api/health")
        return data["status"] == "ok"
    }

    // MARK: - Guides

    func fetchGuides(category: String? = nil) async throws -> [GuideDTO] {
        var path = "/api/guides"
        if let category { path += "?category=\(category)" }
        return try await get(path)
    }

    // MARK: - Sessions

    func createSession(guideSlug: String) async throws -> SessionDTO {
        let body = CreateSessionRequest(guide_slug: guideSlug)
        return try await post("/api/sessions", body: body)
    }

    func completeSession(id: String, durationSeconds: Int) async throws -> SessionDTO {
        let now = ISO8601DateFormatter().string(from: Date())
        let body = CompleteSessionRequest(
            completed_at: now,
            duration_seconds: durationSeconds
        )
        return try await patch("/api/sessions/\(id)", body: body)
    }

    func fetchSessions(limit: Int = 20, offset: Int = 0) async throws -> [SessionDTO] {
        let resp: SessionsListResponse = try await get("/api/sessions?limit=\(limit)&offset=\(offset)")
        return resp.sessions
    }

    // MARK: - TTS

    func synthesizeSpeech(_ text: String) async throws -> Data {
        let body: [String: String] = ["text": text]
        let request = makeRequest(path: "/api/tts", method: "POST", body: body)
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
        let ttsResponse = try JSONDecoder().decode(TTSResponse.self, from: data)
        guard let audioData = Data(base64Encoded: ttsResponse.audio_data) else {
            throw APIError.invalidResponse
        }
        return audioData
    }

    // MARK: - Conversations

    func createConversation(username: String? = nil) async throws -> ConversationDTO {
        var path = "/api/conversations"
        if let username { path += "?username=\(username)" }
        return try await post(path, body: Optional<String>.none as String?)
    }

    func sendMessage(conversationId: String, role: String, content: String) async throws -> MessageDTO {
        let body = SendMessageBody(role: role, content: content)
        return try await post("/api/conversations/messages?conversation_id=\(conversationId)", body: body)
    }

    func fetchConversationDetail(_ id: String) async throws -> ConversationDetailDTO {
        return try await get("/api/conversations/\(id)")
    }

    func fetchConversations(username: String? = nil, limit: Int = 20) async throws -> [ConversationDTO] {
        var path = "/api/conversations?limit=\(limit)"
        if let username { path += "&username=\(username)" }
        return try await get(path)
    }

    // MARK: - AI Chat

    func sendAIChat(message: String, history: [AIChatHistoryEntry], username: String?) async throws -> AIChatResponse {
        let body = AIChatRequest(
            message: message,
            history: history,
            username: username
        )
        return try await post("/api/ai-chat", body: body)
    }

    // MARK: - Private helpers

    private func get<T: Decodable>(_ path: String) async throws -> T {
        return try await withRetry {
            let request = self.makeRequest(path: path, method: "GET", body: Optional<String>.none)
            let (data, response) = try await self.session.data(for: request)
            try self.validateResponse(response, data: data)
            return try JSONDecoder().decode(T.self, from: data)
        }
    }

    private func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        return try await withRetry {
            let request = self.makeRequest(path: path, method: "POST", body: body)
            let (data, response) = try await self.session.data(for: request)
            try self.validateResponse(response, data: data)
            return try JSONDecoder().decode(T.self, from: data)
        }
    }

    private func patch<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        return try await withRetry {
            let request = self.makeRequest(path: path, method: "PATCH", body: body)
            let (data, response) = try await self.session.data(for: request)
            try self.validateResponse(response, data: data)
            return try JSONDecoder().decode(T.self, from: data)
        }
    }

    /// Retry with exponential backoff for transient errors (max 2 retries).
    private func withRetry<T>(maxRetries: Int = 2, operation: @escaping () async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 0...maxRetries {
            do {
                return try await operation()
            } catch let error as APIError where error.isRetryable && attempt < maxRetries {
                lastError = error
                let delay = UInt64(pow(2.0, Double(attempt)) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: delay)
            } catch let error as URLError where error.isTransient && attempt < maxRetries {
                lastError = error
                let delay = UInt64(pow(2.0, Double(attempt)) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: delay)
            } catch {
                throw APIError.from(error)
            }
        }
        throw APIError.from(lastError ?? APIError.unknown)
    }

    private func makeRequest<B: Encodable>(path: String, method: String, body: B) -> URLRequest {
        let url = URL(string: path, relativeTo: baseURL)!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let encodable = body as? Encodable, !(body is Optional<String>) {
            request.httpBody = try? JSONEncoder().encode(AnyEncodable(encodable))
        }
        return request
    }

    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpError(statusCode: http.statusCode, body: body)
        }
    }
}

// MARK: - Error types

enum APIError: LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case networkUnavailable
    case timeout
    case decodingFailed(String)
    case unknown

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "服务器响应异常，请稍后重试"
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

    /// Whether this error is transient and the request can be retried.
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

    /// Convert any error into a user-friendly APIError.
    static func from(_ error: Error) -> APIError {
        if let apiError = error as? APIError {
            return apiError
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return .networkUnavailable
            case .timedOut:
                return .timeout
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return .networkUnavailable
            default:
                return .unknown
            }
        }
        if error is DecodingError {
            return .decodingFailed("数据格式不匹配")
        }
        return .unknown
    }
}

// MARK: - URLError transient check

private extension URLError {
    var isTransient: Bool {
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut,
             .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }
}

// MARK: - Type-erased Encodable wrapper

private struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void

    init(_ wrapped: Encodable) {
        _encode = { encoder in
            try wrapped.encode(to: encoder)
        }
    }

    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}
