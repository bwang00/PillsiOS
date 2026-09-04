import XCTest
@testable import Pills

// MARK: - Mock TTS API

actor MockTTSAPI: TTSAPIProtocol {
    struct Snapshot: Sendable {
        let callCount: Int
        let lastText: String?
    }

    private var responseData = Data()
    private var responseError: APIError?
    private var shouldSuspend = false
    private var callCount = 0
    private var lastText: String?
    private var requests: [CheckedContinuation<Data, Error>] = []

    func configure(
        data: Data = Data(),
        error: APIError? = nil,
        suspend: Bool = false
    ) {
        responseData = data
        responseError = error
        shouldSuspend = suspend
    }

    func synthesizeSpeech(_ text: String) async throws -> Data {
        callCount += 1
        lastText = text

        if shouldSuspend {
            return try await withCheckedThrowingContinuation { continuation in
                requests.append(continuation)
            }
        }
        if let responseError {
            throw responseError
        }
        return responseData
    }

    func resumeRequests() {
        let pendingRequests = requests
        requests.removeAll()
        for continuation in pendingRequests {
            if let responseError {
                continuation.resume(throwing: responseError)
            } else {
                continuation.resume(returning: responseData)
            }
        }
    }

    func shutdown() {
        shouldSuspend = false
        resumeRequests()
    }

    func snapshot() -> Snapshot {
        Snapshot(callCount: callCount, lastText: lastText)
    }
}

private actor TTSCompletionProbe {
    private var isFinished = false

    func finish() {
        isFinished = true
    }

    func snapshot() -> Bool {
        isFinished
    }
}

// MARK: - Tests

@MainActor
final class TTSPlayerTests: XCTestCase {

    private var mockAPI: MockTTSAPI!
    private var player: TTSPlayer!
    private var tasksUnderTest: [Task<Void, Never>] = []
    private var completionObservers: [Task<Void, Never>] = []

    override func setUp() {
        super.setUp()
        mockAPI = MockTTSAPI()
        player = TTSPlayer(api: mockAPI)
    }

    override func tearDown() async throws {
        let unfinishedTasks = tasksUnderTest
        let unfinishedObservers = completionObservers
        unfinishedTasks.forEach { $0.cancel() }
        unfinishedObservers.forEach { $0.cancel() }
        await mockAPI.shutdown()
        player.stop()

        let cleanup = expectation(description: "tracked TTS tasks cleaned up")
        let cleanupProbe = TTSCompletionProbe()
        let cleanupObserver = Task {
            for task in unfinishedTasks {
                await task.value
            }
            for observer in unfinishedObservers {
                await observer.value
            }
            guard !Task.isCancelled else { return }
            await cleanupProbe.finish()
            cleanup.fulfill()
        }
        await fulfillment(of: [cleanup], timeout: 2)
        if !(await cleanupProbe.snapshot()) {
            XCTFail("Timed out cleaning up tracked TTS tasks")
            cleanupObserver.cancel()
        }

        tasksUnderTest.removeAll()
        completionObservers.removeAll()
        player = nil
        mockAPI = nil
        try await super.tearDown()
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
        await mockAPI.configure(data: Data([0x00]))
        let speakTask = Task { await player.speak("hello") }
        guard await waitForCompletion(of: speakTask, "successful TTS request") else { return }

        let snapshot = await mockAPI.snapshot()
        XCTAssertEqual(snapshot.callCount, 1)
        XCTAssertEqual(snapshot.lastText, "hello")
    }

    func testSpeak_apiFailure_reportsErrorWithoutCrashing() async {
        var reportedErrorCount = 0
        player = TTSPlayer(api: mockAPI) { _ in
            reportedErrorCount += 1
        }
        await mockAPI.configure(error: .timeout)

        let speakTask = Task { await player.speak("test") }
        guard await waitForCompletion(of: speakTask, "failed TTS request") else { return }

        let snapshot = await mockAPI.snapshot()
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(snapshot.callCount, 1)
        XCTAssertEqual(reportedErrorCount, 1)
    }

    func testSpeak_passesCorrectText() async {
        let speakTask = Task { await player.speak("吸气") }
        guard await waitForCompletion(of: speakTask, "localized TTS request") else { return }

        let snapshot = await mockAPI.snapshot()
        XCTAssertEqual(snapshot.lastText, "吸气")
    }

    func testSpeak_whenCancelledErrorIsWrapped_doesNotReportError() async {
        var reportedErrorCount = 0
        player = TTSPlayer(api: mockAPI) { _ in
            reportedErrorCount += 1
        }
        await mockAPI.configure(error: .unknown, suspend: true)

        let speakTask = Task { await player.speak("吸气") }
        tasksUnderTest.append(speakTask)
        let requestStarted = await waitUntil("TTS request to start") {
            await self.mockAPI.snapshot().callCount == 1
        }
        guard requestStarted else { return }

        speakTask.cancel()
        await mockAPI.resumeRequests()
        guard await waitForCompletion(of: speakTask, "cancelled TTS request") else { return }

        XCTAssertEqual(reportedErrorCount, 0)
        XCTAssertFalse(player.isPlaying)
    }

    private func waitForCompletion(
        of task: Task<Void, Never>,
        _ description: String,
        timeout: TimeInterval = 2
    ) async -> Bool {
        tasksUnderTest.append(task)
        let completion = expectation(description: description)
        let probe = TTSCompletionProbe()
        let observer = Task {
            await task.value
            guard !Task.isCancelled else { return }
            await probe.finish()
            completion.fulfill()
        }
        completionObservers.append(observer)

        await fulfillment(of: [completion], timeout: timeout)
        let didFinish = await probe.snapshot()
        if !didFinish {
            XCTFail("Timed out waiting for \(description)")
            task.cancel()
            observer.cancel()
        }
        return didFinish
    }

    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while clock.now < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        if await condition() {
            return true
        }
        XCTFail("Timed out waiting for \(description)")
        return false
    }
}
