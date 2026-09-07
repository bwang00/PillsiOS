import Foundation
import SwiftData
import Observation

/// Protocol for the session API methods HistoryViewModel needs. Enables testability.
protocol HistoryAPIProtocol: Sendable {
    func fetchSessions(limit: Int, offset: Int) async throws -> [SessionDTO]
}

extension APIClient: HistoryAPIProtocol {}

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
    private let api: HistoryAPIProtocol
    private var currentOffset = 0
    private let pageSize = 20

    init(modelContext: ModelContext, api: HistoryAPIProtocol = APIClient.shared) {
        self.modelContext = modelContext
        self.api = api
    }

    func loadInitial() async {
        canLoadMore = true
        await fetchFromServer(offset: 0)
    }

    func loadMore() async {
        guard !isLoading, canLoadMore else { return }
        await fetchFromServer(offset: currentOffset + pageSize)
    }

    func refresh() async {
        canLoadMore = true
        await fetchFromServer(offset: 0)
    }

    private func fetchFromServer(offset: Int) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let requestUserID = currentUserID()

        do {
            let dtos = try await api.fetchSessions(
                limit: pageSize,
                offset: offset
            )
            guard currentUserID() == requestUserID else { return }
            // Commit pagination state only after a successful fetch, so a
            // failure keeps the previous offset and a retry re-requests the
            // same page instead of skipping ahead.
            currentOffset = offset

            if dtos.count < pageSize {
                canLoadMore = false
            }

            // Sync to SwiftData
            for dto in dtos {
                let exists = try? modelContext.fetch(
                    FetchDescriptor<Session>(predicate: #Predicate { $0.id == dto.id })
                ).first
                if let exists {
                    exists.apply(dto)
                } else {
                    modelContext.insert(Session(from: dto))
                }
            }
            try? modelContext.save()

            // Reload from cache for consistent ordering
            loadFromCache()
        } catch {
            guard currentUserID() == requestUserID else { return }
            if sessions.isEmpty {
                loadFromCache()
                if sessions.isEmpty {
                    errorMessage = "无法加载历史记录：\(error.localizedDescription)"
                }
            }
        }
    }

    private func currentUserID() -> String? {
        guard let users = try? modelContext.fetch(FetchDescriptor<User>()),
              users.count == 1 else {
            return nil
        }
        return users[0].id
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
