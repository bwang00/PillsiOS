import SwiftUI
import SwiftData

@main
struct PillsApp: App {
    @StateObject private var authManager = AuthManager()
    @State private var networkMonitor = NetworkMonitor()
    private let modelContainer: ModelContainer

    init() {
        let schema = Schema([
            Guide.self,
            Session.self,
            Conversation.self,
            ChatMessage.self,
            User.self,
            PendingSessionCompletion.self,
        ])
        let configuration = ModelConfiguration(
            APIConfiguration.defaultDataNamespace(),
            schema: schema
        )
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Unable to create the app data store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authManager)
                .environment(networkMonitor)
                .modelContainer(modelContainer)
                .task {
                    guard authManager.state == .restoring else { return }
                    do {
                        try await authManager.configure(modelContext: modelContainer.mainContext)
                    } catch {
                        // AuthManager exposes a retryable failure state; retain the log for diagnostics.
                        print("Authentication restoration failed: \(error)")
                    }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var authManager: AuthManager

    var body: some View {
        Group {
            switch authManager.state {
            case .restoring:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在恢复登录状态…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            case .signedOut, .signingIn:
                SignInView()
            case .signedIn:
                MainTabView()
            case .failed:
                VStack(spacing: 16) {
                    Text("无法恢复登录状态")
                        .font(.headline)
                    Text(authManager.authErrorMessage ?? "请重试")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("重试") {
                        Task { try? await authManager.restoreSession() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
        }
        .animation(.easeInOut, value: authManager.state)
    }
}
