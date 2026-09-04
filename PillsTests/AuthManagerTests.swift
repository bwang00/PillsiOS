import XCTest
import SwiftData
@testable import Pills

@MainActor
final class AuthManagerTests: XCTestCase {

    private var container: ModelContainer!
    private var authManager: AuthManager!

    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(
            for: Guide.self, Session.self, Conversation.self, ChatMessage.self, User.self,
            configurations: config
        )
        authManager = AuthManager()
    }

    // MARK: - Initial state

    func testInitialState_noUser() {
        XCTAssertNil(authManager.currentUser)
        XCTAssertFalse(authManager.isSigningIn)
    }

    // MARK: - configure

    func testConfigure_emptyDatabase_noUser() {
        authManager.configure(modelContext: container.mainContext)
        XCTAssertNil(authManager.currentUser)
    }

    func testConfigure_withExistingUser_loadsUser() {
        let user = User(id: "u1", username: "alice", appleUserIdentifier: "apple-123")
        container.mainContext.insert(user)
        try! container.mainContext.save()

        authManager.configure(modelContext: container.mainContext)

        XCTAssertNotNil(authManager.currentUser)
        XCTAssertEqual(authManager.currentUser?.username, "alice")
        XCTAssertEqual(authManager.currentUser?.appleUserIdentifier, "apple-123")
    }

    func testConfigure_withMultipleUsers_loadsMostRecent() {
        let older = User(id: "u1", username: "older", createdAt: Date().addingTimeInterval(-3600))
        let newer = User(id: "u2", username: "newer", createdAt: Date())
        container.mainContext.insert(older)
        container.mainContext.insert(newer)
        try! container.mainContext.save()

        authManager.configure(modelContext: container.mainContext)

        XCTAssertEqual(authManager.currentUser?.username, "newer")
    }

    // MARK: - signOut

    func testSignOut_clearsCurrentUser() {
        authManager.configure(modelContext: container.mainContext)
        authManager.devSignIn()
        XCTAssertNotNil(authManager.currentUser)

        authManager.signOut()

        XCTAssertNil(authManager.currentUser)
    }

    func testSignOut_deletesFromDatabase() {
        authManager.configure(modelContext: container.mainContext)
        authManager.devSignIn()
        XCTAssertNotNil(authManager.currentUser)

        authManager.signOut()

        let descriptor = FetchDescriptor<User>()
        let remaining = try! container.mainContext.fetch(descriptor)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testSignOut_whenNoUser_doesNotCrash() {
        authManager.configure(modelContext: container.mainContext)
        XCTAssertNil(authManager.currentUser)

        authManager.signOut() // should not crash

        XCTAssertNil(authManager.currentUser)
    }

    // MARK: - devSignIn (DEBUG only)

    #if DEBUG
    func testDevSignIn_createsUser() {
        authManager.configure(modelContext: container.mainContext)
        authManager.devSignIn()

        XCTAssertNotNil(authManager.currentUser)
        XCTAssertEqual(authManager.currentUser?.username, "dev_user")
    }

    func testDevSignIn_persistsToDatabase() {
        authManager.configure(modelContext: container.mainContext)
        authManager.devSignIn()

        let descriptor = FetchDescriptor<User>()
        let users = try! container.mainContext.fetch(descriptor)
        XCTAssertEqual(users.count, 1)
        XCTAssertEqual(users.first?.username, "dev_user")
    }

    func testDevSignIn_multipleTimesCreatesMultipleUsers() {
        authManager.configure(modelContext: container.mainContext)
        authManager.devSignIn()
        authManager.devSignIn()

        let descriptor = FetchDescriptor<User>()
        let users = try! container.mainContext.fetch(descriptor)
        XCTAssertEqual(users.count, 2)
    }
    #endif

    // MARK: - AuthError

    func testAuthError_description() {
        let error = AuthError.invalidCredential
        XCTAssertEqual(error.errorDescription, "Sign in failed")
    }
}
