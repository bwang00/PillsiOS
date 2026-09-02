import SwiftUI

struct GuideCard: View {
    let guide: Guide
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                // Icon
                ZStack {
                    Circle()
                        .fill(iconColor.opacity(0.15))
                        .frame(width: 50, height: 50)
                    Image(systemName: iconName)
                        .font(.title3)
                        .foregroundStyle(iconColor)
                }

                // Text
                VStack(alignment: .leading, spacing: 4) {
                    Text(guide.displayName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(guide.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                // Duration
                Text(durationText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(.background, in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
    }

    private var iconName: String {
        switch guide.category {
        case "breathing": return "wind"
        case "mindfulness": return "brain.head.profile"
        case "grounding": return "hand.raised.fill"
        case "muscle_relax": return "figure.mind.and.body"
        default: return "leaf.fill"
        }
    }

    private var iconColor: Color {
        switch guide.category {
        case "breathing": return .blue
        case "mindfulness": return .purple
        case "grounding": return .orange
        case "muscle_relax": return .teal
        default: return .green
        }
    }

    private var durationText: String {
        let minutes = guide.durationSeconds / 60
        let seconds = guide.durationSeconds % 60
        if minutes > 0 && seconds == 0 {
            return "\(minutes)分钟"
        } else if minutes > 0 {
            return "\(minutes)分\(seconds)秒"
        }
        return "\(seconds)秒"
    }
}
