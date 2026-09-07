import Foundation

struct AppleAuthRequest: Encodable, Equatable, Sendable {
    let identityToken: String
    let authorizationCode: String?
    let displayName: String?
    let givenName: String?
    let familyName: String?

    init(payload: AppleSignInPayload) {
        identityToken = payload.identityToken
        authorizationCode = payload.authorizationCode
        displayName = payload.displayName
        givenName = payload.givenName
        familyName = payload.familyName
    }

    enum CodingKeys: String, CodingKey {
        case identityToken = "identity_token"
        case authorizationCode = "authorization_code"
        case displayName = "display_name"
        case givenName = "given_name"
        case familyName = "family_name"
    }
}

struct AuthUserResponse: Decodable, Equatable, Sendable {
    let id: String
    let username: String
    let displayName: String
    let isAdmin: Bool
    let authProvider: String

    enum CodingKeys: String, CodingKey {
        case id, username
        case displayName = "display_name"
        case isAdmin = "is_admin"
        case authProvider = "auth_provider"
    }
}

struct AuthResponse: Decodable, Equatable, Sendable {
    let token: String
    let id: String
    let username: String
    let displayName: String
    let isAdmin: Bool
    let authProvider: String

    var user: AuthUserResponse {
        AuthUserResponse(
            id: id,
            username: username,
            displayName: displayName,
            isAdmin: isAdmin,
            authProvider: authProvider
        )
    }

    enum CodingKeys: String, CodingKey {
        case token, id, username
        case displayName = "display_name"
        case isAdmin = "is_admin"
        case authProvider = "auth_provider"
    }
}

protocol AuthAPIProtocol: Sendable {
    func exchangeAppleCredential(_ request: AppleAuthRequest) async throws -> AuthResponse
    func fetchCurrentUser() async throws -> AuthUserResponse
    func setAuthToken(_ token: String?) async
    func clearAuthToken(ifMatching token: String) async -> Bool
    func setUnauthorizedHandler(_ handler: (@Sendable (String) async -> Void)?) async
}
