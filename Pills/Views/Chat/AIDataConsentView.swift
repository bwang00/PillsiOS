import SwiftUI

/// Disclosure sheet shown before any message leaves the device for the
/// third-party AI services (guideline 5.1.1(i) / 5.1.2(i)): what is sent,
/// who receives it, and for what purpose, with explicit grant / deny actions.
struct AIDataConsentView: View {
    let onGrant: () -> Void
    let onDeny: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("在使用 AI 教练前，请了解并选择是否同意以下数据分享：")
                        .font(.body)

                    disclosureRow(
                        icon: "text.bubble",
                        title: "发送什么",
                        detail: "你发送给 AI 教练的消息文字（如使用语音输入，则为语音转写后的文字）。"
                    )
                    disclosureRow(
                        icon: "arrow.up.forward.app",
                        title: "发送给谁",
                        detail: "经由我们的服务器（pills.blueping.xyz）转发给阿里云通义千问（DashScope）用于生成回复；回复文字会发送给 Microsoft edge-tts 用于合成语音播报。"
                    )
                    disclosureRow(
                        icon: "sparkles",
                        title: "用途",
                        detail: "仅用于生成 AI 教练的回复与语音播报，不用于广告或追踪。"
                    )

                    Link(destination: URL(string: "https://pills.blueping.xyz/privacy")!) {
                        Label("查看完整《隐私政策》", systemImage: "doc.text")
                    }

                    Divider()

                    Text("Before using the AI coach, please review and choose whether to allow the following data sharing:")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("What is sent: the text of your messages to the AI coach (or the speech-to-text transcript if you use voice input). Who receives it: our server (pills.blueping.xyz), which forwards it to Alibaba Cloud Qwen (DashScope) to generate the reply; the reply text is sent to Microsoft edge-tts for speech synthesis. Purpose: generating the AI coach's reply and spoken output only — never for advertising or tracking. Full details are in our Privacy Policy.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 10) {
                        Button {
                            onGrant()
                            dismiss()
                        } label: {
                            Text("同意并继续")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Button(role: .cancel) {
                            onDeny()
                            dismiss()
                        } label: {
                            Text("暂不同意")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                    .padding(.top, 4)
                }
                .padding()
            }
            .navigationTitle("数据分享披露")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func disclosureRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Notice shown in place of the composer when the user has denied sharing,
/// explaining that nothing is sent and offering a way to review again.
struct AIDataConsentDeniedNotice: View {
    let onReview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("你未同意向第三方 AI 服务发送内容，AI 教练不会发送任何消息。")
                .font(.footnote)
            Text("You have not allowed sharing with the third-party AI services, so the AI coach will not send any content.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("重新查看披露并选择", action: onReview)
                .font(.footnote.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    AIDataConsentView(onGrant: {}, onDeny: {})
}
