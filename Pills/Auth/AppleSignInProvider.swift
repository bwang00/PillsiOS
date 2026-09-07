import AuthenticationServices
import Foundation
import UIKit

struct AppleSignInPayload: Equatable, Sendable {
    let identityToken: String
    let authorizationCode: String?
    let userIdentifier: String
    let email: String?
    let displayName: String?
    let givenName: String?
    let familyName: String?

    static func extract(from credential: AppleIDCredentialValues) throws -> AppleSignInPayload {
        guard let identityTokenData = credential.identityTokenData else {
            throw AppleSignInError.missingIdentityToken
        }
        guard let identityToken = String(data: identityTokenData, encoding: .utf8) else {
            throw AppleSignInError.identityTokenNotUTF8
        }

        let authorizationCode: String?
        if let codeData = credential.authorizationCodeData {
            guard let decodedCode = String(data: codeData, encoding: .utf8) else {
                throw AppleSignInError.authorizationCodeNotUTF8
            }
            authorizationCode = decodedCode
        } else {
            authorizationCode = nil
        }

        let givenName = credential.personName?.givenName?.nilIfEmpty
        let familyName = credential.personName?.familyName?.nilIfEmpty
        let displayName = [givenName, familyName]
            .compactMap { $0 }
            .joined(separator: " ")
            .nilIfEmpty

        return AppleSignInPayload(
            identityToken: identityToken,
            authorizationCode: authorizationCode,
            userIdentifier: credential.userIdentifier,
            email: credential.emailAddress?.nilIfEmpty,
            displayName: displayName,
            givenName: givenName,
            familyName: familyName
        )
    }
}

protocol AppleIDCredentialValues {
    var identityTokenData: Data? { get }
    var authorizationCodeData: Data? { get }
    var userIdentifier: String { get }
    var emailAddress: String? { get }
    var personName: PersonNameComponents? { get }
}

extension ASAuthorizationAppleIDCredential: AppleIDCredentialValues {
    var identityTokenData: Data? { identityToken }
    var authorizationCodeData: Data? { authorizationCode }
    var userIdentifier: String { user }
    var emailAddress: String? { email }
    var personName: PersonNameComponents? { fullName }
}

@MainActor
protocol AppleSignInProvider: AnyObject {
    func signIn() async throws -> AppleSignInPayload
}

@MainActor
final class AppleSignInContinuationCoordinator {
    private var continuation: CheckedContinuation<AppleSignInPayload, Error>?

    func begin(_ start: @escaping () -> Void) async throws -> AppleSignInPayload {
        guard continuation == nil else {
            throw AppleSignInError.signInAlreadyInProgress
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            start()
        }
    }

    func complete(_ result: Result<AppleSignInPayload, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

@MainActor
final class AppleAuthorizationSignInProvider: NSObject, AppleSignInProvider {
    private let coordinator = AppleSignInContinuationCoordinator()
    private var authorizationController: ASAuthorizationController?

    func signIn() async throws -> AppleSignInPayload {
        try await coordinator.begin { [weak self] in
            guard let self else { return }
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.fullName, .email]
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            authorizationController = controller
            controller.performRequests()
        }
    }

    private func finish(_ result: Result<AppleSignInPayload, Error>) {
        authorizationController = nil
        coordinator.complete(result)
    }
}

extension AppleAuthorizationSignInProvider: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        let result: Result<AppleSignInPayload, Error>
        if let credential = authorization.credential as? ASAuthorizationAppleIDCredential {
            result = Result { try AppleSignInPayload.extract(from: credential) }
        } else {
            result = .failure(AppleSignInError.invalidCredential)
        }
        Task { @MainActor [weak self] in self?.finish(result) }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        Task { @MainActor [weak self] in self?.finish(.failure(error)) }
    }
}

extension AppleAuthorizationSignInProvider: ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) ?? UIWindow()
        }
    }
}

enum AppleSignInError: LocalizedError, Equatable {
    case missingIdentityToken
    case identityTokenNotUTF8
    case authorizationCodeNotUTF8
    case invalidCredential
    case signInAlreadyInProgress

    var errorDescription: String? {
        switch self {
        case .missingIdentityToken:
            return "Apple 登录未返回身份令牌"
        case .identityTokenNotUTF8:
            return "Apple 身份令牌格式无效"
        case .authorizationCodeNotUTF8:
            return "Apple 授权码格式无效"
        case .invalidCredential:
            return "Apple 登录凭据无效"
        case .signInAlreadyInProgress:
            return "Apple 登录正在进行中"
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
