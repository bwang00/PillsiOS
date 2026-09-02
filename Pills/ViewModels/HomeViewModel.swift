import Foundation
import SwiftData
import Observation

/// ViewModel for the Home screen.
/// Fetches breathing guides and recent sessions from the API, caches locally.
@MainActor
@Observable
final class HomeViewModel {
    var guides: [Guide] = []
    var recentSessions: [Session] = []
    var isLoading = false
    var errorMessage: String?

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func loadData() async {
        isLoading = true
        errorMessage = nil

        do {
            // Fetch guides from server
            let guideDTOs = try await APIClient.shared.fetchGuides(category: "breathing")
            syncGuides(dtos: guideDTOs)

            // Fetch recent sessions
            let sessionDTOs = try await APIClient.shared.fetchSessions(limit: 5)
            syncSessions(dtos: sessionDTOs)
        } catch {
            // Fall back to local cache
            loadFromCache()
            if guides.isEmpty {
                errorMessage = "无法加载数据：\(error.localizedDescription)"
            }
        }

        isLoading = false
    }

    func loadFromCache() {
        let guideDescriptor = FetchDescriptor<Guide>(sortBy: [SortDescriptor(\.sortOrder)])
        guides = (try? modelContext.fetch(guideDescriptor)) ?? []

        let sessionDescriptor = FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)],
            fetchLimit: 5
        )
        recentSessions = (try? modelContext.fetch(sessionDescriptor)) ?? []
    }

    private func syncGuides(dtos: [GuideDTO]) {
        // Upsert guides into SwiftData
        for dto in dtos {
            let existing = try? modelContext.fetch(
                FetchDescriptor<Guide>(predicate: #Predicate { $0.slug == dto.slug })
            ).first
            if let existing {
                existing.displayName = dto.display_name
                existing.description = dto.description
                existing.durationSeconds = dto.duration_seconds
                existing.sortOrder = dto.sort_order
                existing.isActive = dto.is_active
                existing.configJSON = {
                    let data = (try? JSONEncoder().encode(dto.config)) ?? Data()
                    return String(data: data, encoding: .utf8) ?? "{}"
                }()
            } else {
                modelContext.insert(Guide(from: dto))
            }
        }
        try? modelContext.save()

        let descriptor = FetchDescriptor<Guide>(
            predicate: #Predicate { $0.category == "breathing" && $0.isActive },
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        guides = (try? modelContext.fetch(descriptor)) ?? []
    }

    private func syncSessions(dtos: [SessionDTO]) {
        for dto in dtos {
            let existing = try? modelContext.fetch(
                FetchDescriptor<Session>(predicate: #Predicate { $0.id == dto.id })
            ).first
            if existing == nil {
                modelContext.insert(Session(from: dto))
            }
        }
        try? modelContext.save()

        let descriptor = FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)],
            fetchLimit: 5
        )
        recentSessions = (try? modelContext.fetch(descriptor)) ?? []
    }

    // MARK: - Computed properties

    var totalSessions: Int {
        let descriptor = FetchDescriptor<Session>()
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    var streakDays: Int {
        // Count consecutive days with at least one session
        let descriptor = FetchDescriptor<Session>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let all = (try? modelContext.fetch(descriptor)) ?? []
        let calendar = Calendar.current
        var streak = 0
        var checkDate = calendar.startOfDay(for: Date())

        let sessionDates = Set(all.map { calendar.startOfDay(for: $0.createdAt) })
        while sessionDates.contains(checkDate) {
            streak += 1
            checkDate = calendar.date(byAdding: .day, value: -1, to: checkDate)!
        }
        return streak
    }
}
