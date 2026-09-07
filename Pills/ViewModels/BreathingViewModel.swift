import Foundation
import SwiftData
import Observation

protocol BreathingSessionAPI: Sendable {
    func createSession(guideSlug: String, idempotencyKey: String?) async throws -> SessionDTO
    func completeSession(id: String, durationSeconds: Int) async throws -> SessionDTO
}

protocol BreathingSleeper: Sendable {
    func sleep(for duration: Duration) async throws
}

struct TaskBreathingSleeper: BreathingSleeper {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

extension APIClient: BreathingSessionAPI {}

/// Drives the breathing exercise session.
/// Manages phase transitions, timers, TTS audio cues, and session persistence.
@MainActor
@Observable
final class BreathingViewModel {

    // MARK: - State

    enum Phase {
        case idle
        case inhale
        case hold
        case exhale
        case finished
    }

    private enum LifecycleState {
        case idle
        case starting
        case running
        case stopping
        case finished
    }

    private struct StopContext {
        let generation: UInt64
        let sessionID: String?
        let sessionCreationTask: Task<SessionDTO, Error>?
        let timerTask: Task<Void, Never>?
        let elapsedSeconds: Int
        let idempotencyKey: String
    }

    var phase: Phase = .idle
    var phaseLabel: String = "准备开始"
    var currentCycle: Int = 0
    var phaseProgress: Double = 0  // 0...1 within current phase
    var elapsedSeconds: Int = 0

    var isRunning: Bool {
        switch lifecycleState {
        case .starting, .running, .stopping:
            return true
        case .idle, .finished:
            return false
        }
    }

    // MARK: - Configuration

    let guide: Guide
    private var phases: [GuideConfig.BreathPhase] = []
    private var currentPhaseIndex = 0
    private var timerTask: Task<Void, Never>?
    private var sessionCreationTask: Task<SessionDTO, Error>?
    private var sessionId: String?
    private var sessionStartTime: Date?
    /// Per-practice idempotency key sent with createSession and persisted onto
    /// any queued offline completion, so a lost-response retry dedups server-side.
    private var currentIdempotencyKey: String = UUID().uuidString
    private var generation: UInt64 = 0
    private var lifecycleState: LifecycleState = .idle
    /// Synchronous re-entrancy claim for `start()`. Set before the first `await`
    /// (the offline-queue flush) and cleared on return, so a second `start()`
    /// dispatched while the flush suspends cannot slip past the lifecycle guard
    /// and open a duplicate server-side session. Kept separate from
    /// `lifecycleState` so `stop()` during the flush still no-ops as before.
    private var isStarting = false
    private var isViewVisible = false
    private var isAppActive = false

    private var canStart: Bool {
        isViewVisible && isAppActive
    }

    // MARK: - Dependencies

    private let modelContext: ModelContext
    private let ttsPlayer: TTSPlayer
    private let api: BreathingSessionAPI
    private let sleeper: BreathingSleeper
    private let now: () -> Date

    init(
        guide: Guide,
        modelContext: ModelContext,
        ttsPlayer: TTSPlayer,
        api: BreathingSessionAPI = APIClient.shared,
        sleeper: BreathingSleeper = TaskBreathingSleeper(),
        now: @escaping () -> Date = Date.init
    ) {
        self.guide = guide
        self.modelContext = modelContext
        self.ttsPlayer = ttsPlayer
        self.api = api
        self.sleeper = sleeper
        self.now = now
        self.phases = guide.phases
    }

    // MARK: - Lifecycle

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
        guard canStart,
              !phases.isEmpty,
              !isStarting,
              lifecycleState == .idle || lifecycleState == .finished else { return }

        // Claim re-entrancy synchronously, before the first await, so a second
        // start() dispatched while the offline-queue flush below suspends
        // returns at the guard above instead of opening a duplicate session.
        isStarting = true
        defer { isStarting = false }

        // Drain any queued completions from earlier failures before opening a
        // new server-side session. Best-effort: flush errors stay queued.
        await flushPendingCompletions()

