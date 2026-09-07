import SwiftUI

struct SignInView: View {
    @EnvironmentObject var authManager: AuthManager
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            VStack(spacing: 12) {
                Image("GinkgoLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 100, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .accessibilityHidden(true)

                Text("Pills")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("你的身心放松伙伴")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task {
                    do {
                        try await authManager.signInWithApple()
                    } catch {
                        errorMessage = error.localizedDescription
                        showError = true
                    }
                }
            } label: {
                HStack {
                    Image(systemName: "apple.logo")
                        .accessibilityHidden(true)
                    Text("通过 Apple 登录")
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(.black)
            .disabled(authManager.isSigningIn)

            if authManager.isSigningIn {
                ProgressView()
                    .accessibilityLabel("正在登录")
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .alert("登录失败", isPresented: $showError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }
}
