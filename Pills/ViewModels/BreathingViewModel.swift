import Foundation
import SwiftData
import Observation

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

    var phase: Phase = .idle
    var phaseLabel: String = "准备开始"
    var currentCycle: Int = 0
    var totalCycles: Int = 4
    var phaseProgress: Double = 0  // 0...1 within current phase
    var elapsedSeconds: Int = 0
    var isRunning = false

    // MARK: - Configuration

    let guide: Guide
    private var phases: [GuideConfig.BreathPhase] = []
    private var currentPhaseIndex = 0
    private var phaseStartTime: Date?
    private var timerTask: Task<Void, Never>?
    private var sessionId: String?
    private var sessionStartTime: Date?

    // MARK: - Dependencies

    private let modelContext: ModelContext
    private let ttsPlayer: TTSPlayer

    init(guide: Guide, modelContext: ModelContext, ttsPlayer: TTSPlayer) {
        self.guide = guide
        self.modelContext = modelContext
        self.ttsPlayer = ttsPlayer
        self.phases = guide.phases
        // Calculate total cycles from duration
        if !phases.isEmpty {
            let cycleDuration = phases.reduce(0.0) { $0 + $1.duration }
            totalCycles = max(1, Int(Double(guide.durationSeconds) / cycleDuration))
        }
    }

    // MARK: - Lifecycle

    func start() async {
        guard !phases.isEmpty else { return }

        // Create session on server
        do {
            let session = try await APIClient.shared.createSession(guideSlug: guide.slug)
            sessionId = session.id
        } catch {
            print("⚠️ Failed to create session: \(error)")
        }

        currentCycle = 0
        currentPhaseIndex = 0
        elapsedSeconds = 0
        sessionStartTime = Date()
        isRunning = true

        await runCycleLoop()
    }

    func stop() async {
        isRunning = false
        timerTask?.cancel()
        timerTask = nil
        ttsPlayer.stop()

        // Complete session on server
        if let sessionId, elapsedSeconds > 0 {
            do {
                _ = try await APIClient.shared.completeSession(
                    id: sessionId,
                    durationSeconds: elapsedSeconds
                )
            } catch {
                print("⚠️ Failed to complete session: \(error)")
            }
        }

        phase = .finished
        phaseLabel = "练习完成"
    }

    // MARK: - Breathing cycle loop

    private func runCycleLoop() async {
        while isRunning && currentCycle < totalCycles {
            for (index, phaseConfig) in phases.enumerated() {
                guard isRunning else { return }
                currentPhaseIndex = index
                await runPhase(phaseConfig)
            }
            currentCycle += 1
        }

        if isRunning {
            await stop()
        }
    }

    private func runPhase(_ phaseConfig: GuideConfig.BreathPhase) async {
        // Map phase name to enum
        switch phaseConfig.name {
        case "inhale":
            phase = .inhale
            phaseLabel = "吸气"
            await ttsPlayer.speak("吸气")
        case "hold":
            phase = .hold
            phaseLabel = "闭气"
            await ttsPlayer.speak("闭气")
        case "exhale":
            phase = .exhale
            phaseLabel = "呼气"
            await ttsPlayer.speak("呼气")
        default:
            phaseLabel = phaseConfig.label
        }

        // Haptic feedback
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        let duration = phaseConfig.duration
        let steps = Int(duration * 20) // 50ms intervals
        let stepDuration = duration / Double(steps)

        phaseStartTime = Date()
        phaseProgress = 0

        for step in 0..<steps {
            guard isRunning else { return }
            try? await Task.sleep(nanoseconds: UInt64(stepDuration * 1_000_000_000))
            phaseProgress = Double(step + 1) / Double(steps)

            if step % 20 == 0 { // Update elapsed seconds ~every second
                if let sessionStart = sessionStartTime {
                    elapsedSeconds = Int(Date().timeIntervalSince(sessionStart))
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
        "\(currentCycle + 1) / \(totalCycles)"
    }

    var formattedTime: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

import UIKit