        // The flush suspends. A backgrounding/dismissal during that window
        // no-ops stop() (the lifecycle is still idle), so re-validate canStart
        // before opening a session — otherwise we would create a server-side
        // row and then bail at the guards below, orphaning it and wedging the
        // lifecycle at .starting. The defer above releases isStarting.
        guard canStart else { return }

        generation &+= 1
        let runGeneration = generation
        lifecycleState = .starting
        currentCycle = 0
        currentPhaseIndex = 0
        elapsedSeconds = 0
        phaseProgress = 0
        sessionId = nil
        sessionStartTime = nil
        // Snapshot the key into a local so the value sent on the wire is exactly
        // the value carried into StopContext, even if a later run overwrites
        // currentIdempotencyKey before this Task's body executes.
        let runKey = UUID().uuidString
        currentIdempotencyKey = runKey

        let creationTask = Task {
            try await api.createSession(guideSlug: guide.slug, idempotencyKey: runKey)
        }
        sessionCreationTask = creationTask

        do {
            let session = try await creationTask.value
            guard canStart,
                  lifecycleState == .starting,
                  generation == runGeneration else { return }
            sessionCreationTask = nil
            sessionId = session.id
        } catch {
            guard canStart,
                  lifecycleState == .starting,
                  generation == runGeneration else { return }
            sessionCreationTask = nil
            print("⚠️ Failed to create session: \(error)")
        }

        guard canStart,
              lifecycleState == .starting,
              generation == runGeneration else { return }
        sessionStartTime = now()
        lifecycleState = .running
        timerTask = Task { [weak self] in
            await self?.runCycleLoop(generation: runGeneration)
        }
    }

    @discardableResult
    func stop() -> Task<Void, Never>? {
        guard let stopContext = beginStop() else { return nil }
        return Task { await self.finishStop(stopContext) }
    }

