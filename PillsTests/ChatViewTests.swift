import XCTest
import SwiftUI
import SwiftData
import UIKit
@testable import Pills

/// Integration tests for ChatView — verifies rendering and state wiring.
@MainActor
final class ChatViewTests: XCTestCase {

    private var container: ModelContainer!

    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(
            for: Guide.self, Session.self, Conversation.self, ChatMessage.self, User.self,
            configurations: config
        )
    }

    // MARK: - Rendering

    func testChatView_rendersWithoutCrash() {
        let authManager = AuthManager()
        let view = ChatView()
            .environmentObject(authManager)
            .modelContainer(container)

        let controller = UIHostingController(rootView: view)
        controller.loadViewIfNeeded()

        // If we get here without a crash, the view hierarchy is valid
        XCTAssertNotNil(controller.view)
    }

    // MARK: - Regression: input text field must not swallow the content area

    /// Root cause of the "blank AI Chat" bug: the UIKit-backed `ChatTextField`
    /// accepted whatever height SwiftUI proposed, so inside the bottom
    /// `safeAreaInset` it stretched to fill the whole screen, collapsing the
    /// message `ScrollView` to zero height (welcome + bubbles never visible).
    /// The field must size to its intrinsic/control height, not the proposal.
    func testChatTextField_doesNotExpandToFillTallProposal() throws {
        let tf = ChatTextField(
            text: .constant(""),
            placeholder: "输入消息...",
            onReturn: { _ in }
        )
        let controller = UIHostingController(
            rootView: tf.frame(width: 300, height: 600)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        CATransaction.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        controller.view.layoutIfNeeded()

        let field = try XCTUnwrap(
            Self.findTextField(in: controller.view),
            "expected a UITextField in the hosted hierarchy"
        )
        XCTAssertLessThanOrEqual(
            field.frame.height, 80,
            "text field must not expand to fill the proposed height (got \(field.frame.height))"
        )
    }

    private static func findTextField(in view: UIView) -> UITextField? {
        if let field = view as? UITextField { return field }
        for subview in view.subviews {
            if let found = findTextField(in: subview) { return found }
        }
        return nil
    }

    func testWelcomeView_renders() {
        let welcome = ChatWelcomeView()
        let controller = UIHostingController(rootView: welcome)
        controller.loadViewIfNeeded()

        XCTAssertNotNil(controller.view)
    }

    // MARK: - SuggestionChip

    func testSuggestionChip_renders() {
        let chip = SuggestionChip(text: "测试建议", icon: "star.fill")
        let controller = UIHostingController(rootView: chip)
        controller.loadViewIfNeeded()

        XCTAssertNotNil(controller.view)
    }

    // MARK: - TypingIndicator

    func testTypingIndicator_renders() {
        let indicator = TypingIndicator()
        let controller = UIHostingController(rootView: indicator)
        controller.loadViewIfNeeded()

        XCTAssertNotNil(controller.view)
    }

    // MARK: - MessageBubble

    func testMessageBubble_userMessage() {
        let msg = ChatViewModel.ChatMessageItem(
            id: "1", role: "user", content: "你好", timestamp: Date()
        )
        let bubble = MessageBubble(message: msg)
        let controller = UIHostingController(rootView: bubble)
        controller.loadViewIfNeeded()

        XCTAssertNotNil(controller.view)
    }

    func testMessageBubble_aiMessage() {
        let msg = ChatViewModel.ChatMessageItem(
            id: "2", role: "assistant", content: "你好！我是你的AI教练。", timestamp: Date()
        )
        let bubble = MessageBubble(message: msg)
        let controller = UIHostingController(rootView: bubble)
        controller.loadViewIfNeeded()

        XCTAssertNotNil(controller.view)
    }

    func testMessageBubble_longContent() {
        let longText = String(repeating: "这是一条很长的消息。", count: 50)
        let msg = ChatViewModel.ChatMessageItem(
            id: "3", role: "assistant", content: longText, timestamp: Date()
        )
        let bubble = MessageBubble(message: msg)
        let controller = UIHostingController(rootView: bubble)
        controller.loadViewIfNeeded()

        XCTAssertNotNil(controller.view)
    }

    // MARK: - ChatTextField

    func testChatTextField_renders() {
        let tf = ChatTextField(
            text: .constant("hello"),
            placeholder: "输入消息...",
            onReturn: { _ in }
        )
        let controller = UIHostingController(rootView: tf)
        controller.loadViewIfNeeded()

        XCTAssertNotNil(controller.view)
    }

    // MARK: - BubbleShape

    func testBubbleShape_userPath() {
        let shape = BubbleShape(isUser: true)
        let path = shape.path(in: CGRect(x: 0, y: 0, width: 200, height: 50))
        XCTAssertFalse(path.isEmpty)
    }

    func testBubbleShape_aiPath() {
        let shape = BubbleShape(isUser: false)
        let path = shape.path(in: CGRect(x: 0, y: 0, width: 200, height: 50))
        XCTAssertFalse(path.isEmpty)
    }
}
