import XCTest
import SwiftData
@testable import Pills

// MARK: - Mocks

private actor MockSessionAPI: BreathingSessionAPI {
    struct Completion: Equatable { let id: String; let durationSeconds: Int }
    private var createCount = 0
    private var idempotencyKeys: [String?] = []
    private var completions: [Completion] = []
    private var creationFailure: Error?
    private var completionFailure: Error?

    func configure(creationFailure: Error? = nil, completionFailure: Error? = nil) {
        self.creationFailure = creationFailure
        self.completionFailure = completionFailure
    }

    func createSession(guideSlug: String, idempotencyKey: String?) async throws -> SessionDTO {
        createCount += 1
        idempotencyKeys.append(idempotencyKey)
        if let creationFailure { throw creationFailure }
        return SessionDTO(
            id: "session-\(createCount)", guide_slug: guideSlug,
            started_at: "2026-01-01T00:00:00Z", completed_at: nil, duration_seconds: nil)
    }

    func completeSession(id: String, durationSeconds: Int) async throws -> SessionDTO {
        completions.append(Completion(id: id, durationSeconds: durationSeconds))
        if let completionFailure { throw completionFailure }
        return SessionDTO(
            id: id, guide_slug: "grounding-butterfly-hug",
            started_at: "2026-01-01T00:00:00Z",
            completed_at: "2026-01-01T00:01:00Z", duration_seconds: durationSeconds)
    }

    func snapshot() -> (createCount: Int, keys: [String?], completions: [Completion]) {
        (createCount, idempotencyKeys, completions)
    }
}

private actor ManualSleeper: BreathingSleeper {
    private var pending: [CheckedContinuation<Void, Error>] = []
    private var isShutdown = false

    func sleep(for duration: Duration) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                if Task.isCancelled || isShutdown { c.resume(throwing: CancellationError()) }
                else { pending.append(c) }
            }
        } onCancel: {
            Task { await self.cancelFirst() }
        }
    }

    @discardableResult func advanceOne() -> Bool {
        guard !pending.isEmpty else { return false }
        pending.removeFirst().resume()
        return true
    }

    func pendingCount() -> Int { pending.count }

    private func cancelFirst() {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume(throwing: CancellationError())
    }

    func shutdown() {
        isShutdown = true
        let p = pending; pending.removeAll()
        p.forEach { $0.resume(throwing: CancellationError()) }
    }
}

@MainActor
private final class RecordingHaptics: HapticPlayer {
    private(set) var taps: [ButterflySide] = []
    private(set) var stopCount = 0
    func tap(_ side: ButterflySide) { taps.append(side) }
    func stop() { stopCount += 1 }
}

// MARK: - Tests

@MainActor
final class ButterflyHugViewModelTests: XCTestCase {
    private var container: ModelContainer!
    private var api: MockSessionAPI!
    private var sleeper: ManualSleeper!
    private var haptics: RecordingHaptics!
    private var tracked: [Task<Void, Never>] = []

    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(
            for: Guide.self, Session.self, PendingSessionCompletion.self,
            configurations: config)
        api = MockSessionAPI()
        sleeper = ManualSleeper()
        haptics = RecordingHaptics()
    }

    override func tearDown() async throws {
        let tasks = tracked; tracked.removeAll()
        tasks.forEach { $0.cancel() }
        for t in tasks { await t.value }
        await sleeper.shutdown()
    }

    private func makeGuide(tapInterval: Double = 1.0) -> Guide {
        Guide(
            id: UUID().uuidString, slug: "grounding-butterfly-hug", category: "grounding",
            title: "蝴蝶拥抱", summary: "", sortOrder: 9, isActive: true,
            configJSON: #"{"mode":"bilateral_tap","tap_interval":\#(tapInterval),"default_duration":60,"min_duration":15}"#)
    }

    private func makeVM(now: @escaping () -> Date = Date.init) -> ButterflyHugViewModel {
        let vm = ButterflyHugViewModel(
            guide: makeGuide(), modelContext: container.mainContext,
            haptics: haptics, api: api, sleeper: sleeper, now: now)
        vm.handleViewAppearance(isAppActive: true)
        return vm
    }

    private func track(_ task: Task<Void, Never>) { tracked.append(task) }

    func test_start_createsSessionWithIdempotencyKey() async {
        let vm = makeVM()
        track(Task { await vm.start() })
        await waitUntil { await self.sleeper.pendingCount() > 0 }
        let snap = await api.snapshot()
        XCTAssertEqual(snap.createCount, 1)
        XCTAssertNotNil(snap.keys.first ?? nil)
        XCTAssertTrue(vm.isRunning)
        _ = vm.stop()
    }

    func test_tapLoop_alternatesSidesAndCounts() async {
        let vm = makeVM()
        track(Task { await vm.start() })
        await waitUntil { await self.sleeper.pendingCount() > 0 }
        // First beat fired on start (left). Advance to trigger right, then left.
        await sleeper.advanceOne()
        await waitUntil { vm.tapCount >= 2 }
        await sleeper.advanceOne()
        await waitUntil { vm.tapCount >= 3 }
        XCTAssertEqual(haptics.taps.prefix(3), [.left, .right, .left])
        XCTAssertEqual(vm.tapCount, 3)
        _ = vm.stop()
    }

    func test_stop_completesSessionWithElapsedSeconds() async {
        var seconds = 0.0
        let base = Date(timeIntervalSince1970: 0)
        let vm = makeVM(now: { base.addingTimeInterval(seconds) })
        track(Task { await vm.start() })
        await waitUntil { await self.sleeper.pendingCount() > 0 }
        seconds = 42
        let stopTask = vm.stop()
        if let stopTask { track(stopTask); await stopTask.value }
        let snap = await api.snapshot()
        XCTAssertEqual(snap.completions.first?.durationSeconds, 42)
        XCTAssertTrue(vm.isFinished)
    }

    func test_stop_queuesCompletionWhenCompleteSessionFails() async {
        await api.configure(completionFailure: NSError(domain: "x", code: 1))
        let vm = makeVM()
        track(Task { await vm.start() })
        await waitUntil { await self.sleeper.pendingCount() > 0 }
        let stopTask = vm.stop()
        if let stopTask { track(stopTask); await stopTask.value }
        let queued = (try? container.mainContext.fetch(
            FetchDescriptor<PendingSessionCompletion>())) ?? []
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.guideSlug, "grounding-butterfly-hug")
    }

    func test_background_stopsRunningSession() async {
        let vm = makeVM()
        track(Task { await vm.start() })
        await waitUntil { await self.sleeper.pendingCount() > 0 }
        let task = vm.handleAppActivity(isActive: false)
        if let task { track(task); await task.value }
        XCTAssertFalse(vm.isRunning)
        XCTAssertTrue(vm.isFinished)
        let snap = await api.snapshot()
        XCTAssertEqual(snap.completions.count, 1)
    }

    func test_startWhenNotVisible_doesNotCreateSession() async {
        let vm = ButterflyHugViewModel(
            guide: makeGuide(), modelContext: container.mainContext,
            haptics: haptics, api: api, sleeper: sleeper)
        // No handleViewAppearance call -> canStart is false.
        await vm.start()
        let snap = await api.snapshot()
        XCTAssertEqual(snap.createCount, 0)
        XCTAssertFalse(vm.isRunning)
    }

    // MARK: - Helper

    private func waitUntil(
        _ description: String = "condition",
        timeout: TimeInterval = 2,
        _ condition: @MainActor () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for \(description)")
    }
}
