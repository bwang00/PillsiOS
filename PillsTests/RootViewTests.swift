import XCTest
import SwiftUI
import SwiftData
@testable import Pills

// MARK: - Stubs

/// Minimal auth API used only to drive `AuthManager` into a target state for
/// RootView render tests. `fetchCurrentUser` is the only call the restore path
/// makes when a token is present; everything else is a no-op so no network or
/// Apple Sign In is ever touched.
private actor StubAuthAPI: AuthAPIProtocol {
    private let currentUserResult: Result<AuthUserResponse, Error>

    init(currentUserResult: Result<AuthUserResponse, Error>) {
        self.currentUserResult = currentUserResult
    }

    func exchangeAppleCredential(_ request: AppleAuthRequest) async throws -> AuthResponse {
        throw APIError.invalidResponse
    }

    func fetchCurrentUser() async throws -> AuthUserResponse {
        try currentUserResult.get()
    }

    func setAuthToken(_ token: String?) async {}
    func clearAuthToken(ifMatching token: String) async -> Bool { true }
    func setUnauthorizedHandler(_ handler: (@Sendable (String) async -> Void)?) async {}
}

/// Token store whose `loadToken()` always throws, driving `AuthManager` into
/// the recoverable `.failed` state during `configure`.
@MainActor
private final class FailingAuthTokenStore: AuthTokenStore {
    enum StoreError: Error { case loadFailed }
    func loadToken() throws -> String? { throw StoreError.loadFailed }
    func saveToken(_ token: String) throws {}
    func removeToken() throws {}
}

// MARK: - Rendered-tree inspection

/// A snapshot of everything user-visible that a `UIHostingController`
/// materialized for a SwiftUI view. SwiftUI backs `Text` with `UILabel`,
/// `ProgressView` with `UIActivityIndicatorView`, and `TabView` with
/// `UITabBar`, so we collect text, accessibility labels, tab titles, and the
/// set of UIKit class names present in the hierarchy.
private struct RenderedTree {
    var strings: Set<String> = []
    var classNames: Set<String> = []

    var hasTabBar: Bool { classNames.contains("UITabBar") }
    var hasActivityIndicator: Bool {
        classNames.contains { $0.contains("ActivityIndicator") || $0.contains("ProgressView") }
    }

    func contains(_ text: String) -> Bool { strings.contains(text) }
}

// MARK: - Tests

@MainActor
final class RootViewTests: XCTestCase {

