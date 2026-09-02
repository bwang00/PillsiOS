import Foundation
import SwiftData

/// Guide configuration from the server.
/// Maps to the `guides` table in the FastAPI backend.
@Model
final class Guide {
    @Attribute(.unique) var slug: String
    var category: String
    var displayName: String
    var summary: String
    var durationSeconds: Int
    var sortOrder: Int
    var isActive: Bool
    /// JSON-encoded config object (phase timings, steps, etc.)
    var configJSON: String

    init(
        slug: String,
        category: String,
        displayName: String,
        summary: String,
        durationSeconds: Int,
        sortOrder: Int,
        isActive: Bool,
        configJSON: String
    ) {
        self.slug = slug
        self.category = category
        self.displayName = displayName
        self.summary = summary
        self.durationSeconds = durationSeconds
        self.sortOrder = sortOrder
        self.isActive = isActive
        self.configJSON = configJSON
    }
}

// MARK: - API DTO

struct GuideDTO: Codable {
    let slug: String
    let category: String
    let display_name: String
    let description: String
    let duration_seconds: Int
    let sort_order: Int
    let is_active: Bool
    let config: GuideConfig
}

struct GuideConfig: Codable {
    let phases: [BreathPhase]?
    let steps: [GuideStep]?

    struct BreathPhase: Codable {
        let name: String
        let label: String
        let duration: Double
    }

    struct GuideStep: Codable {
        let name: String
        let label: String
        let duration: Double
    }
}

// MARK: - DTO → Model

extension Guide {
    convenience init(from dto: GuideDTO) {
        let configData = (try? JSONEncoder().encode(dto.config)) ?? Data()
        let configString = String(data: configData, encoding: .utf8) ?? "{}"
        self.init(
            slug: dto.slug,
            category: dto.category,
            displayName: dto.display_name,
            summary: dto.description,
            durationSeconds: dto.duration_seconds,
            sortOrder: dto.sort_order,
            isActive: dto.is_active,
            configJSON: configString
        )
    }

    var phases: [GuideConfig.BreathPhase] {
        guard let data = configJSON.data(using: .utf8),
              let config = try? JSONDecoder().decode(GuideConfig.self, from: data)
        else { return [] }
        return config.phases ?? []
    }
}
