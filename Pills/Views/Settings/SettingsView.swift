import SwiftUI

/// Persistent Settings surface: privacy-policy and support links plus the
/// app version. The privacy link used to exist only inside the one-time AI
/// consent sheet, so consenting users had no in-app path back to it.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("关于") {
                    LabeledContent("版本", value: AppInfo.versionDisplay)
                        .accessibilityLabel("版本 \(AppInfo.versionDisplay)")
                }

                Section {
                    Link(destination: AppInfo.privacyURL) {
                        Label("隐私政策", systemImage: "doc.text")
                    }
                    Link(destination: AppInfo.supportURL) {
                        Label("支持", systemImage: "questionmark.circle")
                    }
                } footer: {
                    Text("隐私政策与支持页面将在浏览器中打开。")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
