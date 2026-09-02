import Foundation
import AuthenticationServices
import SwiftData

/// Manages Sign in with Apple flow and local user session.
@MainActor
final class AuthManager: NSObject, ObservableObject {
    @Published var currentUser: User?
    @Published var isSigningIn = false

    private var modelContext: ModelContext?
    private var continuation: CheckedContinuation<String, Error>?

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
        loadCurrentUser()
    }

    // MARK: - Sign in with Apple

    func signInWithApple() async throws {
        isSigningIn = true
        defer { isSigningIn = false }

        let appleUserId = try await performAppleSignIn()

        // Generate or retrieve username
        let username = await resolveUsername(appleUserId: appleUserId)

        // Persist user
        let user = User(
            id: UUID().uuidString,
            username: username,
            appleUserIdentifier: appleUserId
        )
        modelContext?.insert(user)
        try? modelContext?.save()
        currentUser = user
    }

    private func performAppleSignIn() async throws -> String {
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self

        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            controller.performRequests()
        }
    }

    private func resolveUsername(appleUserId: String) async -> String {
        // Check if we already have a user for this Apple ID
        if let existing = loadUser(byAppleId: appleUserId) {
            return existing.username
        }
        // Generate a default username from Apple ID suffix
        let suffix = String(appleUserId.suffix(6))
        return "user_\(suffix)"
    }

    // MARK: - Persistence

    private func loadCurrentUser() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<User>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        currentUser = try? context.fetch(descriptor).first
    }

    private func loadUser(byAppleId appleId: String) -> User? {
        guard let context = modelContext else { return nil }
        let descriptor = FetchDescriptor<User>(
            predicate: #Predicate { $0.appleUserIdentifier == appleId }
        )
        return try? context.fetch(descriptor).first
    }

    func signOut() {
        if let user = currentUser {
            modelContext?.delete(user)
            try? modelContext?.save()
        }
        currentUser = nil
    }
}

// MARK: - ASAuthorizationControllerDelegate

extension AuthManager: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            Task { @MainActor in
                self.continuation?.resume(throwing: AuthError.invalidCredential)
            }
            return
        }
        let userId = credential.user
        Task { @MainActor in
            self.continuation?.resume(returning: userId)
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        Task { @MainActor in
            self.continuation?.resume(throwing: error)
        }
    }
}

// MARK: - ASAuthorizationControllerPresentationContextProviding

extension AuthManager: ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first
        else {
            return UIWindow()
        }
        return window
    }
}

enum AuthError: LocalizedError {
    case invalidCredential
    var errorDescription: String? { "Sign in failed" }
}
