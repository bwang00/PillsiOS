import SwiftUI

/// A banner that appears at the top when the device is offline.
struct OfflineBanner: View {
    let message: String
    var retryAction: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.caption)
            Text(message)
                .font(.caption)
                .fontWeight(.medium)
            Spacer()
            if let retryAction {
                Button("重试", action: retryAction)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .buttonStyle(.borderless)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.orange)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// View modifier that shows an offline banner when network is unavailable.
struct OfflineBannerModifier: ViewModifier {
    @Environment(NetworkMonitor.self) private var network
    var retryAction: (() -> Void)?

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            if !network.isOnline {
                OfflineBanner(
                    message: "网络连接不可用",
                    retryAction: retryAction
                )
            }
            content
        }
        .animation(.easeInOut(duration: 0.3), value: network.isOnline)
    }
}

extension View {
    func offlineBanner(retry: (() -> Void)? = nil) -> some View {
        modifier(OfflineBannerModifier(retryAction: retry))
    }
}
