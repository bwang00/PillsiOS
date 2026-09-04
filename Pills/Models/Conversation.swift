import Foundation
import SwiftData

/// A conversation with the AI coach.
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
    var role: String
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
    let message_count: Int?
    let first_message: String?
}

struct MessageDTO: Codable {
    let id: String
    let conversation_id: String
    let role: String
    let content: String
    let created_at: String
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
    let history: [AIChatHistoryEntry]
    let username: String?
}

struct AIChatHistoryEntry: Codable {
    let role: String
    let content: String
}

struct AIChatResponse: Codable {
    let reply: String
}

struct SendMessageBody: Codable {
    let role: String
    let content: String
}

struct TTSResponse: Codable {
    let audio_data: String  // base64-encoded MP3
    let format: String
    let size: Int
}

// MARK: - DTO → Model

extension Conversation {
    convenience init(from dto: ConversationDTO) {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fb = ISO8601DateFormatter()
        let created = fmt.date(from: dto.created_at) ?? fb.date(from: dto.created_at) ?? Date()
        let updated = fmt.date(from: dto.updated_at) ?? fb.date(from: dto.updated_at) ?? Date()
        self.init(id: dto.id, createdAt: created, updatedAt: updated, username: dto.username)
    }

    convenience init(from detail: ConversationDetailDTO) {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fb = ISO8601DateFormatter()
        let created = fmt.date(from: detail.created_at) ?? Date()
        let updated = fmt.date(from: detail.updated_at) ?? Date()
        self.init(id: detail.id, createdAt: created, updatedAt: updated, username: detail.username)
        self.messages = detail.messages.map { dto in
            let msgDate = fmt.date(from: dto.created_at) ?? fb.date(from: dto.created_at) ?? Date()
            return ChatMessage(id: dto.id, role: dto.role, content: dto.content, createdAt: msgDate)
        }
    }
}
