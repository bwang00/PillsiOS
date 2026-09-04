import SwiftUI
import SwiftData

@main
struct PillsApp: App {
    @StateObject private var authManager = AuthManager()
    @State private var networkMonitor = NetworkMonitor()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authManager)
                .environment(networkMonitor)
        }
        .modelContainer(for: [Guide.self, Session.self, Conversation.self, ChatMessage.self, User.self]) { result in
            if case .success(let container) = result {
                authManager.configure(modelContext: container.mainContext)
            }
        }
    }
}

/// Root view that switches between onboarding and main tab view.
struct RootView: View {
    @EnvironmentObject var authManager: AuthManager

    var body: some View {
        Group {
            if authManager.currentUser != nil {
                MainTabView()
            } else {
                SignInView()
            }
        }
        .animation(.easeInOut, value: authManager.currentUser?.id)
    }
}
