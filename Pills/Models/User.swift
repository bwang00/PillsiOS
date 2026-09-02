import Foundation
import SwiftData

/// Local user profile.
/// Stores Sign in with Apple credentials and chosen username.
@Model
final class User {
    @Attribute(.unique) var id: String
    var username: String
    var appleUserIdentifier: String?
    var createdAt: Date

    init(id: String, username: String, appleUserIdentifier: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.username = username
        self.appleUserIdentifier = appleUserIdentifier
        self.createdAt = createdAt
    }
}
