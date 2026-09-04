import SwiftUI
import SwiftData

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: HistoryViewModel?

    var body: some View {
        NavigationStack {
            List {
                if let vm = viewModel {
                    if vm.sessions.isEmpty && !vm.isLoading {
                        emptyState
                    } else {
                        ForEach(vm.sessions, id: \.id) { session in
                            sessionRow(session, vm: vm)
                        }

                        if vm.canLoadMore {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .onAppear {
                                    Task { await vm.loadMore() }
                                }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("练习记录")
            .refreshable {
                await viewModel?.refresh()
            }
            .overlay {
                if let vm = viewModel, vm.isLoading && vm.sessions.isEmpty {
                    ProgressView("加载中...")
                }
            }
            .task {
                if viewModel == nil {
                    let vm = HistoryViewModel(modelContext: modelContext)
                    viewModel = vm
                    await vm.loadInitial()
                }
            }
        }
    }

    // MARK: - Subviews

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("暂无练习记录")
                .font(.headline)
            Text("完成一次呼吸练习后，记录将显示在这里")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .listRowSeparator(.hidden)
    }

    private func sessionRow(_ session: Session, vm: HistoryViewModel) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(vm.displayName(for: session.guideSlug))
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(vm.formatDate(session.startedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                if let duration = session.durationSeconds {
                    Text(vm.formatDuration(duration))
                        .font(.subheadline)
                        .foregroundStyle(.green)
                }
                Image(systemName: session.completedAt != nil ? "checkmark.circle.fill" : "clock")
                    .font(.caption)
                    .foregroundStyle(session.completedAt != nil ? .green : .secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
