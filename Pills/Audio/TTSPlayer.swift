import Foundation
import AVFoundation

/// Plays TTS audio returned from the server-side edge-tts endpoint.
@MainActor
final class TTSPlayer: ObservableObject {
    @Published var isPlaying = false

    private var player: AVAudioPlayer?

    init() {
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
        do {
            let audioData = try await APIClient.shared.synthesizeSpeech(text)
            play(data: audioData)
        } catch {
            print("⚠️ TTS fetch failed: \(error)")
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
