import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var authManager: AuthManager
    @State private var viewModel: HomeViewModel?
    @State private var selectedGuide: Guide?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Stats header
                    if let vm = viewModel {
                        statsHeader(vm: vm)
                    }

                    // Guide cards
                    guideSection

                    // Recent sessions
                    if let vm = viewModel, !vm.recentSessions.isEmpty {
                        recentSection(sessions: vm.recentSessions, vm: vm)
                    }
                }
                .padding()
            }
            .navigationTitle("Pills")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        authManager.signOut()
                    } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .refreshable {
                await viewModel?.loadData()
            }
            .task {
                if viewModel == nil {
                    let vm = HomeViewModel(modelContext: modelContext)
                    viewModel = vm
                    await vm.loadData()
                }
            }
            .navigationDestination(item: $selectedGuide) { guide in
                BreathingView(guide: guide)
            }
        }
    }

    // MARK: - Subviews

    private func statsHeader(vm: HomeViewModel) -> some View {
        HStack(spacing: 20) {
            statCard(title: "连续练习", value: "\(vm.streakDays)", unit: "天")
            statCard(title: "总练习", value: "\(vm.totalSessions)", unit: "次")
        }
    }

    private func statCard(title: String, value: String, unit: String) -> some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.title2)
                    .fontWeight(.bold)
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var guideSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("呼吸练习")
                .font(.headline)

            if let vm = viewModel {
                if vm.isLoading && vm.guides.isEmpty {
                    ProgressView("加载中...")
                        .frame(maxWidth: .infinity)
                        .padding()
                } else if let error = vm.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                } else {
                    ForEach(vm.guides, id: \.slug) { guide in
                        GuideCard(guide: guide) {
                            selectedGuide = guide
                        }
                    }
                }
            }
        }
    }

    private func recentSection(sessions: [Session], vm: HomeViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("最近练习")
                .font(.headline)

            ForEach(sessions, id: \.id) { session in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(vm.displayName(for: session.guideSlug))
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(session.startedAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let duration = session.durationSeconds {
                        Text(vm.formatDuration(duration))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .background(.gray.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let secs = seconds % 60
        return minutes > 0 ? "\(minutes)分\(secs)秒" : "\(secs)秒"
    }
}
