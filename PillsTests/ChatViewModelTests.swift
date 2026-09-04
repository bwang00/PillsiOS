import XCTest
import SwiftData
@testable import Pills

// MARK: - Mock API client

final class MockChatAPI: ChatAPIProtocol, @unchecked Sendable {
    var createConversationResult: Result<ConversationDTO, Error> = .success(
        ConversationDTO(id: "conv-1", created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z", username: nil, message_count: 0, first_message: nil)
    )
    var fetchDetailResult: Result<ConversationDetailDTO, Error> = .success(
        ConversationDetailDTO(id: "conv-1", created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z", username: nil, messages: [])
    )
    var fetchConversationsResult: Result<[ConversationDTO], Error> = .success([])
    var sendMessageResult: Result<MessageDTO, Error> = .success(
        MessageDTO(id: "msg-1", conversation_id: "conv-1", role: "user", content: "hi", created_at: "2026-01-01T00:00:00Z")
    )
    var sendAIChatResult: Result<AIChatResponse, Error> = .success(
        AIChatResponse(reply: "AI reply")
    )

    var createConversationCallCount = 0
    var sendMessageCallCount = 0
    var sendAIChatCallCount = 0

    func createConversation(username: String?) async throws -> ConversationDTO {
        createConversationCallCount += 1
        return try createConversationResult.get()
    }

    func fetchConversationDetail(_ id: String) async throws -> ConversationDetailDTO {
        return try fetchDetailResult.get()
    }

    func fetchConversations(username: String?, limit: Int) async throws -> [ConversationDTO] {
        return try fetchConversationsResult.get()
    }

    func sendMessage(conversationId: String, role: String, content: String) async throws -> MessageDTO {
        sendMessageCallCount += 1
        return try sendMessageResult.get()
    }

    func sendAIChat(message: String, history: [AIChatHistoryEntry], username: String?) async throws -> AIChatResponse {
        sendAIChatCallCount += 1
        return try sendAIChatResult.get()
    }
}

// MARK: - Tests

@MainActor
final class ChatViewModelTests: XCTestCase {

    private var container: ModelContainer!
    private var mockAPI: MockChatAPI!

    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(
            for: Guide.self, Session.self, Conversation.self, ChatMessage.self, User.self,
            configurations: config
        )
        mockAPI = MockChatAPI()
    }

    private func makeViewModel(username: String? = "testuser") -> ChatViewModel {
        ChatViewModel(
            modelContext: container.mainContext,
            username: username,
            api: mockAPI
        )
    }

    // MARK: - createNewConversation

    func testCreateNewConversation_success() async {
        let vm = makeViewModel()
        await vm.createNewConversation()

        XCTAssertEqual(vm.conversationId, "conv-1")
        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertNil(vm.errorMessage)
    }

    func testCreateNewConversation_failure() async {
        mockAPI.createConversationResult = .failure(APIError.networkUnavailable)
        let vm = makeViewModel()
        await vm.createNewConversation()

        XCTAssertNil(vm.conversationId)
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.errorMessage!.contains("无法创建对话"))
    }

    // MARK: - loadOrCreateConversation

    func testLoadOrCreate_whenNoConversationId_createsNew() async {
        let vm = makeViewModel()
        XCTAssertNil(vm.conversationId)

        await vm.loadOrCreateConversation()

        XCTAssertEqual(mockAPI.createConversationCallCount, 1)
        XCTAssertEqual(vm.conversationId, "conv-1")
    }

