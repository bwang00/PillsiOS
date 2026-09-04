import XCTest
@testable import Pills

// MARK: - Mock TTS API

final class MockTTSAPI: TTSAPIProtocol, @unchecked Sendable {
    var result: Result<Data, Error> = .success(Data())
    var callCount = 0
    var lastText: String?

    func synthesizeSpeech(_ text: String) async throws -> Data {
        callCount += 1
        lastText = text
        return try result.get()
    }
}

// MARK: - Tests

@MainActor
final class TTSPlayerTests: XCTestCase {

    private var mockAPI: MockTTSAPI!
    private var player: TTSPlayer!

    override func setUp() {
        super.setUp()
        mockAPI = MockTTSAPI()
        player = TTSPlayer(api: mockAPI)
    }

    // MARK: - Initial state

    func testInitialState_notPlaying() {
        XCTAssertFalse(player.isPlaying)
    }

    // MARK: - stop

    func testStop_whenNotPlaying_staysFalse() {
        player.stop()
        XCTAssertFalse(player.isPlaying)
    }

    // MARK: - play(data:)

    func testPlay_withInvalidData_doesNotCrash() {
        let garbage = Data([0x00, 0x01, 0x02])
        player.play(data: garbage)

        // AVAudioPlayer will fail to decode garbage data, isPlaying stays false
        XCTAssertFalse(player.isPlaying)
    }

    func testStop_afterPlay_resetsState() {
        // Even with invalid data, stop should work cleanly
        player.play(data: Data([0xFF]))
        player.stop()

        XCTAssertFalse(player.isPlaying)
    }

    // MARK: - speak

    func testSpeak_callsAPI() async {
        mockAPI.result = .success(Data([0x00])) // invalid audio but tests API call
        await player.speak("hello")

        XCTAssertEqual(mockAPI.callCount, 1)
        XCTAssertEqual(mockAPI.lastText, "hello")
    }

    func testSpeak_apiFailure_doesNotCrash() async {
        mockAPI.result = .failure(APIError.timeout)
        await player.speak("test")

        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(mockAPI.callCount, 1)
    }

    func testSpeak_passesCorrectText() async {
        mockAPI.result = .success(Data())
        await player.speak("吸气")

        XCTAssertEqual(mockAPI.lastText, "吸气")
    }
}
