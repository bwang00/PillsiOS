import Foundation
import SwiftData
import Observation

/// Drives the butterfly hug (蝴蝶拥抱) grounding exercise: a steady alternating
/// left/right tap metronome with free-form start/stop, recorded through the same
/// session pipeline as breathing. Session-lifecycle guards mirror
/// BreathingViewModel (generation counter, canStart gating, background/dismiss
/// auto-stop, idempotency key, offline completion queue).
@MainActor
@Observable
final class ButterflyHugViewModel {

    private enum LifecycleState { case idle, starting, running, stopping, finished }

    private struct StopContext {
        let generation: UInt64
        let sessionID: String?
        let sessionCreationTask: Task<SessionDTO, Error>?
        let timerTask: Task<Void, Never>?
        let elapsedSeconds: Int
        let idempotencyKey: String
    }

    // MARK: - State

    var activeSide: ButterflySide = .left
    var tapCount: Int = 0
    var elapsedSeconds: Int = 0

    var isRunning: Bool {
        switch lifecycleState {
        case .starting, .running, .stopping: return true
        case .idle, .finished: return false
        }
    }

    var isFinished: Bool { lifecycleState == .finished }

    // MARK: - Configuration

    let guide: Guide
    private let tapInterval: Double
    private var timerTask: Task<Void, Never>?
    private var sessionCreationTask: Task<SessionDTO, Error>?
    private var sessionId: String?
    private var sessionStartTime: Date?
    private var currentIdempotencyKey: String = UUID().uuidString
    private var generation: UInt64 = 0
    private var lifecycleState: LifecycleState = .idle
    private var isStarting = false
    private var isViewVisible = false
    private var isAppActive = false

    private var canStart: Bool { isViewVisible && isAppActive }

    // MARK: - Dependencies

    private let modelContext: ModelContext
    private let haptics: HapticPlayer
    private let api: BreathingSessionAPI
    private let sleeper: BreathingSleeper
    private let now: () -> Date

    init(
        guide: Guide,
        modelContext: ModelContext,
        haptics: HapticPlayer,
        api: BreathingSessionAPI = APIClient.shared,
        sleeper: BreathingSleeper = TaskBreathingSleeper(),
        now: @escaping () -> Date = Date.init
    ) {
        self.guide = guide
        self.modelContext = modelContext
        self.haptics = haptics
        self.api = api
        self.sleeper = sleeper
        self.now = now
        self.tapInterval = guide.butterfly?.tapInterval ?? 1.0
    }

    // MARK: - Lifecycle handlers

    func handleViewAppearance(isAppActive: Bool) {
        isViewVisible = true
        self.isAppActive = isAppActive
    }

    @discardableResult
    func handleAppActivity(isActive: Bool) -> Task<Void, Never>? {
        isAppActive = isActive
        return isActive ? nil : stop()
    }

    @discardableResult
    func handleViewDisappearance() -> Task<Void, Never>? {
        isViewVisible = false
        return stop()
    }

    func start() async {
        guard canStart, !isStarting,
              lifecycleState == .idle || lifecycleState == .finished else { return }

        isStarting = true
        defer { isStarting = false }

        await flushPendingCompletions()
        guard canStart else { return }

        generation &+= 1
        let runGeneration = generation
        lifecycleState = .starting
        tapCount = 0
        elapsedSeconds = 0
        activeSide = .left
        sessionId = nil
        sessionStartTime = nil
        let runKey = UUID().uuidString
        currentIdempotencyKey = runKey

        let creationTask = Task {
            try await api.createSession(guideSlug: guide.slug, idempotencyKey: runKey)
        }
        sessionCreationTask = creationTask
        do {
            let session = try await creationTask.value
            guard canStart, lifecycleState == .starting, generation == runGeneration else { return }
            sessionCreationTask = nil
            sessionId = session.id
        } catch {
            guard canStart, lifecycleState == .starting, generation == runGeneration else { return }
            sessionCreationTask = nil
            print("⚠️ Failed to create butterfly session: \(error)")
        }

        guard canStart, lifecycleState == .starting, generation == runGeneration else { return }
        sessionStartTime = now()
        lifecycleState = .running
        timerTask = Task { [weak self] in
            await self?.runTapLoop(generation: runGeneration)
        }
    }

