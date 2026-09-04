import XCTest
import SwiftData
@testable import Pills

private actor MockBreathingSessionAPI: BreathingSessionAPI {
    struct Completion: Sendable, Equatable {
        let sessionID: String
        let durationSeconds: Int
    }

    struct Snapshot: Sendable {
        let createSessionCallCount: Int
        let completions: [Completion]
    }

    private struct PendingCreation {
        let sessionID: String
        let guideSlug: String
        let continuation: CheckedContinuation<SessionDTO, Error>
    }

    private struct PendingCompletion {
        let completion: Completion
        let continuation: CheckedContinuation<SessionDTO, Error>
    }

    private var shouldSuspendCreation = false
    private var shouldSuspendCompletion = false
    private var createSessionCallCount = 0
    private var completions: [Completion] = []
    private var pendingCreations: [PendingCreation] = []
    private var pendingCompletions: [PendingCompletion] = []

    func configure(suspendCreation: Bool = false, suspendCompletion: Bool = false) {
        shouldSuspendCreation = suspendCreation
        shouldSuspendCompletion = suspendCompletion
    }

    func createSession(guideSlug: String) async throws -> SessionDTO {
        createSessionCallCount += 1
        let sessionID = "session-\(createSessionCallCount)"

        if shouldSuspendCreation {
            return try await withCheckedThrowingContinuation { continuation in
                pendingCreations.append(
                    PendingCreation(
                        sessionID: sessionID,
                        guideSlug: guideSlug,
                        continuation: continuation
                    )
                )
            }
        }
        return makeSession(id: sessionID, guideSlug: guideSlug)
    }

    func completeSession(id: String, durationSeconds: Int) async throws -> SessionDTO {
        let completion = Completion(sessionID: id, durationSeconds: durationSeconds)
        completions.append(completion)

        if shouldSuspendCompletion {
            return try await withCheckedThrowingContinuation { continuation in
                pendingCompletions.append(
                    PendingCompletion(completion: completion, continuation: continuation)
                )
            }
        }
        return makeCompletedSession(completion)
    }

    func resumeAllCreations() {
        let creations = pendingCreations
        pendingCreations.removeAll()
        for creation in creations {
            creation.continuation.resume(
                returning: makeSession(id: creation.sessionID, guideSlug: creation.guideSlug)
            )
        }
    }

    func resumeAllCompletions() {
        let pending = pendingCompletions
        pendingCompletions.removeAll()
        for completion in pending {
            completion.continuation.resume(returning: makeCompletedSession(completion.completion))
        }
    }

    func shutdown() {
        shouldSuspendCreation = false
        shouldSuspendCompletion = false
        resumeAllCreations()
        resumeAllCompletions()
    }

    func snapshot() -> Snapshot {
        Snapshot(
            createSessionCallCount: createSessionCallCount,
            completions: completions
        )
    }

    private func makeCompletedSession(_ completion: Completion) -> SessionDTO {
        makeSession(
            id: completion.sessionID,
            guideSlug: "test-breathing",
            completedAt: "2026-01-01T00:00:01Z",
            durationSeconds: completion.durationSeconds
        )
    }

    private func makeSession(
        id: String,
        guideSlug: String,
        completedAt: String? = nil,
        durationSeconds: Int? = nil
    ) -> SessionDTO {
        SessionDTO(
            id: id,
            guide_slug: guideSlug,
            started_at: "2026-01-01T00:00:00Z",
            completed_at: completedAt,
            duration_seconds: durationSeconds
        )
    }
}

