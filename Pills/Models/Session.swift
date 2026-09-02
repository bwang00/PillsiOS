import Foundation
import SwiftData

/// A practice session record.
/// Maps to the `sessions` table in the FastAPI backend.
@Model
final class Session {
    @Attribute(.unique) var id: String
    var guideSlug: String
    var createdAt: Date
    var completedAt: Date?
    var durationSeconds: Int?
    var notes: String?

    init(
        id: String,
        guideSlug: String,
        createdAt: Date,
        completedAt: Date? = nil,
        durationSeconds: Int? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.guideSlug = guideSlug
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.durationSeconds = durationSeconds
        self.notes = notes
    }
}

// MARK: - API DTOs

struct SessionDTO: Codable {
    let id: String
    let guide_slug: String?
    let created_at: String
    let completed_at: String?
    let duration_seconds: Int?
    let notes: String?
}

struct CreateSessionRequest: Codable {
    let guide_slug: String
}

struct CompleteSessionRequest: Codable {
    let completed_at: String
    let duration_seconds: Int
    let notes: String?
}

// MARK: - DTO → Model

extension Session {
    convenience init(from dto: SessionDTO) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let created = formatter.date(from: dto.created_at)
            ?? ISO8601DateFormatter().date(from: dto.created_at)
            ?? Date()
        let completed = dto.completed_at.flatMap {
            formatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0)
        }
        self.init(
            id: dto.id,
            guideSlug: dto.guide_slug ?? "",
            createdAt: created,
            completedAt: completed,
            durationSeconds: dto.duration_seconds,
            notes: dto.notes
        )
    }
}
