import Foundation
import SwiftData
import Observation

protocol ChatAPIProtocol: Sendable {
    func createConversation() async throws -> ConversationDTO
    func fetchConversationDetail(_ id: String) async throws -> ConversationDetailDTO
    func fetchConversations(limit: Int) async throws -> [ConversationDTO]
    func sendMessage(conversationId: String, role: String, content: String) async throws -> MessageDTO
    func sendAIChat(message: String, history: [AIChatHistoryEntry]) async throws -> AIChatResponse
}

extension APIClient: ChatAPIProtocol {}

@MainActor
@Observable
final class ChatViewModel {
    var messages: [ChatMessageItem] = []
    var inputText = ""
    var isSending = false
    var errorMessage: String?
    var conversationId: String?

    private let modelContext: ModelContext
    private let api: ChatAPIProtocol

    struct ChatMessageItem: Identifiable {
        let id: String
        let role: String
        let content: String
        let timestamp: Date
    }

    init(modelContext: ModelContext, api: ChatAPIProtocol = APIClient.shared) {
        self.modelContext = modelContext
        self.api = api
    }

    func loadOrCreateConversation() async {
        if let conversationId {
            await loadConversation(conversationId)
        } else {
            await createNewConversation()
        }
    }

    func createNewConversation() async {
        do {
            let dto = try await api.createConversation()
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
            return try await api.fetchConversations(limit: 20)
        } catch {
            return []
        }
    }

    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if conversationId == nil {
            await createNewConversation()
        }
        guard let conversationId else { return }

        inputText = ""
        isSending = true
        errorMessage = nil

        messages.append(
            ChatMessageItem(
                id: UUID().uuidString,
                role: "user",
                content: text,
                timestamp: Date()
            )
        )

        do {
            _ = try await api.sendMessage(
                conversationId: conversationId,
                role: "user",
                content: text
            )
        } catch {
            print("⚠️ Failed to save user message: \(error)")
        }

        let history = messages.map {
            AIChatHistoryEntry(role: $0.role, content: $0.content)
        }

        do {
            let response = try await api.sendAIChat(message: text, history: history)
            messages.append(
                ChatMessageItem(
                    id: UUID().uuidString,
                    role: "assistant",
                    content: response.reply,
                    timestamp: Date()
                )
            )

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
