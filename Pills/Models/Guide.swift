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
    // Butterfly hug (bilateral tap) config. Additive + optional so existing
    // breathing/steps configs decode unchanged.
    let mode: String?
    let tap_interval: Double?
    let default_duration: Int?
    let min_duration: Int?

    init(
        phases: [BreathPhase]? = nil,
        steps: [GuideStep]? = nil,
        mode: String? = nil,
        tap_interval: Double? = nil,
        default_duration: Int? = nil,
        min_duration: Int? = nil
    ) {
        self.phases = phases
        self.steps = steps
        self.mode = mode
        self.tap_interval = tap_interval
        self.default_duration = default_duration
        self.min_duration = min_duration
    }

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

/// Decoded, defaulted configuration for the butterfly hug exercise.
struct ButterflyConfig: Equatable {
    let tapInterval: Double
    let defaultDuration: Int
    let minDuration: Int
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

    private var decodedConfig: GuideConfig? {
        guard let data = configJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GuideConfig.self, from: data)
    }

    var phases: [GuideConfig.BreathPhase] {
        decodedConfig?.phases ?? []
    }

    /// Non-nil only for the bilateral-tap butterfly hug guide.
    var butterfly: ButterflyConfig? {
        guard let config = decodedConfig, config.mode == "bilateral_tap" else { return nil }
        return ButterflyConfig(
            tapInterval: config.tap_interval ?? 1.0,
            defaultDuration: config.default_duration ?? 60,
            minDuration: config.min_duration ?? 15
        )
    }

    var isButterflyHug: Bool { butterfly != nil }

    /// A guide the client can actually render: breathing phases OR butterfly hug.
    /// Steps-only guides (e.g. grounding-54321) are not yet renderable.
    var isRenderable: Bool { !phases.isEmpty || isButterflyHug }

    /// Estimated total duration in seconds from phase config
    var estimatedDuration: Int {
        Int(phases.reduce(0.0) { $0 + $1.duration })
    }
}