    func testLoadOrCreate_whenHasConversationId_loadsExisting() async {
        let vm = makeViewModel()
        vm.conversationId = "existing-conv"

        mockAPI.fetchDetailResult = .success(
            ConversationDetailDTO(
                id: "existing-conv",
                created_at: "2026-01-01T00:00:00Z",
                updated_at: "2026-01-01T00:00:00Z",
                username: nil,
                messages: [
                    MessageDTO(id: "m1", conversation_id: "existing-conv", role: "user", content: "hello", created_at: "2026-01-01T00:00:00Z"),
                    MessageDTO(id: "m2", conversation_id: "existing-conv", role: "assistant", content: "hi there", created_at: "2026-01-01T00:00:01Z"),
                ]
            )
        )

        await vm.loadOrCreateConversation()

        XCTAssertEqual(vm.conversationId, "existing-conv")
        XCTAssertEqual(vm.messages.count, 2)
        XCTAssertEqual(vm.messages[0].role, "user")
        XCTAssertEqual(vm.messages[0].content, "hello")
        XCTAssertEqual(vm.messages[1].role, "assistant")
        XCTAssertEqual(vm.messages[1].content, "hi there")
    }

    // MARK: - sendMessage

    func testSendMessage_success() async {
        let vm = makeViewModel()
        vm.conversationId = "conv-1"
        vm.inputText = "你好"

        await vm.sendMessage()

        // User message added locally
        XCTAssertEqual(vm.messages.count, 2) // user + AI
        XCTAssertEqual(vm.messages[0].role, "user")
        XCTAssertEqual(vm.messages[0].content, "你好")
        XCTAssertEqual(vm.messages[1].role, "assistant")
        XCTAssertEqual(vm.messages[1].content, "AI reply")

        // Input cleared
        XCTAssertEqual(vm.inputText, "")
        XCTAssertFalse(vm.isSending)
        XCTAssertNil(vm.errorMessage)

        // API calls: 1 user save + 1 AI save = 2 sendMessage, 1 sendAIChat
        XCTAssertEqual(mockAPI.sendMessageCallCount, 2)
        XCTAssertEqual(mockAPI.sendAIChatCallCount, 1)
    }

    func testSendMessage_emptyInput_doesNothing() async {
        let vm = makeViewModel()
        vm.conversationId = "conv-1"
        vm.inputText = "   "

        await vm.sendMessage()

        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertEqual(mockAPI.sendAIChatCallCount, 0)
    }

    func testSendMessage_autoCreatesConversation() async {
        let vm = makeViewModel()
        XCTAssertNil(vm.conversationId)
        vm.inputText = "hello"

        await vm.sendMessage()

        XCTAssertEqual(mockAPI.createConversationCallCount, 1)
        XCTAssertEqual(vm.conversationId, "conv-1")
        XCTAssertEqual(vm.messages.count, 2) // user + AI
    }

    func testSendMessage_aiFailure_showsError() async {
        mockAPI.sendAIChatResult = .failure(APIError.timeout)
        let vm = makeViewModel()
        vm.conversationId = "conv-1"
        vm.inputText = "test"

        await vm.sendMessage()

        // User message still added locally
        XCTAssertEqual(vm.messages.count, 1)
        XCTAssertEqual(vm.messages[0].role, "user")

        // Error shown
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.errorMessage!.contains("AI 回复失败"))
        XCTAssertFalse(vm.isSending)
    }

    func testSendMessage_trimsWhitespace() async {
        let vm = makeViewModel()
        vm.conversationId = "conv-1"
        vm.inputText = "  hello world  "

        await vm.sendMessage()

        XCTAssertEqual(vm.messages[0].content, "hello world")
    }

    // MARK: - loadConversationList

    func testLoadConversationList_success() async {
        mockAPI.fetchConversationsResult = .success([
            ConversationDTO(id: "c1", created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z", username: nil, message_count: 1, first_message: nil),
            ConversationDTO(id: "c2", created_at: "2026-01-02T00:00:00Z", updated_at: "2026-01-02T00:00:00Z", username: nil, message_count: 2, first_message: nil),
        ])
        let vm = makeViewModel()
        let result = await vm.loadConversationList()

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].id, "c1")
    }

    func testLoadConversationList_failure_returnsEmpty() async {
        mockAPI.fetchConversationsResult = .failure(APIError.timeout)
        let vm = makeViewModel()
        let result = await vm.loadConversationList()

        XCTAssertTrue(result.isEmpty)
    }
}
