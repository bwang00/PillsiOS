import XCTest
import SwiftData
@testable import Pills

// MARK: - Mock API

final class MockHomeAPI: HomeAPIProtocol, @unchecked Sendable {
    var guidesResult: Result<[GuideDTO], Error> = .success([])
    var sessionsResult: Result<[SessionDTO], Error> = .success([])
    var fetchGuidesCallCount = 0
    var fetchSessionsCallCount = 0
    var lastGuideCategory: String?
    var lastSessionLimit: Int?
    var lastSessionOffset: Int?

    func fetchGuides(category: String?) async throws -> [GuideDTO] {
        fetchGuidesCallCount += 1
        lastGuideCategory = category
        return try guidesResult.get()
    }

    func fetchSessions(limit: Int, offset: Int) async throws -> [SessionDTO] {
        fetchSessionsCallCount += 1
        lastSessionLimit = limit
        lastSessionOffset = offset
        return try sessionsResult.get()
    }
}

private actor DelayedHomeAPI: HomeAPIProtocol {
    private var continuation: CheckedContinuation<[GuideDTO], Error>?
    private(set) var didStartGuides = false

    func fetchGuides(category: String?) async throws -> [GuideDTO] {
        didStartGuides = true
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func fetchSessions(limit: Int, offset: Int) async throws -> [SessionDTO] { [] }

    func succeed(with guides: [GuideDTO]) {
        continuation?.resume(returning: guides)
        continuation = nil
    }
}

// MARK: - Tests

@MainActor
final class HomeViewModelTests: XCTestCase {

    private var container: ModelContainer!
    private var mockAPI: MockHomeAPI!

    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(
            for: Guide.self, Session.self, Conversation.self, ChatMessage.self, User.self,
            PendingSessionCompletion.self,
            configurations: config
        )
        mockAPI = MockHomeAPI()
    }

    override func tearDown() {
        container = nil
        mockAPI = nil
        super.tearDown()
    }

    private func makeViewModel() -> HomeViewModel {
        HomeViewModel(modelContext: container.mainContext, api: mockAPI)
    }

    private func makeGuideDTO(
        id: String = "g1",
        slug: String = "4-7-8-breathing",
        category: String = "breathing",
        title: String = "4-7-8 呼吸法",
        sortOrder: Int = 1,
        active: Bool = true,
        phases: [GuideConfig.BreathPhase]? = nil
    ) -> GuideDTO {
        GuideDTO(
            id: id,
            slug: slug,
            title: title,
            description: "描述",
            category: category,
            sort_order: sortOrder,
            active: active,
            config: GuideConfig(phases: phases, steps: nil)
        )
    }

    private func makeSessionDTO(
        id: String,
        slug: String = "4-7-8-breathing",
        startedAt: String = "2026-01-01T00:00:00Z",
        completedAt: String? = "2026-01-01T00:01:00Z",
        seconds: Int? = 60
    ) -> SessionDTO {
        SessionDTO(
            id: id,
            guide_slug: slug,
            started_at: startedAt,
            completed_at: completedAt,
            duration_seconds: seconds
        )
    }

    // MARK: - loadData success

    func testLoadData_success_populatesGuidesAndSessions() async {
        mockAPI.guidesResult = .success([
            makeGuideDTO(id: "g1", slug: "4-7-8-breathing", sortOrder: 1),
            makeGuideDTO(id: "g2", slug: "box-breathing", title: "箱式呼吸", sortOrder: 2)
        ])
        mockAPI.sessionsResult = .success([
            makeSessionDTO(id: "s1"),
            makeSessionDTO(id: "s2")
        ])
        let vm = makeViewModel()

        await vm.loadData()

        XCTAssertEqual(vm.guides.count, 2)
        XCTAssertEqual(vm.recentSessions.count, 2)
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.errorMessage)
    }

    func testLoadData_requestsBreathingCategoryWithLimitFive() async {
        let vm = makeViewModel()

        await vm.loadData()

        XCTAssertEqual(mockAPI.lastGuideCategory, "breathing")
        XCTAssertEqual(mockAPI.lastSessionLimit, 5)
        XCTAssertEqual(mockAPI.lastSessionOffset, 0)
    }

    func testLoadData_filtersInactiveAndOtherCategoryGuides() async {
        mockAPI.guidesResult = .success([
            makeGuideDTO(id: "g1", slug: "active-breathing", sortOrder: 1, active: true),
            makeGuideDTO(id: "g2", slug: "inactive-breathing", sortOrder: 2, active: false),
            makeGuideDTO(id: "g3", slug: "body-scan", category: "meditation", sortOrder: 3)
        ])
        let vm = makeViewModel()

        await vm.loadData()

        // All three are persisted, but only active breathing guides surface.
        XCTAssertEqual(vm.guides.map(\.slug), ["active-breathing"])
        let stored = (try? container.mainContext.fetch(FetchDescriptor<Guide>())) ?? []
        XCTAssertEqual(stored.count, 3)
    }

    func testSyncGuides_updatesExistingGuideInPlace() async throws {
        let existing = Guide(
            id: "old-id",
            slug: "4-7-8-breathing",
            category: "breathing",
            title: "旧标题",
            summary: "旧描述",
            sortOrder: 9,
            isActive: true,
            configJSON: "{}"
        )
        container.mainContext.insert(existing)
        try container.mainContext.save()

        mockAPI.guidesResult = .success([
            makeGuideDTO(id: "g1", slug: "4-7-8-breathing", title: "新标题", sortOrder: 1)
        ])
        let vm = makeViewModel()

        await vm.loadData()

        let stored = try container.mainContext.fetch(FetchDescriptor<Guide>())
        XCTAssertEqual(stored.count, 1, "Existing guide must be updated, not duplicated")
        XCTAssertEqual(stored.first?.title, "新标题")
        XCTAssertEqual(stored.first?.sortOrder, 1)
    }

    func testSyncSessions_updatesExistingSessionCompletion() async throws {
        let cached = Session(id: "sync-1", guideSlug: "4-7-8-breathing", startedAt: Date())
        container.mainContext.insert(cached)
        try container.mainContext.save()
        XCTAssertNil(cached.completedAt)

        mockAPI.sessionsResult = .success([
            makeSessionDTO(id: "sync-1", seconds: 90)
        ])
        let vm = makeViewModel()

        await vm.loadData()

        let stored = try container.mainContext.fetch(FetchDescriptor<Session>())
        XCTAssertEqual(stored.count, 1)
        XCTAssertNotNil(stored.first?.completedAt)
        XCTAssertEqual(stored.first?.durationSeconds, 90)
    }

    // MARK: - loadData failure & cache fallback

    func testLoadData_failureWithEmptyCache_setsError() async {
        mockAPI.guidesResult = .failure(APIError.networkUnavailable)
        let vm = makeViewModel()

        await vm.loadData()

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.errorMessage!.contains("无法加载数据"))
        XCTAssertFalse(vm.isLoading)
    }

    func testLoadData_failureWithCachedGuides_fallsBackWithoutError() async throws {
        // Seed cache with an active breathing guide.
        container.mainContext.insert(Guide(
            id: "g1", slug: "4-7-8-breathing", category: "breathing",
            title: "4-7-8 呼吸法", summary: "d", sortOrder: 1, isActive: true, configJSON: "{}"
        ))
        try container.mainContext.save()

        mockAPI.guidesResult = .failure(APIError.timeout)
        let vm = makeViewModel()

        await vm.loadData()

        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.guides.count, 1)
    }

    func testDelayedGuideResponse_discardedAfterUserChanges() async throws {
        let api = DelayedHomeAPI()
        container.mainContext.insert(User(id: "user-a", username: "alice"))
        try container.mainContext.save()
        let vm = HomeViewModel(modelContext: container.mainContext, api: api)

        let load = Task { await vm.loadData() }
        // Bounded, real-deadline wait (mirrors TTSPlayerTests.waitUntil). On the
        // never-expected timeout we fail and return WITHOUT awaiting load.value,
        // so a stuck continuation cannot hang the whole suite.
        guard await waitUntil("fetchGuides to start", condition: { await api.didStartGuides }) else {
            load.cancel()
            return
        }

        for user in try container.mainContext.fetch(FetchDescriptor<User>()) {
            container.mainContext.delete(user)
        }
        container.mainContext.insert(User(id: "user-b", username: "bob"))
        try container.mainContext.save()

        await api.succeed(with: [makeGuideDTO(id: "g1", slug: "user-a-guide")])
        await load.value

        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<Guide>()).isEmpty)
        XCTAssertTrue(vm.guides.isEmpty)
    }

    // MARK: - Derived statistics

    func testTotalSessions_countsAllRows() async throws {
        let now = Date()
        for i in 0..<3 {
            container.mainContext.insert(
                Session(id: "s\(i)", guideSlug: "4-7-8-breathing", startedAt: now)
            )
        }
        try container.mainContext.save()
        let vm = makeViewModel()

        XCTAssertEqual(vm.totalSessions, 3)
    }

    func testStreakDays_consecutiveDaysFromToday() async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        for offset in 0..<3 {
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            container.mainContext.insert(
                Session(id: "s\(offset)", guideSlug: "g", startedAt: day)
            )
        }
        try container.mainContext.save()
        let vm = makeViewModel()

        XCTAssertEqual(vm.streakDays, 3)
    }

    func testStreakDays_gapBreaksStreak() async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        // Today and two days ago, skipping yesterday → streak of 1.
        let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: today)!
        container.mainContext.insert(Session(id: "s0", guideSlug: "g", startedAt: today))
        container.mainContext.insert(Session(id: "s1", guideSlug: "g", startedAt: twoDaysAgo))
        try container.mainContext.save()
        let vm = makeViewModel()

        XCTAssertEqual(vm.streakDays, 1)
    }

    func testStreakDays_noSessionToday_isZero() async throws {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date()))!
        container.mainContext.insert(Session(id: "s0", guideSlug: "g", startedAt: yesterday))
        try container.mainContext.save()
        let vm = makeViewModel()

        XCTAssertEqual(vm.streakDays, 0)
    }

    // MARK: - Formatting helpers

    func testDisplayName_prefersCachedGuideTitle() async {
        mockAPI.guidesResult = .success([
            makeGuideDTO(slug: "box-breathing", title: "箱式呼吸")
        ])
        let vm = makeViewModel()
        await vm.loadData()

        XCTAssertEqual(vm.displayName(for: "box-breathing"), "箱式呼吸")
    }

    func testDisplayName_humanizesUnknownSlug() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.displayName(for: "deep-calm-breath"), "Deep Calm Breath")
    }

    func testFormatDuration_variants() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.formatDuration(0), "0秒")
        XCTAssertEqual(vm.formatDuration(45), "45秒")
        XCTAssertEqual(vm.formatDuration(60), "1分0秒")
        XCTAssertEqual(vm.formatDuration(125), "2分5秒")
    }

    // MARK: - Test helpers

    /// Polls `condition` until a real deadline. On timeout it fails the test and
    /// returns false so the caller can bail out instead of hanging on a
    /// continuation that may never be resumed.
    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }

        if await condition() { return true }
        XCTFail("Timed out waiting for \(description)")
        return false
    }
}
