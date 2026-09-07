import XCTest
@testable import Pills

private struct StubAppleCredential: AppleIDCredentialValues {
    let identityTokenData: Data?
    let authorizationCodeData: Data?
    let userIdentifier: String
    let emailAddress: String?
    let personName: PersonNameComponents?
}

@MainActor
final class AppleSignInProviderTests: XCTestCase {
    func testExtractsTokenCodeUserEmailAndName() throws {
        var name = PersonNameComponents()
        name.givenName = "Alice"
        name.familyName = "Example"
        let credential = StubAppleCredential(
            identityTokenData: Data("identity-token".utf8),
            authorizationCodeData: Data("authorization-code".utf8),
            userIdentifier: "apple-user-id",
            emailAddress: "alice@example.com",
            personName: name
        )

        let payload = try AppleSignInPayload.extract(from: credential)

        XCTAssertEqual(payload.identityToken, "identity-token")
        XCTAssertEqual(payload.authorizationCode, "authorization-code")
        XCTAssertEqual(payload.userIdentifier, "apple-user-id")
        XCTAssertEqual(payload.email, "alice@example.com")
        XCTAssertEqual(payload.givenName, "Alice")
        XCTAssertEqual(payload.familyName, "Example")
        XCTAssertEqual(payload.displayName, "Alice Example")
    }

    func testMissingIdentityTokenFailsClearly() {
        let credential = StubAppleCredential(
            identityTokenData: nil,
            authorizationCodeData: nil,
            userIdentifier: "apple-user-id",
            emailAddress: nil,
            personName: nil
        )

        XCTAssertThrowsError(try AppleSignInPayload.extract(from: credential)) { error in
            XCTAssertEqual(error as? AppleSignInError, .missingIdentityToken)
        }
    }

    func testNonUTF8IdentityTokenFailsClearly() {
        let credential = StubAppleCredential(
            identityTokenData: Data([0xFF, 0xFE]),
            authorizationCodeData: nil,
            userIdentifier: "apple-user-id",
            emailAddress: nil,
            personName: nil
        )

        XCTAssertThrowsError(try AppleSignInPayload.extract(from: credential)) { error in
            XCTAssertEqual(error as? AppleSignInError, .identityTokenNotUTF8)
        }
    }

    func testNonUTF8AuthorizationCodeFailsClearly() {
        let credential = StubAppleCredential(
            identityTokenData: Data("identity-token".utf8),
            authorizationCodeData: Data([0xFF, 0xFE]),
            userIdentifier: "apple-user-id",
            emailAddress: nil,
            personName: nil
        )

        XCTAssertThrowsError(try AppleSignInPayload.extract(from: credential)) { error in
            XCTAssertEqual(error as? AppleSignInError, .authorizationCodeNotUTF8)
        }
    }

    func testContinuationCoordinatorRejectsOverlapAndResumesEachRequestOnce() async throws {
        let coordinator = AppleSignInContinuationCoordinator()
        let payload = AppleSignInPayload(
            identityToken: "token", authorizationCode: nil, userIdentifier: "user",
            email: nil, displayName: nil, givenName: nil, familyName: nil
        )
        let first = Task { @MainActor in
            try await coordinator.begin {}
        }
        await Task.yield()

        do {
            _ = try await coordinator.begin {}
            XCTFail("Expected overlapping sign-in to fail")
        } catch {
            XCTAssertEqual(error as? AppleSignInError, .signInAlreadyInProgress)
        }

        coordinator.complete(.success(payload))
        coordinator.complete(.failure(AppleSignInError.invalidCredential))
        let firstValue = try await first.value
        XCTAssertEqual(firstValue, payload)

        let second = Task { @MainActor in
            try await coordinator.begin {}
        }
        await Task.yield()
        coordinator.complete(.success(payload))
        let secondValue = try await second.value
        XCTAssertEqual(secondValue, payload)
    }
}
