import Foundation
import SwiftData
import Observation

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

    struct ChatMessageItem: Identifiable {
        let id: String
        let role: String // "user" or "assistant"
        let content: String
        let timestamp: Date
    }

    init(modelContext: ModelContext, username: String?) {
        self.modelContext = modelContext
        self.username = username
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
            let dto = try await APIClient.shared.createConversation(username: username)
            conversationId = dto.id
            messages = []
        } catch {
            errorMessage = "无法创建对话：\(error.localizedDescription)"
        }
    }

    func loadConversation(_ id: String) async {
        do {
            let detail = try await APIClient.shared.fetchConversationDetail(id)
            conversationId = detail.id
            messages = detail.messages.map {
                ChatMessageItem(
                    id: $0.id ?? UUID().uuidString,
                    role: $0.role,
                    content: $0.content,
                    timestamp: ISO8601DateFormatter().date(from: $0.created_at ?? "") ?? Date()
                )
            }
        } catch {
            errorMessage = "无法加载对话：\(error.localizedDescription)"
        }
    }

    func loadConversationList() async -> [ConversationDTO] {
        do {
            return try await APIClient.shared.fetchConversations(username: username, limit: 20)
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
            _ = try await APIClient.shared.sendMessage(
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
            let response = try await APIClient.shared.sendAIChat(
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
                _ = try await APIClient.shared.sendMessage(
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
