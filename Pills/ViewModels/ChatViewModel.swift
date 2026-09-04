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

        NSLog("[ChatVM] sendMessage: '%@' convId=%@", text, conversationId)
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

    // MARK: - Debug helpers

    #if DEBUG
    func populateTestMessages() {
        let samples: [(String, String)] = [
            ("user", "你好，我想了解一下呼吸练习"),
            ("assistant", "你好！很高兴你对呼吸练习感兴趣。我们平台有几种不同的呼吸法，包括4-7-8呼吸法和方块呼吸法。你想了解哪一种？"),
            ("user", "4-7-8呼吸法是什么？"),
            ("assistant", "4-7-8呼吸法是由Andrew Weil博士开发的一种放松技巧。具体步骤是：\n\n1. 用鼻子吸气4秒\n2. 屏住呼吸7秒\n3. 用嘴巴缓慢呼气8秒\n\n这种呼吸法可以帮助快速放松神经系统，特别适合睡前或感到焦虑时使用。"),
            ("user", "方块呼吸呢？"),
            ("assistant", "方块呼吸（也叫箱式呼吸）是一种简单有效的呼吸技巧，四个阶段等长：\n\n• 吸气4秒\n• 屏气4秒\n• 呼气4秒\n• 屏气4秒\n\n就像一个正方形的四条边。这种方法被美国海豹突击队使用，帮助他们在高压环境下保持冷静。"),
            ("user", "我什么时候练习比较好？"),
            ("assistant", "最佳练习时间因人而异，但这里有几个建议：\n\n🌅 早晨：开始新一天前，做几组呼吸练习可以提神醒脑\n🌙 睡前：4-7-8呼吸法特别适合帮助入睡\n😰 感到焦虑时：随时可以做方块呼吸来快速平静下来\n🧘 冥想前：呼吸练习是很好的冥想准备活动\n\n建议先从每天1-2次开始，逐步增加频率。"),
            ("user", "好的，谢谢你的建议！"),
            ("assistant", "不客气！记住，呼吸练习最重要的是坚持。不需要每次很长时间，哪怕每天只做2-3分钟也会有明显的效果。如果你有任何问题，随时可以来找我聊～祝你练习愉快 😊"),
        ]
        messages = samples.enumerated().map { i, item in
            ChatMessageItem(
                id: "test-\(i)",
                role: item.0,
                content: item.1,
                timestamp: Date().addingTimeInterval(Double(i - samples.count) * 60)
            )
        }
    }
    #endif
}
