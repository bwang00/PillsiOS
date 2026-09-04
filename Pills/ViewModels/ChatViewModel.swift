import Foundation
import SwiftData
import Observation

/// Protocol for the API methods ChatViewModel needs. Enables testability.
protocol ChatAPIProtocol: Sendable {
    func createConversation(username: String?) async throws -> ConversationDTO
    func fetchConversationDetail(_ id: String) async throws -> ConversationDetailDTO
    func fetchConversations(username: String?, limit: Int) async throws -> [ConversationDTO]
    func sendMessage(conversationId: String, role: String, content: String) async throws -> MessageDTO
    func sendAIChat(message: String, history: [AIChatHistoryEntry], username: String?) async throws -> AIChatResponse
}

extension APIClient: ChatAPIProtocol {}

/// ViewModel for the AI Chat screen.
/// Manages conversation state, message sending, and AI responses.
@MainActor
@Observable
final class ChatViewModel {
    var messages: [ChatMessageItem] = []
    var inputText = ""
    var isSending = false
    var errorMessage: String?
    var conversationId: String?

    private let modelContext: ModelContext
    private let username: String?
    private let api: ChatAPIProtocol

    struct ChatMessageItem: Identifiable {
        let id: String
        let role: String // "user" or "assistant"
        let content: String
        let timestamp: Date
    }

    init(modelContext: ModelContext, username: String?, api: ChatAPIProtocol = APIClient.shared) {
        self.modelContext = modelContext
        self.username = username
        self.api = api
    }

    // MARK: - Conversation management

    func loadOrCreateConversation() async {
        if let conversationId {
            await loadConversation(conversationId)
        } else {
            await createNewConversation()
        }
    }

    func createNewConversation() async {
        do {
            let dto = try await api.createConversation(username: username)
            conversationId = dto.id
            messages = []
        } catch {
            errorMessage = "无法创建对话：\(error.localizedDescription)"
        }
    }

    func loadConversation(_ id: String) async {
        do {
            let detail = try await api.fetchConversationDetail(id)
            conversationId = detail.id
            messages = detail.messages.map {
                ChatMessageItem(
                    id: $0.id,
                    role: $0.role,
                    content: $0.content,
                    timestamp: ISO8601DateFormatter().date(from: $0.created_at) ?? Date()
                )
            }
        } catch {
            errorMessage = "无法加载对话：\(error.localizedDescription)"
        }
    }

    func loadConversationList() async -> [ConversationDTO] {
        do {
            return try await api.fetchConversations(username: username, limit: 20)
        } catch {
            return []
        }
    }

    // MARK: - Send message

    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Auto-create conversation if needed
        if conversationId == nil {
            await createNewConversation()
        }
        guard let conversationId else { return }

        inputText = ""
        isSending = true
        errorMessage = nil

        // Add user message locally
        let userMsg = ChatMessageItem(
            id: UUID().uuidString,
            role: "user",
            content: text,
            timestamp: Date()
        )
        messages.append(userMsg)

        // Save user message to server
        do {
            _ = try await api.sendMessage(
                conversationId: conversationId,
                role: "user",
                content: text
            )
        } catch {
            print("⚠️ Failed to save user message: \(error)")
        }

        // Build conversation history for AI
        let history = messages.map {
            AIChatHistoryEntry(role: $0.role, content: $0.content)
        }

        // Call AI
        do {
            let response = try await api.sendAIChat(
                message: text,
                history: history,
                username: username
            )

            let aiMsg = ChatMessageItem(
                id: UUID().uuidString,
                role: "assistant",
                content: response.reply,
                timestamp: Date()
            )
            messages.append(aiMsg)

            // Save AI message to server
            do {
                _ = try await api.sendMessage(
                    conversationId: conversationId,
                    role: "assistant",
                    content: response.reply
                )
            } catch {
                print("⚠️ Failed to save AI message: \(error)")
            }
        } catch {
            errorMessage = "AI 回复失败：\(error.localizedDescription)"
        }

        isSending = false
    }
}
