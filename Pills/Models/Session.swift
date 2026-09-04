import Foundation
import SwiftData

/// A practice session record.
@Model
final class Session {
    @Attribute(.unique) var id: String
    var guideSlug: String
    var startedAt: Date
    var completedAt: Date?
    var durationSeconds: Int?

    init(
        id: String,
        guideSlug: String,
        startedAt: Date,
        completedAt: Date? = nil,
        durationSeconds: Int? = nil
    ) {
        self.id = id
        self.guideSlug = guideSlug
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.durationSeconds = durationSeconds
    }
}

// MARK: - API DTOs

struct SessionDTO: Codable {
    let id: String
    let guide_slug: String
    let started_at: String
    let completed_at: String?
    let duration_seconds: Int?
}

struct SessionsListResponse: Codable {
    let sessions: [SessionDTO]
    let total: Int
}

struct CreateSessionRequest: Codable {
    let guide_slug: String
}

struct CompleteSessionRequest: Codable {
    let completed_at: String?
    let duration_seconds: Int?
}

// MARK: - DTO → Model

extension Session {
    convenience init(from dto: SessionDTO) {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFmt = ISO8601DateFormatter()
        let started = fmt.date(from: dto.started_at) ?? fallbackFmt.date(from: dto.started_at) ?? Date()
        let completed = dto.completed_at.flatMap {
            fmt.date(from: $0) ?? fallbackFmt.date(from: $0)
        }
        self.init(
            id: dto.id,
            guideSlug: dto.guide_slug,
            startedAt: started,
            completedAt: completed,
            durationSeconds: dto.duration_seconds
        )
    }
}
