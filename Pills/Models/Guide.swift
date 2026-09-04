import Foundation
import SwiftData

/// Guide configuration from the server.
/// Maps to the `guides` table in the FastAPI backend.
@Model
final class Guide {
    @Attribute(.unique) var id: String
    @Attribute(.unique) var slug: String
    var category: String
    var title: String
    var summary: String
    var sortOrder: Int
    var isActive: Bool
    /// JSON-encoded config object (phase timings, steps, etc.)
    var configJSON: String

    init(
        id: String,
        slug: String,
        category: String,
        title: String,
        summary: String,
        sortOrder: Int,
        isActive: Bool,
        configJSON: String
    ) {
        self.id = id
        self.slug = slug
        self.category = category
        self.title = title
        self.summary = summary
        self.sortOrder = sortOrder
        self.isActive = isActive
        self.configJSON = configJSON
    }
}

// MARK: - API DTO

struct GuideDTO: Codable {
    let id: String
    let slug: String
    let title: String
    let description: String
    let category: String
    let sort_order: Int
    let active: Bool
    let config: GuideConfig
}

struct GuideConfig: Codable {
    let phases: [BreathPhase]?
    let steps: [GuideStep]?

    struct BreathPhase: Codable {
        let name: String     // Chinese: "吸气", "闭气", "呼气"
        let duration: Double
    }

    struct GuideStep: Codable {
        let sense: String?
        let count: Int?
        let prompt: String?
        let body_part: String?
        let tense_duration: Double?
        let relax_duration: Double?
        let tense_prompt: String?
        let relax_prompt: String?
    }
}

// MARK: - DTO → Model

extension Guide {
    convenience init(from dto: GuideDTO) {
        let configData = (try? JSONEncoder().encode(dto.config)) ?? Data()
        let configString = String(data: configData, encoding: .utf8) ?? "{}"
        self.init(
            id: dto.id,
            slug: dto.slug,
            category: dto.category,
            title: dto.title,
            summary: dto.description,
            sortOrder: dto.sort_order,
            isActive: dto.active,
            configJSON: configString
        )
    }

    var phases: [GuideConfig.BreathPhase] {
        guard let data = configJSON.data(using: .utf8),
              let config = try? JSONDecoder().decode(GuideConfig.self, from: data)
        else { return [] }
        return config.phases ?? []
    }

    /// Estimated total duration in seconds from phase config
    var estimatedDuration: Int {
        Int(phases.reduce(0.0) { $0 + $1.duration })
    }
}
