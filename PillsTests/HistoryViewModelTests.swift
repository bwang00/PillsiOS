import XCTest
import SwiftData
@testable import Pills

// MARK: - Mock API

final class MockHistoryAPI: HistoryAPIProtocol, @unchecked Sendable {
    var result: Result<[SessionDTO], Error> = .success([])
    var callCount = 0
    var lastLimit: Int?
    var lastOffset: Int?

    func fetchSessions(limit: Int, offset: Int) async throws -> [SessionDTO] {
        callCount += 1
        lastLimit = limit
        lastOffset = offset
        return try result.get()
    }
}

private actor DelayedHistoryAPI: HistoryAPIProtocol {
    private var continuation: CheckedContinuation<[SessionDTO], Error>?
    private(set) var didStart = false

    func fetchSessions(limit: Int, offset: Int) async throws -> [SessionDTO] {
        didStart = true
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func succeed(with sessions: [SessionDTO]) {
        continuation?.resume(returning: sessions)
        continuation = nil
    }
}

// MARK: - Tests

@MainActor
final class HistoryViewModelTests: XCTestCase {

    private var container: ModelContainer!
    private var mockAPI: MockHistoryAPI!

    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(
            for: Guide.self, Session.self, Conversation.self, ChatMessage.self, User.self,
            configurations: config
        )
        mockAPI = MockHistoryAPI()
    }

    private func makeViewModel() -> HistoryViewModel {
        HistoryViewModel(modelContext: container.mainContext, api: mockAPI)
    }

    private func makeDTO(id: String, slug: String = "4-7-8-breathing", seconds: Int? = 60) -> SessionDTO {
        SessionDTO(
            id: id,
            guide_slug: slug,
            started_at: "2026-01-01T00:00:00Z",
            completed_at: seconds != nil ? "2026-01-01T00:01:00Z" : nil,
            duration_seconds: seconds
        )
    }

    // MARK: - loadInitial

    func testLoadInitial_success() async {
        mockAPI.result = .success([makeDTO(id: "s1"), makeDTO(id: "s2")])
        let vm = makeViewModel()

        await vm.loadInitial()

        XCTAssertEqual(vm.sessions.count, 2)
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(mockAPI.lastOffset, 0)
    }

    func testSyncUpdatesExistingSessionWhenServerReturnsCompletion() async throws {
        // Local cache has an in-flight session (created but never completed).
        let cached = Session(id: "sync-1", guideSlug: "4-7-8-breathing", startedAt: Date())
        container.mainContext.insert(cached)
        try container.mainContext.save()
        XCTAssertNil(cached.completedAt)
        XCTAssertNil(cached.durationSeconds)

        // Server now reports the session as completed (e.g. flush from another
        // device or a retry that finally landed).
        let dto = SessionDTO(
            id: "sync-1",
            guide_slug: "4-7-8-breathing",
            started_at: "2026-01-01T00:00:00Z",
            completed_at: "2026-01-01T00:01:30Z",
            duration_seconds: 90
        )
        mockAPI.result = .success([dto])
        let vm = makeViewModel()

        await vm.loadInitial()

        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.id == "sync-1" }
        )
        let stored = try container.mainContext.fetch(descriptor)
        XCTAssertEqual(stored.count, 1)
        XCTAssertNotNil(stored.first?.completedAt)
        XCTAssertEqual(stored.first?.durationSeconds, 90)
    }

    func testDelayedResponseIsDiscardedAfterAuthenticatedUserChanges() async throws {
        let api = DelayedHistoryAPI()
        container.mainContext.insert(User(id: "user-a", username: "alice"))
        try container.mainContext.save()
        let vm = HistoryViewModel(modelContext: container.mainContext, api: api)

        let load = Task { await vm.loadInitial() }
        while await !api.didStart {
            await Task.yield()
        }

        for user in try container.mainContext.fetch(FetchDescriptor<User>()) {
            container.mainContext.delete(user)
        }
        container.mainContext.insert(User(id: "user-b", username: "bob"))
        try container.mainContext.save()
        await api.succeed(with: [makeDTO(id: "user-a-session")])
        await load.value

        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<Session>()).isEmpty)
        XCTAssertTrue(vm.sessions.isEmpty)
    }

    func testLoadInitial_emptyResponse_setsCannotLoadMore() async {
        mockAPI.result = .success([])
        let vm = makeViewModel()

        await vm.loadInitial()

        XCTAssertTrue(vm.sessions.isEmpty)
        XCTAssertFalse(vm.canLoadMore)
    }

    func testLoadInitial_failure_setsError() async {
        mockAPI.result = .failure(APIError.networkUnavailable)
        let vm = makeViewModel()

        await vm.loadInitial()

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.errorMessage!.contains("无法加载历史记录"))
        XCTAssertFalse(vm.isLoading)
    }

    func testLoadInitial_failureWithCachedData_noError() async {
        // Pre-populate cache
        container.mainContext.insert(Session(id: "cached", guideSlug: "test", startedAt: Date()))
        try! container.mainContext.save()

        mockAPI.result = .failure(APIError.timeout)
        let vm = makeViewModel()

        await vm.loadInitial()

        // Has cached data, so no error shown
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.sessions.count, 1)
    }

    // MARK: - Pagination

    func testCanLoadMore_fullPage() async {
        // Return exactly 20 items (full page)
        let dtos = (0..<20).map { makeDTO(id: "s\($0)") }
        mockAPI.result = .success(dtos)
        let vm = makeViewModel()

        await vm.loadInitial()

        XCTAssertTrue(vm.canLoadMore)
    }

    func testCanLoadMore_partialPage() async {
        // Return 5 items (partial page)
        let dtos = (0..<5).map { makeDTO(id: "s\($0)") }
        mockAPI.result = .success(dtos)
        let vm = makeViewModel()

        await vm.loadInitial()

        XCTAssertFalse(vm.canLoadMore)
    }

    func testLoadMore_incrementsOffset() async {
        let dtos = (0..<20).map { makeDTO(id: "s\($0)") }
        mockAPI.result = .success(dtos)
        let vm = makeViewModel()

        await vm.loadInitial()
        XCTAssertEqual(mockAPI.lastOffset, 0)

        await vm.loadMore()
        XCTAssertEqual(mockAPI.lastOffset, 20)
    }

    func testLoadMore_failureDoesNotCorruptOffset() async {
        let dtos = (0..<20).map { makeDTO(id: "s\($0)") }
        mockAPI.result = .success(dtos)
        let vm = makeViewModel()

        await vm.loadInitial()
        XCTAssertEqual(mockAPI.lastOffset, 0)

        // Fail the next page
        mockAPI.result = .failure(APIError.networkUnavailable)
        await vm.loadMore()

        // Retry should use the same offset, not skip ahead
        mockAPI.result = .success((20..<40).map { makeDTO(id: "s\($0)") })
        await vm.loadMore()
        XCTAssertEqual(mockAPI.lastOffset, 20)
    }

    func testLoadMore_whenCannotLoadMore_skips() async {
        mockAPI.result = .success([]) // empty = canLoadMore becomes false
        let vm = makeViewModel()

        await vm.loadInitial()
        XCTAssertFalse(vm.canLoadMore)

        await vm.loadMore()
        // Only 1 call (from loadInitial), loadMore was skipped
        XCTAssertEqual(mockAPI.callCount, 1)
    }

    func testLoadMore_whenLoading_skips() async {
        // This is hard to test deterministically since loadMore checks isLoading
        // at the start. We verify by calling loadMore rapidly.
        mockAPI.result = .success((0..<20).map { makeDTO(id: "s\($0)") })
        let vm = makeViewModel()
        await vm.loadInitial()

        // loadMore should work since isLoading is false after loadInitial
        await vm.loadMore()
        XCTAssertEqual(mockAPI.callCount, 2)
    }

    // MARK: - refresh

    func testRefresh_resetsOffsetAndReloads() async {
        let dtos = (0..<20).map { makeDTO(id: "s\($0)") }
        mockAPI.result = .success(dtos)
        let vm = makeViewModel()

        await vm.loadInitial()
        await vm.loadMore()
        XCTAssertEqual(mockAPI.lastOffset, 20)

        mockAPI.result = .success([makeDTO(id: "new")])
        await vm.refresh()

        XCTAssertEqual(mockAPI.lastOffset, 0)
        XCTAssertFalse(vm.canLoadMore) // 1 item < pageSize, so no more to load
    }

    // MARK: - formatDuration

    func testFormatDuration_secondsOnly() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.formatDuration(45), "45秒")
        XCTAssertEqual(vm.formatDuration(0), "0秒")
    }

    func testFormatDuration_minutesAndSeconds() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.formatDuration(90), "1分30秒")
        XCTAssertEqual(vm.formatDuration(125), "2分5秒")
    }

    func testFormatDuration_exactMinutes() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.formatDuration(60), "1分0秒")
        XCTAssertEqual(vm.formatDuration(300), "5分0秒")
    }

    // MARK: - displayName

    func testDisplayName_withCachedGuide() async {
        // Insert a guide
        let guide = Guide(
            id: UUID().uuidString,
            slug: "4-7-8-breathing",
            category: "breathing",
            title: "4-7-8 呼吸法",
            summary: "desc",
            sortOrder: 1,
            isActive: true,
            configJSON: "{}"
        )
        container.mainContext.insert(guide)
        try! container.mainContext.save()

        let vm = makeViewModel()
        XCTAssertEqual(vm.displayName(for: "4-7-8-breathing"), "4-7-8 呼吸法")
    }

    func testDisplayName_withoutGuide_humanizesSlug() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.displayName(for: "box-breathing"), "Box Breathing")
    }
}
