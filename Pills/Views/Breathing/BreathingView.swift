import SwiftUI
import SwiftData

struct BreathingView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let guide: Guide

    @State private var viewModel: BreathingViewModel?
    @StateObject private var ttsPlayer = TTSPlayer()

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Breathing circle
            BreathingCircle(scale: viewModel?.circleScale ?? 0.6)
                .frame(height: 250)

            // Phase label
            Text(viewModel?.phaseLabel ?? "准备开始")
                .font(.title)
                .fontWeight(.medium)
                .animation(.easeInOut, value: viewModel?.phaseLabel)

            // Cycle counter
            if let vm = viewModel, vm.isRunning {
                Text(vm.cycleLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Timer
            Text(viewModel?.formattedTime ?? "00:00")
                .font(.system(.title3, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()

            // Controls
            controlButton
                .padding(.bottom, 40)
        }
        .navigationTitle(guide.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let vm = viewModel, vm.isRunning {
                    Button("结束") {
                        Task { await vm.stop() }
                    }
                }
            }
        }
        .onAppear {
            if viewModel == nil {
                viewModel = BreathingViewModel(
                    guide: guide,
                    modelContext: modelContext,
                    ttsPlayer: ttsPlayer
                )
            }
        }
        .interactiveDismissDisabled(viewModel?.isRunning == true)
    }

    // MARK: - Control button

    @ViewBuilder
    private var controlButton: some View {
        if let vm = viewModel {
            if vm.phase == .finished {
                Button {
                    dismiss()
                } label: {
                    Text("完成")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .padding(.horizontal, 32)
            } else if vm.isRunning {
                Button {
                    Task { await vm.stop() }
                } label: {
                    Label("停止", systemImage: "stop.fill")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .padding(.horizontal, 32)
            } else {
                Button {
                    Task { await vm.start() }
                } label: {
                    Label("开始练习", systemImage: "play.fill")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .padding(.horizontal, 32)
            }
        }
    }
}
