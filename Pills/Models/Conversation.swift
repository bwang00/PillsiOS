import Foundation
import SwiftData

/// A conversation with the AI coach.
/// Maps to the `conversations` table in the FastAPI backend.
@Model
final class Conversation {
    @Attribute(.unique) var id: String
    var createdAt: Date
    var updatedAt: Date
    var username: String?
    @Relationship(deleteRule: .cascade) var messages: [ChatMessage]

    init(
        id: String,
        createdAt: Date,
        updatedAt: Date,
        username: String? = nil,
        messages: [ChatMessage] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.username = username
        self.messages = messages
    }
}

/// A single message in a conversation.
@Model
final class ChatMessage {
    @Attribute(.unique) var id: String
    var role: String // "user" or "assistant"
    var content: String
    var createdAt: Date
    var conversation: Conversation?

    init(id: String, role: String, content: String, createdAt: Date) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

// MARK: - API DTOs

struct ConversationDTO: Codable {
    let id: String
    let created_at: String
    let updated_at: String
    let username: String?
}

struct MessageDTO: Codable {
    let id: String?
    let role: String
    let content: String
    let created_at: String?
}

struct ConversationDetailDTO: Codable {
    let id: String
    let created_at: String
    let updated_at: String
    let username: String?
    let messages: [MessageDTO]
}

struct AIChatRequest: Codable {
    let message: String
    let conversation_history: [AIChatHistoryEntry]
    let username: String?
}

struct AIChatHistoryEntry: Codable {
    let role: String
    let content: String
}

struct AIChatResponse: Codable {
    let response: String
}

struct SendMessageRequest: Codable {
    let conversation_id: String
    let role: String
    let content: String
}

// MARK: - DTO → Model

extension Conversation {
    convenience init(from dto: ConversationDTO) {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let created = fmt.date(from: dto.created_at) ?? ISO8601DateFormatter().date(from: dto.created_at) ?? Date()
        let updated = fmt.date(from: dto.updated_at) ?? ISO8601DateFormatter().date(from: dto.updated_at) ?? Date()
        self.init(id: dto.id, createdAt: created, updatedAt: updated, username: dto.username)
    }

    convenience init(from detail: ConversationDetailDTO) {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let created = fmt.date(from: detail.created_at) ?? Date()
        let updated = fmt.date(from: detail.updated_at) ?? Date()
        self.init(id: detail.id, createdAt: created, updatedAt: updated, username: detail.username)
        self.messages = detail.messages.map { dto in
            let msgDate = dto.created_at.flatMap {
                fmt.date(from: $0) ?? ISO8601DateFormatter().date(from: $0)
            } ?? Date()
            return ChatMessage(
                id: dto.id ?? UUID().uuidString,
                role: dto.role,
                content: dto.content,
                createdAt: msgDate
            )
        }
    }
}
