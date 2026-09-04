import Foundation
import SwiftData
import Observation

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
            let guideDTOs = try await APIClient.shared.fetchGuides(category: "breathing")
            syncGuides(dtos: guideDTOs)

            let sessionDTOs = try await APIClient.shared.fetchSessions(limit: 5)
            syncSessions(dtos: sessionDTOs)
        } catch {
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

        var sessionDescriptor = FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        sessionDescriptor.fetchLimit = 5
        recentSessions = (try? modelContext.fetch(sessionDescriptor)) ?? []
    }

    private func syncGuides(dtos: [GuideDTO]) {
        for dto in dtos {
            let existing = try? modelContext.fetch(
                FetchDescriptor<Guide>(predicate: #Predicate { $0.slug == dto.slug })
            ).first
            if let existing {
                existing.title = dto.title
                existing.summary = dto.description
                existing.sortOrder = dto.sort_order
                existing.isActive = dto.active
                let data = (try? JSONEncoder().encode(dto.config)) ?? Data()
                existing.configJSON = String(data: data, encoding: .utf8) ?? "{}"
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

        var descriptor = FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 5
        recentSessions = (try? modelContext.fetch(descriptor)) ?? []
    }

    var totalSessions: Int {
        let descriptor = FetchDescriptor<Session>()
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    var streakDays: Int {
        let descriptor = FetchDescriptor<Session>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        let all = (try? modelContext.fetch(descriptor)) ?? []
        let calendar = Calendar.current
        var streak = 0
        var checkDate = calendar.startOfDay(for: Date())
        let sessionDates = Set(all.map { calendar.startOfDay(for: $0.startedAt) })
        while sessionDates.contains(checkDate) {
            streak += 1
            checkDate = calendar.date(byAdding: .day, value: -1, to: checkDate)!
        }
        return streak
    }

    func displayName(for slug: String) -> String {
        for guide in guides where guide.slug == slug {
            return guide.title
        }
        return slug.replacingOccurrences(of: "-", with: " ").capitalized
    }

    func formatDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let secs = seconds % 60
        return minutes > 0 ? "\(minutes)分\(secs)秒" : "\(secs)秒"
    }
}
