import Foundation
import AVFoundation

/// Protocol for the TTS API method. Enables testability.
protocol TTSAPIProtocol: Sendable {
    func synthesizeSpeech(_ text: String) async throws -> Data
}

extension APIClient: TTSAPIProtocol {}

/// Plays TTS audio returned from the server-side edge-tts endpoint.
@MainActor
final class TTSPlayer: ObservableObject {
    @Published var isPlaying = false

    private var player: AVAudioPlayer?
    private let api: TTSAPIProtocol
    private let onError: (Error) -> Void

    init(
        api: TTSAPIProtocol = APIClient.shared,
        onError: @escaping (Error) -> Void = { error in
            print("⚠️ TTS fetch failed: \(error)")
        }
    ) {
        self.api = api
        self.onError = onError
        configureAudioSession()
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        } catch {
            print("⚠️ AudioSession config failed: \(error)")
        }
    }

    /// Fetches TTS audio from the server and plays it immediately.
    func speak(_ text: String) async {
        guard !Task.isCancelled else { return }
        do {
            let audioData = try await api.synthesizeSpeech(text)
            guard !Task.isCancelled else { return }
            play(data: audioData)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            onError(error)
        }
    }

    // MARK: - Cache (low-latency cues)

    private var cache: [String: Data] = [:]

    /// Synthesizes and caches the given texts so later `speakCached` calls play
    /// instantly. Used to warm short metronome cues (e.g. 左/右) before a run.
    func prefetch(_ texts: [String]) async {
        await withTaskGroup(of: (String, Data?).self) { group in
            for text in texts where cache[text] == nil {
                let api = self.api
                group.addTask {
                    do { return (text, try await api.synthesizeSpeech(text)) }
                    catch { return (text, nil) }
                }
            }
            for await (text, data) in group {
                if let data { cache[text] = data }
            }
        }
    }

    /// Plays a cached cue immediately with no network latency. On a cache miss
    /// it fetches, caches, and plays asynchronously.
    func speakCached(_ text: String) {
        if let data = cache[text] {
            play(data: data)
        } else {
            Task { [weak self] in
                guard let self, !Task.isCancelled else { return }
                do {
                    let data = try await self.api.synthesizeSpeech(text)
                    guard !Task.isCancelled else { return }
                    self.cache[text] = data
                    self.play(data: data)
                } catch {
                    guard !Task.isCancelled, !(error is CancellationError) else { return }
                    self.onError(error)
                }
            }
        }
    }

    /// Plays raw MP3/PCM data through AVAudioPlayer.
    func play(data: Data) {
        stop()
        do {
            player = try AVAudioPlayer(data: data)
            player?.delegate = delegateProxy
            player?.play()
            isPlaying = true
        } catch {
            print("⚠️ Audio playback failed: \(error)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
    }

    // MARK: - Delegate proxy

    private lazy var delegateProxy = AudioDelegateProxy(player: self)

    private class AudioDelegateProxy: NSObject, AVAudioPlayerDelegate {
        weak var player: TTSPlayer?

        init(player: TTSPlayer) {
            self.player = player
        }

        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            Task { @MainActor in
                self.player?.isPlaying = false
            }
        }
    }
}