    private func beginStop() -> StopContext? {
        guard lifecycleState == .starting || lifecycleState == .running else { return nil }

        lifecycleState = .stopping
        if let sessionStartTime {
            elapsedSeconds = max(0, Int(now().timeIntervalSince(sessionStartTime)))
        }

        let stopContext = StopContext(
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
        stopContext.timerTask?.cancel()
        ttsPlayer.stop()
        return stopContext
    }

    private func finishStop(_ stopContext: StopContext) async {
        await stopContext.timerTask?.value

        var completedSessionID = stopContext.sessionID
        if let creationTask = stopContext.sessionCreationTask {
            do {
                let session = try await creationTask.value
                completedSessionID = completedSessionID ?? session.id
            } catch {
                print("⚠️ Failed to create session: \(error)")
            }
        }

        if let completedSessionID {
            do {
                _ = try await api.completeSession(
                    id: completedSessionID,
                    durationSeconds: stopContext.elapsedSeconds
                )
                removePendingCompletion(sessionID: completedSessionID)
            } catch {
                print("⚠️ Failed to complete session: \(error)")
                queuePendingCompletion(
                    sessionID: completedSessionID,
                    guideSlug: guide.slug,
                    durationSeconds: stopContext.elapsedSeconds
                )
            }
        } else {
            // createSession never returned an id (offline / backend error), but
            // the practice still ran. Queue it so a later flush can create the
            // session and upload the duration instead of losing the practice.
            // Carry this run's idempotency key: if the original createSession
            // actually committed server-side but lost its response, the flush
            // retry reuses the same key and the backend returns that session
            // instead of inserting a duplicate.
            queuePendingCompletion(
                sessionID: nil,
                guideSlug: guide.slug,
                durationSeconds: stopContext.elapsedSeconds,
                idempotencyKey: stopContext.idempotencyKey
            )
        }

        guard lifecycleState == .stopping,
              generation == stopContext.generation else { return }
        phase = .finished
        phaseLabel = "练习完成"
        lifecycleState = .finished
    }

    // MARK: - Pending completion queue

    /// Retries any queued session completions and removes them only after the
    /// backend acknowledges the upload. Records without a server session id
    /// (offline practices) are created first. Failures leave the record in
    /// place so a later flush can try again.
    func flushPendingCompletions() async {
        await SessionCompletionQueue.flush(modelContext: modelContext, api: api)
    }

    private func queuePendingCompletion(
        sessionID: String?,
        guideSlug: String,
        durationSeconds: Int,
        idempotencyKey: String? = nil
    ) {
        if let sessionID {
            // Dedup by server session id so retrying the same session updates
            // the existing record instead of creating a duplicate.
            let existing = (try? modelContext.fetch(
                FetchDescriptor<PendingSessionCompletion>(
                    predicate: #Predicate { $0.sessionID == sessionID }
                )
            ).first)
            if let existing {
                existing.durationSeconds = durationSeconds
                existing.createdAt = now()
                try? modelContext.save()
                return
            }
        }
        modelContext.insert(
            PendingSessionCompletion(
                sessionID: sessionID,
                guideSlug: guideSlug,
                durationSeconds: durationSeconds,
                idempotencyKey: idempotencyKey,
                createdAt: now()
            )
        )
        try? modelContext.save()
    }

    private func removePendingCompletion(sessionID: String) {
        guard let existing = try? modelContext.fetch(
            FetchDescriptor<PendingSessionCompletion>(
                predicate: #Predicate { $0.sessionID == sessionID }
            )
        ).first else { return }
        modelContext.delete(existing)
        try? modelContext.save()
    }

    // MARK: - Breathing cycle loop

    private func runCycleLoop(generation runGeneration: UInt64) async {
        while lifecycleState == .running,
              generation == runGeneration,
              !Task.isCancelled {
            for (index, phaseConfig) in phases.enumerated() {
                guard lifecycleState == .running,
                      generation == runGeneration,
                      !Task.isCancelled else { return }
                currentPhaseIndex = index
                await runPhase(phaseConfig, generation: runGeneration)
                guard lifecycleState == .running,
                      generation == runGeneration,
                      !Task.isCancelled else { return }
            }
            currentCycle += 1
        }
    }

    private func runPhase(
        _ phaseConfig: GuideConfig.BreathPhase,
        generation runGeneration: UInt64
    ) async {
        phaseProgress = 0

        switch phaseConfig.name {
        case "吸气", "inhale":
            phase = .inhale
            phaseLabel = "吸气"
            await ttsPlayer.speak("吸气")
        case "闭气", "hold":
            phase = .hold
            phaseLabel = "闭气"
            await ttsPlayer.speak("闭气")
        case "呼气", "exhale":
            phase = .exhale
            phaseLabel = "呼气"
            await ttsPlayer.speak("呼气")
        default:
            phaseLabel = phaseConfig.name
        }

        guard lifecycleState == .running,
              generation == runGeneration,
              !Task.isCancelled else { return }

        // Haptic feedback
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        let duration = phaseConfig.duration
        let steps = max(1, Int(duration * 20)) // 50ms intervals
        let stepDuration = duration / Double(steps)

        for step in 0..<steps {
            guard lifecycleState == .running,
                  generation == runGeneration,
                  !Task.isCancelled else { return }
            do {
                try await sleeper.sleep(for: .seconds(stepDuration))
            } catch {
                return
            }
            guard lifecycleState == .running,
                  generation == runGeneration,
                  !Task.isCancelled else { return }
            phaseProgress = Double(step + 1) / Double(steps)

            if step % 20 == 0 { // Update elapsed seconds ~every second
                if let sessionStart = sessionStartTime {
                    elapsedSeconds = max(0, Int(now().timeIntervalSince(sessionStart)))
                }
            }
        }
    }

    private var cycleDuration: Double {
        phases.reduce(0) { $0 + $1.duration }
    }

    private var phaseOffset: Double {
        phases.prefix(currentPhaseIndex).reduce(0) { $0 + $1.duration }
    }

    // MARK: - Computed properties

    /// Circle scale: 0.4 (contracted) → 1.0 (expanded)
    var circleScale: CGFloat {
        switch phase {
        case .inhale:
            return 0.4 + 0.6 * CGFloat(phaseProgress)
        case .hold:
            return 1.0
        case .exhale:
            return 1.0 - 0.6 * CGFloat(phaseProgress)
        case .idle, .finished:
            return 0.6
        }
    }

    var cycleLabel: String {
        "第 \(currentCycle + 1) 轮"
    }

    var formattedTime: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

import UIKit
