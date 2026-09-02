import SwiftUI
import SwiftData

/// Main tab bar with Home, Chat, and History tabs.
struct MainTabView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var authManager: AuthManager

    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label("首页", systemImage: "house.fill")
                }

            ChatView()
                .tabItem {
                    Label("AI 教练", systemImage: "bubble.left.and.bubble.right.fill")
                }

            HistoryView()
                .tabItem {
                    Label("记录", systemImage: "clock.arrow.circlepath")
                }
        }
        .tint(.green)
    }
}
