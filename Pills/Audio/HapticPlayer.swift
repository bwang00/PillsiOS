import UIKit

/// Which side of the body the user should tap on the current beat.
enum ButterflySide: String, Sendable {
    case left
    case right
}

/// Abstraction over per-beat haptic feedback so it can be mocked in tests.
/// iPhone has a single actuator: left/right is conveyed visually; the haptic
/// marks each beat with a subtle intensity difference to reinforce rhythm.
protocol HapticPlayer: AnyObject {
    func tap(_ side: ButterflySide)
    func stop()
}

/// Concrete player using system impact feedback generators.
final class ImpactHapticPlayer: HapticPlayer {
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)

    func tap(_ side: ButterflySide) {
        switch side {
        case .left:
            light.impactOccurred()
        case .right:
            medium.impactOccurred()
        }
    }

    func stop() {
        // No continuous engine to stop; impact generators are one-shot.
    }
}
