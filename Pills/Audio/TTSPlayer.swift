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