    private var container: ModelContainer!

    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(
            for: Guide.self, Session.self, Conversation.self, ChatMessage.self,
            User.self, PendingSessionCompletion.self,
            configurations: config
        )
    }

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    // MARK: State drivers

    /// `.restoring` is the initial state before `configure` runs.
    private func makeRestoringManager() -> AuthManager {
        AuthManager(
            appleSignInProvider: StubAppleSignInProvider(),
            api: StubAuthAPI(currentUserResult: .failure(APIError.unauthorized)),
            tokenStore: InMemoryAuthTokenStore()
        )
    }

    /// No stored token + unauthorized API → `configure` invalidates → `.signedOut`.
    private func makeSignedOutManager() async -> AuthManager {
        let manager = AuthManager(
            appleSignInProvider: StubAppleSignInProvider(),
            api: StubAuthAPI(currentUserResult: .failure(APIError.unauthorized)),
            tokenStore: InMemoryAuthTokenStore()
        )
        try? await manager.configure(modelContext: container.mainContext)
        return manager
    }

    /// Valid token + successful `fetchCurrentUser` → `.signedIn`.
    private func makeSignedInManager() async -> AuthManager {
        let user = AuthUserResponse(
            id: "backend-user", username: "alice", displayName: "Alice",
            isAdmin: false, authProvider: "apple"
        )
        let manager = AuthManager(
            appleSignInProvider: StubAppleSignInProvider(),
            api: StubAuthAPI(currentUserResult: .success(user)),
            tokenStore: InMemoryAuthTokenStore(token: jwt(subject: "backend-user"))
        )
        try? await manager.configure(modelContext: container.mainContext)
        return manager
    }

    /// `loadToken()` throws → `configure` fails → `.failed`.
    private func makeFailedManager() async -> AuthManager {
        let manager = AuthManager(
            appleSignInProvider: StubAppleSignInProvider(),
            api: StubAuthAPI(currentUserResult: .failure(APIError.unauthorized)),
            tokenStore: FailingAuthTokenStore()
        )
        try? await manager.configure(modelContext: container.mainContext)
        return manager
    }

    // MARK: Rendering

    private func render(_ authManager: AuthManager) -> RenderedTree {
        renderTree(RootView(), authManager: authManager)
    }

    /// Hosts `content` in a live `UIWindow`, pumps the runloop so SwiftUI
    /// commits a render pass, and returns everything inspectable that got
    /// materialized. SwiftUI does not create any child views (or accessibility
    /// elements) until the hosting view is in a visible window — `loadView
    /// IfNeeded()` alone leaves `_UIHostingView` empty.
    private func renderTree<Content: View>(_ content: Content, authManager: AuthManager) -> RenderedTree {
        let hosted = content
            .environmentObject(authManager)
            .environment(NetworkMonitor())
            .modelContainer(container)
        let controller = UIHostingController(rootView: hosted)
        let frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.frame = frame

        let window = UIWindow(frame: frame)
        window.rootViewController = controller
        window.isHidden = false
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        window.setNeedsLayout()
        window.layoutIfNeeded()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        window.layoutIfNeeded()
        CATransaction.commit()
        CATransaction.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        window.layoutIfNeeded()
        CATransaction.flush()

        var tree = RenderedTree()
        collect(from: window, into: &tree)
        collectAccessibility(from: window, into: &tree, depth: 0)

        window.resignKey()
        window.isHidden = true
        window.rootViewController = nil
        return tree
    }

    private func collect(from view: UIView, into tree: inout RenderedTree) {
        tree.classNames.insert(String(describing: type(of: view)))

        if let label = view as? UILabel, let text = label.text, !text.isEmpty {
            tree.strings.insert(text)
        }
        if let button = view as? UIButton {
            for state: UIControl.State in [.normal, .selected, .application] {
                if let title = button.title(for: state), !title.isEmpty {
                    tree.strings.insert(title)
                }
            }
            if let current = button.currentTitle, !current.isEmpty {
                tree.strings.insert(current)
            }
        }
        if let tabBar = view as? UITabBar {
            for item in tabBar.items ?? [] {
                if let title = item.title, !title.isEmpty { tree.strings.insert(title) }
                if let al = item.accessibilityLabel, !al.isEmpty { tree.strings.insert(al) }
            }
        }
        if let accessibilityLabel = view.accessibilityLabel, !accessibilityLabel.isEmpty {
            tree.strings.insert(accessibilityLabel)
        }

        for subview in view.subviews {
            collect(from: subview, into: &tree)
        }
    }

    /// Walks the accessibility tree, which is how a window-hosted SwiftUI view
    /// exposes its `Text`/`Button`/`TabView` content even though it does not
    /// create a 1:1 `UILabel` per `Text`. Collects labels, identifiers, and
    /// values, and records the runtime class of each element.
    private func collectAccessibility(from element: Any, into tree: inout RenderedTree, depth: Int) {
        guard depth < 60 else { return }

        tree.classNames.insert(String(describing: type(of: element)))

        if let object = element as? NSObject {
            if let label = object.accessibilityLabel, !label.isEmpty {
                tree.strings.insert(label)
            }
            if let value = object.accessibilityValue, !value.isEmpty {
                tree.strings.insert(value)
            }
        }
        if let identifiable = element as? UIAccessibilityIdentification,
           let identifier = identifiable.accessibilityIdentifier, !identifier.isEmpty {
            tree.strings.insert(identifier)
        }

        if let container = element as? UIView {
            if let elements = container.accessibilityElements {
                for child in elements {
                    collectAccessibility(from: child, into: &tree, depth: depth + 1)
                }
            }
            for subview in container.subviews {
                collectAccessibility(from: subview, into: &tree, depth: depth + 1)
            }
        }
    }

    // MARK: Branch assertions
    //
    // What a UIHostingController render can observe is limited: SwiftUI only
    // bridges *some* views into inspectable UIKit. `ProgressView` becomes a
    // `SwiftUIActivityIndicatorView`, and `TabView`/`NavigationStack` become a
    // real `UITabBar`/`UINavigationBar` (whose titles we can read). But a
    // plain `VStack` of `Text`/`Button` — SignInView, the restoring caption,
    // the failed-state heading and retry button — renders via SwiftUI's own
    // display list and exposes no `UILabel`/accessibility string in a unit-test
    // host (no accessibility server is running). These tests therefore assert
    // the signals that DO materialize and, for the text-only branches, assert
    // the negative (the auth gate stays closed / no app UI) rather than the
    // exact copy. Asserting SignInView vs. failed-state *content* would require
    // structural view inspection (e.g. ViewInspector), which was intentionally
    // out of scope for this target.

    func testRestoringStateShowsSpinnerAndKeepsAppHidden() async {
        let manager = makeRestoringManager()
        XCTAssertEqual(manager.state, .restoring)

        let tree = render(manager)

        XCTAssertTrue(
            tree.hasActivityIndicator,
            "restoring should bridge ProgressView to an activity indicator; classes=\(tree.classNames.sorted())"
        )
        XCTAssertFalse(tree.hasTabBar, "main tabs must not render while restoring")
    }

    func testSignedOutStateKeepsAuthGateClosed() async {
        let manager = await makeSignedOutManager()
        XCTAssertEqual(manager.state, .signedOut)

        let tree = render(manager)

        XCTAssertFalse(tree.hasTabBar, "signed-out must never expose the main tab UI")
        XCTAssertFalse(tree.hasActivityIndicator, "signed-out shows SignInView, which has no spinner")
    }

    func testFailedStateKeepsAuthGateClosedWithoutSpinner() async {
        let manager = await makeFailedManager()
        XCTAssertEqual(manager.state, .failed)

        let tree = render(manager)

        XCTAssertFalse(tree.hasTabBar, "failed must never expose the main tab UI")
        XCTAssertFalse(
            tree.hasActivityIndicator,
            "failed shows a retry button, not a spinner — distinguishes it from restoring"
        )
    }

    func testSignedInStateOpensMainTabsWithHomeChatAndHistory() async {
        await isolateSharedAPIClient()
        let manager = await makeSignedInManager()
        XCTAssertEqual(manager.state, .signedIn)

        let tree = render(manager)

        XCTAssertTrue(tree.hasTabBar, "main tab bar missing; classes=\(tree.classNames.sorted())")
        XCTAssertTrue(tree.contains("首页"), "home tab missing; got \(tree.strings.sorted())")
        XCTAssertTrue(tree.contains("AI 教练"), "chat tab missing; got \(tree.strings.sorted())")
        XCTAssertTrue(tree.contains("记录"), "history tab missing; got \(tree.strings.sorted())")
        XCTAssertTrue(
            tree.contains("Pills"),
            "HomeView navigation title missing; got \(tree.strings.sorted())"
        )
    }

    // MARK: HomeView wiring

    func testHomeViewRendersNavigationTitleWhenSignedIn() async {
        await isolateSharedAPIClient()
        let manager = await makeSignedInManager()
        XCTAssertEqual(manager.state, .signedIn)

        let tree = renderTree(HomeView(), authManager: manager)

        XCTAssertTrue(
            tree.contains("Pills"),
            "HomeView should mount its NavigationStack titled Pills; got \(tree.strings.sorted())"
        )
    }

    // MARK: Helpers

    /// `HomeView.task` builds a `HomeViewModel` backed by the real
    /// `APIClient.shared`. Clearing its token guarantees
    /// `tokenSnapshot(for: .required)` throws `.unauthorized` *before* any HTTP
    /// request, so a signed-in render never reaches the network even if the
    /// host happens to have a keychain token. This keeps the render hermetic.
    private func isolateSharedAPIClient() async {
        await APIClient.shared.setAuthToken(nil)
    }

    private func jwt(subject: String, expiresAt: Date = Date().addingTimeInterval(3_600)) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [
            "sub": subject,
            "exp": Int(expiresAt.timeIntervalSince1970),
        ])
        let payload = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(payload).signature"
    }
}

/// Apple Sign In is never invoked by these tests (RootView only renders
/// SignInView; it does not call `signInWithApple`). This stub exists solely to
/// satisfy `AuthManager`'s injected-provider requirement without touching the
/// real AuthenticationServices provider. `AppleSignInProvider` is class-bound
/// (`AnyObject`) and `@MainActor`, so the stub must be too.
@MainActor
private final class StubAppleSignInProvider: AppleSignInProvider {
    func signIn() async throws -> AppleSignInPayload {
        throw AuthError.invalidCredential
    }
}
