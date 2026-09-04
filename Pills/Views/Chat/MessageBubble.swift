import SwiftUI

struct MessageBubble: View {
    let message: ChatViewModel.ChatMessageItem

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 48) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .font(.body)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        isUser
                        ? Color.green
                        : Color(.secondarySystemBackground)
                    )
                    .foregroundStyle(isUser ? .white : .primary)
                    .clipShape(BubbleShape(isUser: isUser))

                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }

            if !isUser { Spacer(minLength: 48) }
        }
        .transition(.asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity
        ))
    }
}

// Custom bubble shape with tail
struct BubbleShape: Shape {
    let isUser: Bool

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 16
        let tailRadius: CGFloat = 4
        var path = Path()

        if isUser {
            // User bubble: rounded on all corners except bottom-right
            path.addRoundedRect(
                in: CGRect(x: rect.minX, y: rect.minY, width: rect.width - tailRadius, height: rect.height),
                cornerSize: CGSize(width: radius, height: radius)
            )
            // Small tail
            path.addRoundedRect(
                in: CGRect(x: rect.maxX - tailRadius * 2, y: rect.maxY - radius, width: tailRadius * 2, height: radius),
                cornerSize: CGSize(width: tailRadius, height: tailRadius)
            )
        } else {
            // AI bubble: rounded on all corners except bottom-left
            path.addRoundedRect(
                in: CGRect(x: rect.minX + tailRadius, y: rect.minY, width: rect.width - tailRadius, height: rect.height),
                cornerSize: CGSize(width: radius, height: radius)
            )
            // Small tail
            path.addRoundedRect(
                in: CGRect(x: rect.minX, y: rect.maxY - radius, width: tailRadius * 2, height: radius),
                cornerSize: CGSize(width: tailRadius, height: tailRadius)
            )
        }

        return path
    }
}