    @discardableResult
    func stop() -> Task<Void, Never>? {
        guard let ctx = beginStop() else { return nil }
        return Task { await self.finishStop(ctx) }
    }

    private func beginStop() -> StopContext? {
        guard lifecycleState == .starting || lifecycleState == .running else { return nil }
        lifecycleState = .stopping
        if let sessionStartTime {
            elapsedSeconds = max(0, Int(now().timeIntervalSince(sessionStartTime)))
        }
        let ctx = StopContext(
            generation: generation,
            sessionID: sessionId,
            sessionCreationTask: sessionCreationTask,
            timerTask: timerTask,
            elapsedSeconds: elapsedSeconds,
            idempotencyKey: currentIdempotencyKey
        )
        sessionStartTime = nil
        sessionId = nil
        sessionCreationTask = nil
        timerTask = nil
        ctx.timerTask?.cancel()
        haptics.stop()
        return ctx
    }

    private func finishStop(_ ctx: StopContext) async {
        await ctx.timerTask?.value

        var completedSessionID = ctx.sessionID
        if let creationTask = ctx.sessionCreationTask {
            do {
                let session = try await creationTask.value
                completedSessionID = completedSessionID ?? session.id
            } catch {
                print("⚠️ Failed to create butterfly session: \(error)")
            }
        }

        if let completedSessionID {
            do {
                _ = try await api.completeSession(id: completedSessionID, durationSeconds: ctx.elapsedSeconds)
                removePendingCompletion(sessionID: completedSessionID)
            } catch {
                print("⚠️ Failed to complete butterfly session: \(error)")
                queuePendingCompletion(
                    sessionID: completedSessionID, guideSlug: guide.slug,
                    durationSeconds: ctx.elapsedSeconds)
            }
        } else {
            queuePendingCompletion(
                sessionID: nil, guideSlug: guide.slug,
                durationSeconds: ctx.elapsedSeconds, idempotencyKey: ctx.idempotencyKey)
        }

        guard lifecycleState == .stopping, generation == ctx.generation else { return }
        lifecycleState = .finished
    }

    // MARK: - Metronome loop

    private func runTapLoop(generation runGeneration: UInt64) async {
        while lifecycleState == .running, generation == runGeneration, !Task.isCancelled {
            haptics.tap(activeSide)
            tapCount += 1
            activeSide = (activeSide == .left) ? .right : .left
            if let start = sessionStartTime {
                elapsedSeconds = max(0, Int(now().timeIntervalSince(start)))
            }
            do {
                try await sleeper.sleep(for: .seconds(tapInterval))
            } catch {
                return
            }
            guard lifecycleState == .running, generation == runGeneration, !Task.isCancelled else { return }
        }
    }

    // MARK: - Pending completion queue (mirrors BreathingViewModel)

    func flushPendingCompletions() async {
        await SessionCompletionQueue.flush(modelContext: modelContext, api: api)
    }

    private func queuePendingCompletion(
        sessionID: String?, guideSlug: String, durationSeconds: Int, idempotencyKey: String? = nil
    ) {
        if let sessionID,
           let existing = (try? modelContext.fetch(
                FetchDescriptor<PendingSessionCompletion>(
                    predicate: #Predicate { $0.sessionID == sessionID })).first) {
            existing.durationSeconds = durationSeconds
            existing.createdAt = now()
            try? modelContext.save()
            return
        }
        modelContext.insert(PendingSessionCompletion(
            sessionID: sessionID, guideSlug: guideSlug,
            durationSeconds: durationSeconds, idempotencyKey: idempotencyKey, createdAt: now()))
        try? modelContext.save()
    }

    private func removePendingCompletion(sessionID: String) {
        guard let existing = (try? modelContext.fetch(
            FetchDescriptor<PendingSessionCompletion>(
                predicate: #Predicate { $0.sessionID == sessionID })).first) else { return }
        modelContext.delete(existing)
        try? modelContext.save()
    }

    // MARK: - Display

    var formattedTime: String {
        String(format: "%02d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
    }
}
