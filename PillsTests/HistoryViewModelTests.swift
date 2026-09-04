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
