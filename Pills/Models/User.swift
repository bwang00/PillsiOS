import Foundation
import SwiftData

/// Local cache of the authenticated backend user. Authentication tokens are never stored here.
@Model
final class User {
    @Attribute(.unique) var id: String
    var username: String
    var displayName: String = ""
    var isAdmin: Bool = false
    var authProvider: String = "apple"
    var appleUserIdentifier: String?
    var createdAt: Date

    init(
        id: String,
        username: String,
        displayName: String = "",
        isAdmin: Bool = false,
        authProvider: String = "apple",
        appleUserIdentifier: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.isAdmin = isAdmin
        self.authProvider = authProvider
        self.appleUserIdentifier = appleUserIdentifier
        self.createdAt = createdAt
    }
}
