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

    func completeSession(id: String, durationSeconds: Int, notes: String? = nil) async throws -> SessionDTO {
        let now = ISO8601DateFormatter().string(from: Date())
        let body = CompleteSessionRequest(
            completed_at: now,
            duration_seconds: durationSeconds,
            notes: notes
        )
        return try await patch("/api/sessions/\(id)", body: body)
    }

    func fetchSessions(limit: Int = 20, offset: Int = 0) async throws -> [SessionDTO] {
        return try await get("/api/sessions?limit=\(limit)&offset=\(offset)")
    }

    // MARK: - TTS

    func synthesizeSpeech(_ text: String) async throws -> Data {
        let body: [String: String] = ["text": text]
        let request = makeRequest(path: "/api/tts", method: "POST", body: body)
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
        return data
    }

    // MARK: - Conversations

    func createConversation(username: String? = nil) async throws -> ConversationDTO {
        var path = "/api/conversations"
        if let username { path += "?username=\(username)" }
        return try await post(path, body: Optional<String>.none as String?)
    }

    func sendMessage(conversationId: String, role: String, content: String) async throws -> MessageDTO {
        let body = SendMessageRequest(
            conversation_id: conversationId,
            role: role,
            content: content
        )
        return try await post("/api/conversations/messages", body: body)
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
            conversation_history: history,
            username: username
        )
        return try await post("/api/ai-chat", body: body)
    }

    // MARK: - Private helpers

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let request = makeRequest(path: path, method: "GET", body: Optional<String>.none)
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        let request = makeRequest(path: path, method: "POST", body: body)
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func patch<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        let request = makeRequest(path: path, method: "PATCH", body: body)
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func makeRequest<B: Encodable>(path: String, method: String, body: B) -> URLRequest {
        let url = baseURL.appendingPathComponent(path)
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

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid server response"
        case .httpError(let code, let body):
            return "HTTP \(code): \(body.prefix(200))"
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
