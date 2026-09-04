import SwiftUI

struct SignInView: View {
    @EnvironmentObject var authManager: AuthManager
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // App branding
            VStack(spacing: 12) {
                Image("GinkgoLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 100, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 22))

                Text("Pills")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("你的身心放松伙伴")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Sign in button
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
            }

            #if DEBUG
            Button {
                authManager.devSignIn()
            } label: {
                Text("Dev 跳过登录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
            #endif

            Spacer()
        }
        .padding(.horizontal, 24)
        .alert("登录失败", isPresented: $showError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        #if DEBUG
        .task {
            authManager.devSignIn()
        }
        #endif
    }
}
