import SwiftUI

/// Animated breathing circle that scales smoothly between inhale and exhale phases.
struct BreathingCircle: View {
    let scale: CGFloat

    var body: some View {
        ZStack {
            // Outer glow ring
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.blue.opacity(0.15), .clear],
                        center: .center,
                        startRadius: 40,
                        endRadius: 120
                    )
                )
                .scaleEffect(scale * 1.3)
                .blur(radius: 10)

            // Main circle
            Circle()
                .fill(
                    LinearGradient(
                        colors: [.blue.opacity(0.6), .cyan.opacity(0.4)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    Circle()
                        .stroke(.white.opacity(0.3), lineWidth: 2)
                )
                .scaleEffect(scale)

            // Inner highlight
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(0.3), .clear],
                        center: .init(x: 0.35, y: 0.35),
                        startRadius: 5,
                        endRadius: 60
                    )
                )
                .scaleEffect(scale * 0.8)
        }
        .animation(.easeInOut(duration: 0.3), value: scale)
    }
}
