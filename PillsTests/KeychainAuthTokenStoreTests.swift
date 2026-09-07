import XCTest
import Security
@testable import Pills

@MainActor
final class KeychainAuthTokenStoreTests: XCTestCase {
    func testInMemoryStorePersistsOnlyTokenUntilRemoved() throws {
        let store = InMemoryAuthTokenStore()

        XCTAssertNil(try store.loadToken())
        try store.saveToken("backend-token")
        XCTAssertEqual(try store.loadToken(), "backend-token")
        try store.removeToken()
        XCTAssertNil(try store.loadToken())
    }

    func testKeychainStoreRoundTripsAndUsesThisDeviceOnlyAccessibility() throws {
        let service = "xyz.blueping.pills.tests.\(UUID().uuidString)"
        let account = "backend-auth-token"
        let store = KeychainAuthTokenStore(service: service, account: account)
        defer { try? store.removeToken() }

        try store.saveToken("first-token")
        XCTAssertEqual(try store.loadToken(), "first-token")
        try store.saveToken("second-token")
        XCTAssertEqual(try store.loadToken(), "second-token")

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )

        try store.removeToken()
        XCTAssertNil(try store.loadToken())
    }

    func testNamespacedAccountsIsolateTokensPerEnvironment() throws {
        // Two stores sharing a service but differing only by account (the
        // environment namespace) must not see each other's token. This guards
        // the per-environment cache isolation invariant.
        let service = "xyz.blueping.pills.tests.\(UUID().uuidString)"
        let dev = KeychainAuthTokenStore(service: service, account: "backend-auth-token-pills-development")
        let prod = KeychainAuthTokenStore(service: service, account: "backend-auth-token-pills-production")
        defer {
            try? dev.removeToken()
            try? prod.removeToken()
        }

        XCTAssertNil(try dev.loadToken())
        XCTAssertNil(try prod.loadToken())

        try dev.saveToken("dev-token")
        XCTAssertEqual(try dev.loadToken(), "dev-token")
        XCTAssertNil(try prod.loadToken(), "Production namespace must not read the development token")

        try prod.saveToken("prod-token")
        XCTAssertEqual(try prod.loadToken(), "prod-token")
        XCTAssertEqual(try dev.loadToken(), "dev-token", "Development token must be untouched by the production write")

        try prod.removeToken()
        XCTAssertNil(try prod.loadToken())
        XCTAssertEqual(try dev.loadToken(), "dev-token")
    }

    func testRemoveTokenOnEmptyKeychainIsNoOp() throws {
        let store = KeychainAuthTokenStore(
            service: "xyz.blueping.pills.tests.\(UUID().uuidString)",
            account: "backend-auth-token"
        )
        XCTAssertNil(try store.loadToken())
        XCTAssertNoThrow(try store.removeToken(), "Deleting an absent item must not throw")
    }

    func testInMemoryStoreCanBeSeededAtInit() throws {
        let store = InMemoryAuthTokenStore(token: "seeded")
        XCTAssertEqual(try store.loadToken(), "seeded")
        try store.removeToken()
        XCTAssertNil(try store.loadToken())
    }
}