private actor ControllableBreathingSleeper: BreathingSleeper {
    private struct PendingSleep {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var pendingSleeps: [PendingSleep] = []
    private var isShutdown = false

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled || isShutdown {
                    continuation.resume(throwing: CancellationError())
                } else {
                    pendingSleeps.append(PendingSleep(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelSleep(id: id) }
        }
    }

    @discardableResult
    func advanceOne() -> Bool {
        guard !pendingSleeps.isEmpty else { return false }
        let pendingSleep = pendingSleeps.removeFirst()
        pendingSleep.continuation.resume()
        return true
    }

    func resumeAll() {
        let sleeps = pendingSleeps
        pendingSleeps.removeAll()
        for sleep in sleeps {
            sleep.continuation.resume()
        }
    }

    func shutdown() {
        isShutdown = true
        let sleeps = pendingSleeps
        pendingSleeps.removeAll()
        for sleep in sleeps {
            sleep.continuation.resume(throwing: CancellationError())
        }
    }

    func pendingCount() -> Int {
        pendingSleeps.count
    }

    private func cancelSleep(id: UUID) {
        guard let index = pendingSleeps.firstIndex(where: { $0.id == id }) else { return }
        let pendingSleep = pendingSleeps.remove(at: index)
        pendingSleep.continuation.resume(throwing: CancellationError())
    }
}

private actor TaskCompletionProbe {
    private var isFinished = false

    func finish() {
        isFinished = true
    }

    func snapshot() -> Bool {
        isFinished
    }
}

@MainActor
final class BreathingViewModelTests: XCTestCase {
    private var container: ModelContainer!
    private var ttsAPI: MockTTSAPI!
    private var ttsPlayer: TTSPlayer!
    private var sessionAPI: MockBreathingSessionAPI!
    private var sleeper: ControllableBreathingSleeper!
    private var tasksUnderTest: [Task<Void, Never>] = []
    private var completionObservers: [Task<Void, Never>] = []

    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(
            for: Guide.self, Session.self, Conversation.self, ChatMessage.self, User.self,
            configurations: config
        )
        ttsAPI = MockTTSAPI()
        ttsPlayer = TTSPlayer(api: ttsAPI)
        sessionAPI = MockBreathingSessionAPI()
        sleeper = ControllableBreathingSleeper()
    }

    override func tearDown() async throws {
        let unfinishedTasks = tasksUnderTest
        let unfinishedObservers = completionObservers
        unfinishedTasks.forEach { $0.cancel() }
        unfinishedObservers.forEach { $0.cancel() }
        await sessionAPI.shutdown()
        await ttsAPI.shutdown()
        await sleeper.shutdown()
        ttsPlayer.stop()

        let cleanup = expectation(description: "tracked breathing tasks cleaned up")
        let cleanupProbe = TaskCompletionProbe()
        let cleanupObserver = Task {
            for task in unfinishedTasks {
                await task.value
            }
            for observer in unfinishedObservers {
                await observer.value
            }
            guard !Task.isCancelled else { return }
            await cleanupProbe.finish()
            cleanup.fulfill()
        }
        await fulfillment(of: [cleanup], timeout: 2)
        if !(await cleanupProbe.snapshot()) {
            XCTFail("Timed out cleaning up tracked breathing tasks")
            cleanupObserver.cancel()
        }

        tasksUnderTest.removeAll()
        completionObservers.removeAll()
        ttsAPI = nil
        ttsPlayer = nil
        sessionAPI = nil
        sleeper = nil
        container = nil
        try await super.tearDown()
    }

    func testCycleLoop_afterTwoPhasesReturnsToFirstPhase() async {
        let viewModel = makeVisibleActiveViewModel(phases: [("吸气", 0.05), ("呼气", 0.05)])

        guard await start(viewModel) else { return }
        guard await waitForPendingSleep("inhale phase step") else { return }
        let advancedInhale = await sleeper.advanceOne()
        XCTAssertTrue(advancedInhale)

        let reachedExhale = await waitUntil("exhale phase") {
            let pendingCount = await self.sleeper.pendingCount()
            return viewModel.phase == .exhale && pendingCount == 1
        }
        guard reachedExhale else { return }
        let advancedExhale = await sleeper.advanceOne()
        XCTAssertTrue(advancedExhale)

        let startedNextCycle = await waitUntil("next inhale cycle") {
            let pendingCount = await self.sleeper.pendingCount()
            return viewModel.currentCycle >= 1
                && viewModel.phase == .inhale
                && pendingCount == 1
        }
        guard startedNextCycle else { return }

        XCTAssertTrue(viewModel.isRunning)
        XCTAssertEqual(viewModel.phase, .inhale)
        XCTAssertGreaterThanOrEqual(viewModel.currentCycle, 1)
        let stopTask = viewModel.stop()
        guard await waitForCompletion(of: stopTask, "cycle loop cleanup stop") else { return }
    }

    func testStop_preventsFurtherPhaseProgress() async {
        let viewModel = makeVisibleActiveViewModel(phases: [("吸气", 0.15)])
        guard await start(viewModel) else { return }
        guard await waitForPendingSleep("first inhale step") else { return }
        let advancedFirstStep = await sleeper.advanceOne()
        XCTAssertTrue(advancedFirstStep)
        let madeProgress = await waitUntil("first inhale progress update") {
            viewModel.phaseProgress > 0
        }
        guard madeProgress else { return }

        let stopTask = viewModel.stop()
        guard await waitForCompletion(of: stopTask, "phase progress stop") else { return }
        let phaseAtStop = viewModel.phase
        let progressAtStop = viewModel.phaseProgress
        let cycleAtStop = viewModel.currentCycle
        await sleeper.resumeAll()

        XCTAssertEqual(viewModel.phase, phaseAtStop)
        XCTAssertEqual(viewModel.phaseProgress, progressAtStop)
        XCTAssertEqual(viewModel.currentCycle, cycleAtStop)
    }

    func testRapidRepeatedStart_createsOnlyOneSession() async {
        await sessionAPI.configure(suspendCreation: true)
        let viewModel = makeVisibleActiveViewModel(phases: [("吸气", 1)])

        let firstStart = Task { await viewModel.start() }
        tasksUnderTest.append(firstStart)
        let creationStarted = await waitUntil("first session creation to start") {
            await self.sessionAPI.snapshot().createSessionCallCount == 1
        }
        guard creationStarted else { return }
        guard await start(viewModel) else { return }

        let startingSnapshot = await sessionAPI.snapshot()
        XCTAssertEqual(startingSnapshot.createSessionCallCount, 1)

        await sessionAPI.resumeAllCreations()
        guard await waitForCompletion(of: firstStart, "first start to finish") else { return }
        let stopTask = viewModel.stop()
        guard await waitForCompletion(of: stopTask, "rapid-start cleanup stop") else { return }
    }

    func testRepeatedStop_completesCreatedSessionOnlyOnceEvenAtZeroSeconds() async {
        let viewModel = makeVisibleActiveViewModel(phases: [("吸气", 1)])
        guard await start(viewModel) else { return }

        let firstStop = viewModel.stop()
        let secondStop = viewModel.stop()
        guard await waitForCompletion(of: firstStop, "first repeated stop") else { return }
        XCTAssertNil(secondStop)

        let snapshot = await sessionAPI.snapshot()
        XCTAssertEqual(
            snapshot.completions,
            [.init(sessionID: "session-1", durationSeconds: 0)]
        )
    }

    func testStop_freezesElapsedAndBlocksRestartUntilCompletionFinishes() async {
        var now = Date(timeIntervalSince1970: 100)
        await sessionAPI.configure(suspendCompletion: true)
        let viewModel = makeVisibleActiveViewModel(
            phases: [("吸气", 10)],
            now: { now }
        )
        guard await start(viewModel) else { return }
        now = Date(timeIntervalSince1970: 102.9)

        let stopTask = viewModel.stop()
        let completionStarted = await waitUntil("first session completion to start") {
            await self.sessionAPI.snapshot().completions.count == 1
        }
        guard completionStarted else { return }

        XCTAssertTrue(viewModel.isRunning)
        now = Date(timeIntervalSince1970: 500)
        guard await start(viewModel) else { return }
        let stoppingSnapshot = await sessionAPI.snapshot()
        XCTAssertEqual(stoppingSnapshot.createSessionCallCount, 1)

        await sessionAPI.resumeAllCompletions()
        guard await waitForCompletion(of: stopTask, "first stop to finish") else { return }

        let completedSnapshot = await sessionAPI.snapshot()
        XCTAssertFalse(viewModel.isRunning)
        XCTAssertEqual(viewModel.elapsedSeconds, 2)
        XCTAssertEqual(
            completedSnapshot.completions,
            [.init(sessionID: "session-1", durationSeconds: 2)]
        )
    }

    func testManualStopClaimsGenerationSynchronouslyBeforeFinalizationTaskRuns() async {
        var now = Date(timeIntervalSince1970: 100)
        await sessionAPI.configure(suspendCompletion: true)
        let viewModel = makeVisibleActiveViewModel(
            phases: [("吸气", 10)],
            now: { now }
        )
        guard await start(viewModel) else { return }
        now = Date(timeIntervalSince1970: 102.9)

        let firstStop = viewModel.stop()

        XCTAssertEqual(viewModel.elapsedSeconds, 2)
        _ = viewModel.handleAppActivity(isActive: true)
        let blockedRestart = Task { await viewModel.start() }
        guard await waitForCompletion(of: blockedRestart, "restart blocked by session-1 stop") else {
            return
        }
        var snapshot = await sessionAPI.snapshot()
        XCTAssertEqual(snapshot.createSessionCallCount, 1)

        let firstCompletionStarted = await waitUntil("session-1 manual completion to start") {
            await self.sessionAPI.snapshot().completions.count == 1
        }
        guard firstCompletionStarted else { return }
        await sessionAPI.resumeAllCompletions()
        guard await waitForCompletion(of: firstStop, "session-1 manual stop to finish") else {
            return
        }

        now = Date(timeIntervalSince1970: 200)
        let secondStart = Task { await viewModel.start() }
        guard await waitForCompletion(of: secondStart, "session-2 start") else { return }
        snapshot = await sessionAPI.snapshot()
        XCTAssertEqual(snapshot.createSessionCallCount, 2)
        XCTAssertTrue(viewModel.isRunning)

        guard await waitForCompletion(of: firstStop, "completed session-1 stop remains inert") else {
            return
        }
        snapshot = await sessionAPI.snapshot()
        XCTAssertEqual(snapshot.createSessionCallCount, 2)
        XCTAssertTrue(viewModel.isRunning)

        now = Date(timeIntervalSince1970: 204.2)
        let secondStop = viewModel.stop()
        let secondCompletionStarted = await waitUntil("session-2 manual completion to start") {
            await self.sessionAPI.snapshot().completions.count == 2
        }
        guard secondCompletionStarted else { return }
        await sessionAPI.resumeAllCompletions()
        guard await waitForCompletion(of: secondStop, "session-2 manual stop to finish") else {
            return
        }

        let finalSnapshot = await sessionAPI.snapshot()
        XCTAssertEqual(finalSnapshot.createSessionCallCount, 2)
        XCTAssertEqual(
            finalSnapshot.completions,
            [
                .init(sessionID: "session-1", durationSeconds: 2),
                .init(sessionID: "session-2", durationSeconds: 4)
            ]
        )
    }

    func testLifecycleStopClaimsSessionSynchronouslyAndKeepsEachCompletionOwnedByItsSession() async {
        var now = Date(timeIntervalSince1970: 100)
        await sessionAPI.configure(suspendCompletion: true)
        let viewModel = makeVisibleActiveViewModel(
            phases: [("吸气", 10)],
            now: { now }
        )
        guard await start(viewModel) else { return }
        now = Date(timeIntervalSince1970: 102.9)

        let lifecycleStop = viewModel.handleAppActivity(isActive: false)

        XCTAssertEqual(viewModel.elapsedSeconds, 2)
        _ = viewModel.handleAppActivity(isActive: true)
        guard await start(viewModel) else { return }
        var snapshot = await sessionAPI.snapshot()
        XCTAssertEqual(snapshot.createSessionCallCount, 1)

        let firstCompletionStarted = await waitUntil("session-1 completion to start") {
            await self.sessionAPI.snapshot().completions.count == 1
        }
        guard firstCompletionStarted else { return }
        snapshot = await sessionAPI.snapshot()
        XCTAssertEqual(
            snapshot.completions,
            [.init(sessionID: "session-1", durationSeconds: 2)]
        )

        await sessionAPI.resumeAllCompletions()
        guard await waitForCompletion(of: lifecycleStop, "session-1 lifecycle stop to finish") else {
            return
        }

        now = Date(timeIntervalSince1970: 200)
        guard await start(viewModel) else { return }
        snapshot = await sessionAPI.snapshot()
        XCTAssertEqual(snapshot.createSessionCallCount, 2)
        XCTAssertTrue(viewModel.isRunning)

        now = Date(timeIntervalSince1970: 204.2)
        let secondStop = viewModel.stop()
        let secondCompletionStarted = await waitUntil("session-2 completion to start") {
            await self.sessionAPI.snapshot().completions.count == 2
        }
        guard secondCompletionStarted else { return }
        snapshot = await sessionAPI.snapshot()
        XCTAssertEqual(
            snapshot.completions,
            [
                .init(sessionID: "session-1", durationSeconds: 2),
                .init(sessionID: "session-2", durationSeconds: 4)
            ]
        )

        await sessionAPI.resumeAllCompletions()
        guard await waitForCompletion(of: secondStop, "session-2 stop to finish") else { return }

        let finalSnapshot = await sessionAPI.snapshot()
        XCTAssertFalse(viewModel.isRunning)
        XCTAssertEqual(finalSnapshot.createSessionCallCount, 2)
        XCTAssertEqual(finalSnapshot.completions.count, 2)
    }

    func testInactiveDuringSessionCreation_completesCreatedSessionWithoutStartingLoop() async {
        await sessionAPI.configure(suspendCreation: true)
        let viewModel = makeVisibleActiveViewModel(phases: [("吸气", 0.05), ("呼气", 0.05)])

        let startTask = Task { await viewModel.start() }
        tasksUnderTest.append(startTask)
        let creationStarted = await waitUntil("suspended session creation to start") {
            await self.sessionAPI.snapshot().createSessionCallCount == 1
        }
        guard creationStarted else { return }
        let inactivityTask = viewModel.handleAppActivity(isActive: false)

        await sessionAPI.resumeAllCreations()
        guard await waitForCompletion(of: startTask, "interrupted start to finish") else { return }
        guard await waitForCompletion(of: inactivityTask, "inactivity stop to finish") else { return }

        let sessionSnapshot = await sessionAPI.snapshot()
        let ttsSnapshot = await ttsAPI.snapshot()
        XCTAssertFalse(viewModel.isRunning)
        XCTAssertEqual(viewModel.phase, .finished)
        XCTAssertEqual(viewModel.currentCycle, 0)
        XCTAssertEqual(ttsSnapshot.callCount, 0)
        XCTAssertEqual(
            sessionSnapshot.completions,
            [.init(sessionID: "session-1", durationSeconds: 0)]
        )
    }

    func testInactiveBeforeQueuedStartExecutes_doesNotCreateSession() async {
        let viewModel = makeVisibleActiveViewModel(phases: [("吸气", 1)])

        let startTask = Task { await viewModel.start() }
        tasksUnderTest.append(startTask)
        let inactivityTask = viewModel.handleAppActivity(isActive: false)
        if let inactivityTask {
            guard await waitForCompletion(of: inactivityTask, "queued inactivity handling") else { return }
        }
        guard await waitForCompletion(of: startTask, "queued start to finish") else { return }

        let snapshot = await sessionAPI.snapshot()
        XCTAssertEqual(snapshot.createSessionCallCount, 0)
        XCTAssertTrue(snapshot.completions.isEmpty)
        XCTAssertFalse(viewModel.isRunning)
    }

    func testInitialInactiveState_blocksStartUntilVisibleAndActive() async {
        let viewModel = makeViewModel(phases: [("吸气", 1)])

        guard await start(viewModel) else { return }
        var snapshot = await sessionAPI.snapshot()
        XCTAssertEqual(snapshot.createSessionCallCount, 0)

        viewModel.handleViewAppearance(isAppActive: true)
        guard await start(viewModel) else { return }
        snapshot = await sessionAPI.snapshot()
        XCTAssertEqual(snapshot.createSessionCallCount, 1)
        let stopTask = viewModel.stop()
        guard await waitForCompletion(of: stopTask, "initial-state cleanup stop") else { return }
    }

    func testViewDisappearance_stopsAndCompletesCreatedSession() async {
        let viewModel = makeVisibleActiveViewModel(phases: [("吸气", 1)])
        guard await start(viewModel) else { return }

        let disappearanceTask = viewModel.handleViewDisappearance()
        guard await waitForCompletion(of: disappearanceTask, "view disappearance stop") else { return }

        let snapshot = await sessionAPI.snapshot()
        XCTAssertFalse(viewModel.isRunning)
        XCTAssertEqual(
            snapshot.completions,
            [.init(sessionID: "session-1", durationSeconds: 0)]
        )
    }

    func testRepeatedLifecycleStop_completesSessionOnlyOnce() async {
        await sessionAPI.configure(suspendCompletion: true)
        let viewModel = makeVisibleActiveViewModel(phases: [("吸气", 1)])
        guard await start(viewModel) else { return }

        let inactivityTask = viewModel.handleAppActivity(isActive: false)
        let disappearanceTask = viewModel.handleViewDisappearance()
        let completionStarted = await waitUntil("lifecycle completion to start") {
            await self.sessionAPI.snapshot().completions.count == 1
        }
        guard completionStarted else { return }

        let stoppingSnapshot = await sessionAPI.snapshot()
        XCTAssertEqual(
            stoppingSnapshot.completions,
            [.init(sessionID: "session-1", durationSeconds: 0)]
        )

        await sessionAPI.resumeAllCompletions()
        guard await waitForCompletion(of: inactivityTask, "inactivity finalization") else { return }
        XCTAssertNil(disappearanceTask)

        let completedSnapshot = await sessionAPI.snapshot()
        XCTAssertEqual(completedSnapshot.completions.count, 1)
    }

    func testBecomingActiveAgain_allowsManualRestartWithoutAutomaticallyRestarting() async {
        let viewModel = makeVisibleActiveViewModel(phases: [("吸气", 1)])
        guard await start(viewModel) else { return }
        let inactivityTask = viewModel.handleAppActivity(isActive: false)
        guard await waitForCompletion(of: inactivityTask, "inactive session stop") else { return }

        _ = viewModel.handleAppActivity(isActive: true)
        var snapshot = await sessionAPI.snapshot()
        XCTAssertEqual(snapshot.createSessionCallCount, 1)
        XCTAssertFalse(viewModel.isRunning)

        guard await start(viewModel) else { return }
        snapshot = await sessionAPI.snapshot()
        XCTAssertEqual(snapshot.createSessionCallCount, 2)
        let stopTask = viewModel.stop()
        guard await waitForCompletion(of: stopTask, "manual restart cleanup stop") else { return }
    }

    func testStartingNextPhase_resetsPhaseProgressBeforeSpeaking() async {
        await ttsAPI.configure(suspend: true)
        let viewModel = makeVisibleActiveViewModel(phases: [("吸气", 0.05), ("呼气", 1)])
        guard await start(viewModel) else { return }

        let firstPromptStarted = await waitUntil("first phase prompt to start") {
            await self.ttsAPI.snapshot().callCount == 1
        }
        guard firstPromptStarted else { return }
        await ttsAPI.resumeRequests()
        guard await waitForPendingSleep("first phase step") else { return }
        let advancedFirstPhase = await sleeper.advanceOne()
        XCTAssertTrue(advancedFirstPhase)
        let secondPromptStarted = await waitUntil("second phase prompt to start") {
            await self.ttsAPI.snapshot().callCount == 2
        }
        guard secondPromptStarted else { return }

        XCTAssertEqual(viewModel.phase, .exhale)
        XCTAssertEqual(viewModel.phaseProgress, 0)

        let inactivityTask = viewModel.handleAppActivity(isActive: false)
        await ttsAPI.resumeRequests()
        guard await waitForCompletion(of: inactivityTask, "phase reset test stop") else { return }
    }

    func testCycleLabel_showsCurrentRoundWithoutTotal() {
        let viewModel = makeVisibleActiveViewModel(phases: [("吸气", 1)])

        XCTAssertEqual(viewModel.cycleLabel, "第 1 轮")
    }

    private func makeVisibleActiveViewModel(
        phases: [(name: String, duration: Double)],
        now: @escaping () -> Date = Date.init
    ) -> BreathingViewModel {
        let viewModel = makeViewModel(phases: phases, now: now)
        viewModel.handleViewAppearance(isAppActive: true)
        return viewModel
    }

    private func makeViewModel(
        phases: [(name: String, duration: Double)],
        now: @escaping () -> Date = Date.init
    ) -> BreathingViewModel {
        let phaseJSON = phases
            .map { #"{"name":"\#($0.name)","duration":\#($0.duration)}"# }
            .joined(separator: ",")
        let guide = Guide(
            id: UUID().uuidString,
            slug: "test-breathing",
            category: "breathing",
            title: "Test Breathing",
            summary: "",
            sortOrder: 0,
            isActive: true,
            configJSON: #"{"phases":[\#(phaseJSON)]}"#
        )
        return BreathingViewModel(
            guide: guide,
            modelContext: container.mainContext,
            ttsPlayer: ttsPlayer,
            api: sessionAPI,
            sleeper: sleeper,
            now: now
        )
    }

    private func start(
        _ viewModel: BreathingViewModel,
        _ description: String = "breathing session start"
    ) async -> Bool {
        let task = Task { await viewModel.start() }
        return await waitForCompletion(of: task, description)
    }

    private func waitForPendingSleep(_ description: String) async -> Bool {
        await waitUntil(description) {
            await self.sleeper.pendingCount() > 0
        }
    }

    private func waitForCompletion(
        of task: Task<Void, Never>?,
        _ description: String,
        timeout: TimeInterval = 2
    ) async -> Bool {
        guard let task else {
            XCTFail("Missing task while waiting for \(description)")
            return false
        }

        tasksUnderTest.append(task)
        let completion = expectation(description: description)
        let probe = TaskCompletionProbe()
        let observer = Task {
            await task.value
            guard !Task.isCancelled else { return }
            await probe.finish()
            completion.fulfill()
        }
        completionObservers.append(observer)

        await fulfillment(of: [completion], timeout: timeout)
        let didFinish = await probe.snapshot()
        if !didFinish {
            XCTFail("Timed out waiting for \(description)")
            task.cancel()
            observer.cancel()
        }
        return didFinish
    }

    private func waitUntil(
        _ description: String = "condition",
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while clock.now < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        if await condition() {
            return true
        }
        XCTFail("Timed out waiting for \(description)")
        return false
    }
}
