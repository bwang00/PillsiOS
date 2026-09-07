import Foundation
import Security

@MainActor
protocol AuthTokenStore: AnyObject {
    func loadToken() throws -> String?
    func saveToken(_ token: String) throws
    func removeToken() throws
}

@MainActor
final class KeychainAuthTokenStore: AuthTokenStore {
    private let service: String
    private let account: String

    init(
        service: String = Bundle.main.bundleIdentifier ?? "xyz.blueping.pills",
        account: String = "backend-auth-token-\(APIConfiguration.defaultDataNamespace())"
    ) {
        self.service = service
        self.account = account
    }

    func loadToken() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidTokenData
        }
        return token
    }

    func saveToken(_ token: String) throws {
        let data = Data(token.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError(status: updateStatus)
        }

        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    }

    func removeToken() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

@MainActor
final class InMemoryAuthTokenStore: AuthTokenStore {
    private var token: String?

    init(token: String? = nil) {
        self.token = token
    }

    func loadToken() throws -> String? { token }
    func saveToken(_ token: String) throws { self.token = token }
    func removeToken() throws { token = nil }
}

enum KeychainError: LocalizedError {
    case operationFailed(OSStatus)
    case invalidTokenData

    init(status: OSStatus) {
        self = .operationFailed(status)
    }

    var errorDescription: String? {
        switch self {
        case .operationFailed(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
            return "Keychain operation failed: \(message) (\(status))"
        case .invalidTokenData:
            return "Stored authentication token is not valid UTF-8"
        }
    }
}
