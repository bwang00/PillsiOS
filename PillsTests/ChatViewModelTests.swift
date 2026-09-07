import XCTest
import SwiftData
@testable import Pills

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
    var sendAIChatResult: Result<AIChatResponse, Error> = .success(AIChatResponse(reply: "AI reply"))

    var createConversationCallCount = 0
    var sendMessageCallCount = 0
    var sendAIChatCallCount = 0

    func createConversation() async throws -> ConversationDTO {
        createConversationCallCount += 1
        return try createConversationResult.get()
    }

    func fetchConversationDetail(_ id: String) async throws -> ConversationDetailDTO {
        try fetchDetailResult.get()
    }

    func fetchConversations(limit: Int) async throws -> [ConversationDTO] {
        try fetchConversationsResult.get()
    }

    func sendMessage(conversationId: String, role: String, content: String) async throws -> MessageDTO {
        sendMessageCallCount += 1
        return try sendMessageResult.get()
    }

    func sendAIChat(message: String, history: [AIChatHistoryEntry]) async throws -> AIChatResponse {
        sendAIChatCallCount += 1
        return try sendAIChatResult.get()
    }
}

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

    private func makeViewModel() -> ChatViewModel {
        ChatViewModel(modelContext: container.mainContext, api: mockAPI)
    }

    func testCreateNewConversationSuccess() async {
        let vm = makeViewModel()
        await vm.createNewConversation()

        XCTAssertEqual(vm.conversationId, "conv-1")
        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertEqual(mockAPI.createConversationCallCount, 1)
    }

    func testCreateNewConversationFailure() async {
        mockAPI.createConversationResult = .failure(APIError.networkUnavailable)
        let vm = makeViewModel()
        await vm.createNewConversation()

        XCTAssertNil(vm.conversationId)
        XCTAssertTrue(vm.errorMessage?.contains("无法创建对话") == true)
    }

    func testLoadOrCreateLoadsExistingConversation() async {
        let vm = makeViewModel()
        vm.conversationId = "existing-conv"
        mockAPI.fetchDetailResult = .success(
            ConversationDetailDTO(
                id: "existing-conv", created_at: "2026-01-01T00:00:00Z",
                updated_at: "2026-01-01T00:00:00Z", username: "legacy-response-name",
                messages: [
                    MessageDTO(id: "m1", conversation_id: "existing-conv", role: "user", content: "hello", created_at: "2026-01-01T00:00:00Z"),
                    MessageDTO(id: "m2", conversation_id: "existing-conv", role: "assistant", content: "hi", created_at: "2026-01-01T00:00:01Z"),
                ]
            )
        )

        await vm.loadOrCreateConversation()

        XCTAssertEqual(vm.messages.map(\.content), ["hello", "hi"])
    }

    func testSendMessageSuccess() async {
        let vm = makeViewModel()
        vm.conversationId = "conv-1"
        vm.inputText = "  你好  "

        await vm.sendMessage()

        XCTAssertEqual(vm.messages.map(\.content), ["你好", "AI reply"])
        XCTAssertEqual(mockAPI.sendMessageCallCount, 2)
        XCTAssertEqual(mockAPI.sendAIChatCallCount, 1)
        XCTAssertFalse(vm.isSending)
        XCTAssertNil(vm.errorMessage)
    }

    func testSendMessageEmptyInputDoesNothing() async {
        let vm = makeViewModel()
        vm.conversationId = "conv-1"
        vm.inputText = "   "

        await vm.sendMessage()

        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertEqual(mockAPI.sendAIChatCallCount, 0)
    }

    func testSendMessageAutoCreatesConversation() async {
        let vm = makeViewModel()
        vm.inputText = "hello"

        await vm.sendMessage()

        XCTAssertEqual(mockAPI.createConversationCallCount, 1)
        XCTAssertEqual(vm.conversationId, "conv-1")
        XCTAssertEqual(vm.messages.count, 2)
    }

    func testSendMessageAIFailureShowsError() async {
        mockAPI.sendAIChatResult = .failure(APIError.timeout)
        let vm = makeViewModel()
        vm.conversationId = "conv-1"
        vm.inputText = "test"

        await vm.sendMessage()

        XCTAssertEqual(vm.messages.count, 1)
        XCTAssertTrue(vm.errorMessage?.contains("AI 回复失败") == true)
        XCTAssertFalse(vm.isSending)
    }

    func testLoadConversationListReturnsResultsAndDecodesLegacyUsername() async {
        mockAPI.fetchConversationsResult = .success([
            ConversationDTO(id: "c1", created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z", username: "legacy", message_count: 1, first_message: nil),
        ])
        let vm = makeViewModel()

        let result = await vm.loadConversationList()

        XCTAssertEqual(result.first?.username, "legacy")
    }

    func testLoadConversationListFailureReturnsEmpty() async {
        mockAPI.fetchConversationsResult = .failure(APIError.timeout)
        let result = await makeViewModel().loadConversationList()
        XCTAssertTrue(result.isEmpty)
    }
}
