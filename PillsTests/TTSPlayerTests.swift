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

    func testPlay_withValidAudioData_setsIsPlaying() {
        // Positive control: proves a decodable fixture actually flips isPlaying,
        // so the cancellation test below is not a false positive (garbage data
        // fails to decode and would leave isPlaying false regardless of any
        // cancellation guard).
        player.play(data: Self.makeValidWAVData())

        XCTAssertTrue(player.isPlaying)

        player.stop()
        XCTAssertFalse(player.isPlaying)
    }

    /// Builds a minimal, decodable 16-bit mono PCM WAV so `AVAudioPlayer(data:)`
    /// initializes successfully without depending on any real audio output.
    private static func makeValidWAVData() -> Data {
        let sampleRate = 8000
        let numSamples = 800
        let numChannels = 1
        let bitsPerSample = 16
        let byteRate = sampleRate * numChannels * bitsPerSample / 8
        let blockAlign = numChannels * bitsPerSample / 8
        let dataSize = numSamples * blockAlign

        var data = Data()
        func appendString(_ s: String) { data.append(contentsOf: s.utf8) }
        func appendUInt32LE(_ value: UInt32) {
            var v = value.littleEndian
            data.append(Data(bytes: &v, count: 4))
        }
        func appendUInt16LE(_ value: UInt16) {
            var v = value.littleEndian
            data.append(Data(bytes: &v, count: 2))
        }

        appendString("RIFF")
        appendUInt32LE(UInt32(36 + dataSize))
        appendString("WAVE")
        appendString("fmt ")
        appendUInt32LE(16)                 // PCM fmt chunk size
        appendUInt16LE(1)                  // audio format = PCM
        appendUInt16LE(UInt16(numChannels))
        appendUInt32LE(UInt32(sampleRate))
        appendUInt32LE(UInt32(byteRate))
        appendUInt16LE(UInt16(blockAlign))
        appendUInt16LE(UInt16(bitsPerSample))
        appendString("data")
        appendUInt32LE(UInt32(dataSize))
        for i in 0..<numSamples {
            let sample = Int16(sin(Double(i) * 0.1) * 10_000)
            var le = sample.littleEndian
            data.append(Data(bytes: &le, count: 2))
        }
        return data
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

    func testSpeak_whenTaskAlreadyCancelled_doesNotCallAPI() async {
        var reportedErrorCount = 0
        player = TTSPlayer(api: mockAPI) { _ in
            reportedErrorCount += 1
        }
        await mockAPI.configure(data: Data([0x00]))

        // Cancel before the MainActor-isolated speak body can run, so the
        // leading `guard !Task.isCancelled` short-circuits the request.
        let speakTask = Task { await player.speak("吸气") }
        speakTask.cancel()
        guard await waitForCompletion(of: speakTask, "pre-cancelled TTS request") else { return }

        let snapshot = await mockAPI.snapshot()
        XCTAssertEqual(snapshot.callCount, 0)
        XCTAssertEqual(reportedErrorCount, 0)
        XCTAssertFalse(player.isPlaying)
    }

    func testSpeak_cancelledDuringFetch_doesNotPlayReturnedAudio() async {
        // Return decodable audio so that, absent the post-await cancellation
        // guard, speak would call play(data:) and flip isPlaying to true.
        await mockAPI.configure(data: Self.makeValidWAVData(), suspend: true)

        let speakTask = Task { await player.speak("吸气") }
        tasksUnderTest.append(speakTask)
        let requestStarted = await waitUntil("TTS request to start") {
            await self.mockAPI.snapshot().callCount == 1
        }
        guard requestStarted else { return }

        // Cancel while suspended, then let the fetch succeed with valid audio.
        speakTask.cancel()
        await mockAPI.resumeRequests()
        guard await waitForCompletion(of: speakTask, "cancelled-during-fetch TTS request") else { return }

        XCTAssertFalse(player.isPlaying, "Cancellation must skip playback even when valid audio arrives")
    }

    func testSpeak_notCancelled_playsReturnedAudio() async {
        // Positive control for the test above: the same valid audio, without
        // cancellation, must reach play(data:) and set isPlaying.
        await mockAPI.configure(data: Self.makeValidWAVData())

        let speakTask = Task { await player.speak("吸气") }
        guard await waitForCompletion(of: speakTask, "successful TTS playback") else { return }

        XCTAssertTrue(player.isPlaying)
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
