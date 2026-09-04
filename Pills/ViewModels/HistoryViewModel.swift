import Foundation
import SwiftData
import Observation

/// ViewModel for the session history screen.
/// Fetches past sessions from the server with pagination, caches locally.
@MainActor
@Observable
final class HistoryViewModel {
    var sessions: [Session] = []
    var isLoading = false
    var canLoadMore = true
    var errorMessage: String?

    private let modelContext: ModelContext
    private var currentOffset = 0
    private let pageSize = 20

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func loadInitial() async {
        currentOffset = 0
        canLoadMore = true
        await fetchFromServer()
    }

    func loadMore() async {
        guard !isLoading, canLoadMore else { return }
        currentOffset += pageSize
        await fetchFromServer(append: true)
    }

    func refresh() async {
        currentOffset = 0
        canLoadMore = true
        await fetchFromServer()
    }

    private func fetchFromServer(append: Bool = false) async {
        isLoading = true
        errorMessage = nil

        do {
            let dtos = try await APIClient.shared.fetchSessions(
                limit: pageSize,
                offset: currentOffset
            )

            if dtos.count < pageSize {
                canLoadMore = false
            }

            // Sync to SwiftData
            for dto in dtos {
                let exists = try? modelContext.fetch(
                    FetchDescriptor<Session>(predicate: #Predicate { $0.id == dto.id })
                ).first
                if exists == nil {
                    modelContext.insert(Session(from: dto))
                }
            }
            try? modelContext.save()

            // Reload from cache for consistent ordering
            loadFromCache()
        } catch {
            if sessions.isEmpty {
                loadFromCache()
                if sessions.isEmpty {
                    errorMessage = "无法加载历史记录：\(error.localizedDescription)"
                }
            }
        }

        isLoading = false
    }

    private func loadFromCache() {
        let descriptor = FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        sessions = (try? modelContext.fetch(descriptor)) ?? []
    }

    // MARK: - Formatting helpers

    func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter.string(from: date)
    }

    func formatDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let secs = seconds % 60
        if minutes > 0 {
            return "\(minutes)分\(secs)秒"
        }
        return "\(secs)秒"
    }

    func displayName(for slug: String) -> String {
        let descriptor = FetchDescriptor<Guide>(predicate: #Predicate { $0.slug == slug })
        if let guide = try? modelContext.fetch(descriptor).first {
            return guide.title
        }
        // Fallback: humanize slug
        return slug
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }
}
