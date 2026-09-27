import SwiftUI
import SwiftData

struct ButterflyHugView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let guide: Guide

    @State private var viewModel: ButterflyHugViewModel?
    @State private var haptics: HapticPlayer = ImpactHapticPlayer()

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            butterfly
                .frame(height: 220)
                .accessibilityElement()
                .accessibilityLabel("蝴蝶拥抱引导，当前\(viewModel?.activeSide.rawValue == "right" ? "右" : "左")侧")

            Text(instruction)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if let vm = viewModel, vm.isRunning {
                Text("已轻拍 \(vm.tapCount) 次")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(viewModel?.formattedTime ?? "00:00")
                .font(.system(.title3, design: .monospaced))
                .foregroundStyle(.secondary)
                .accessibilityLabel("已练习 \(viewModel?.formattedTime ?? "00:00")")

            Spacer()

            controlButton
                .padding(.bottom, 40)
        }
        .navigationTitle(guide.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let vm = viewModel, vm.isRunning {
                    Button("结束") { vm.stop() }
                }
            }
        }
        .onAppear {
            if let viewModel {
                viewModel.handleViewAppearance(isAppActive: scenePhase == .active)
            } else {
                let vm = ButterflyHugViewModel(
                    guide: guide, modelContext: modelContext, haptics: haptics)
                vm.handleViewAppearance(isAppActive: scenePhase == .active)
                viewModel = vm
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            viewModel?.handleAppActivity(isActive: newPhase == .active)
        }
        .onDisappear {
            viewModel?.handleViewDisappearance()
        }
    }

    private var instruction: String {
        "双臂交叉，双手轻放于对侧肩上。跟随节奏，左右交替轻拍，同时缓慢呼吸。感觉平静后即可停止。"
    }

    // MARK: - Butterfly wings

    @ViewBuilder
    private var butterfly: some View {
        let active = viewModel?.activeSide ?? .left
        let running = viewModel?.isRunning ?? false
        HStack(spacing: 8) {
            wing(side: .left, isActive: running && active == .left)
            wing(side: .right, isActive: running && active == .right)
        }
    }

    @ViewBuilder
    private func wing(side: ButterflySide, isActive: Bool) -> some View {
        Image(systemName: side == .left ? "hand.raised.fill" : "hand.raised.fill")
            .resizable()
            .scaledToFit()
            .frame(width: 90, height: 140)
            .scaleEffect(side == .left ? -1 : 1) // mirror the left hand
            .foregroundStyle(isActive ? Color.accentColor : Color.secondary.opacity(0.35))
            .scaleEffect(isActive ? 1.08 : 1.0)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isActive)
            .accessibilityHidden(true)
    }

    // MARK: - Control button

    @ViewBuilder
    private var controlButton: some View {
        if let vm = viewModel {
            if vm.isFinished {
                Button { dismiss() } label: {
                    Text("完成").fontWeight(.semibold)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent).tint(.green).padding(.horizontal, 32)
            } else if vm.isRunning {
                Button { vm.stop() } label: {
                    Label("停止", systemImage: "stop.fill").fontWeight(.semibold)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .buttonStyle(.bordered).tint(.red).padding(.horizontal, 32)
            } else {
                Button { Task { await vm.start() } } label: {
                    Label("开始练习", systemImage: "play.fill").fontWeight(.semibold)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent).tint(.blue).padding(.horizontal, 32)
            }
        }
    }
}
