import SwiftUI
import SwiftData

/// Main tab bar with Home, Chat, and History tabs.
struct MainTabView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var authManager: AuthManager
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem {
                    Label("首页", systemImage: "house.fill")
                }
                .tag(0)

            ChatView()
                .tabItem {
                    Label("AI 教练", systemImage: "bubble.left.and.bubble.right.fill")
                }
                .tag(1)

            HistoryView()
                .tabItem {
                    Label("记录", systemImage: "clock.arrow.circlepath")
                }
                .tag(2)
        }
        .tint(.green)
        .task {
            // Drain any practice sessions queued from earlier offline failures.
            // MainTabView only appears once signed in, so the shared API client
            // already carries a valid token.
            await SessionCompletionQueue.flush(
                modelContext: modelContext,
                api: APIClient.shared
            )
        }
    }
}
