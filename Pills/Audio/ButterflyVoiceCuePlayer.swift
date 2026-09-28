import Foundation

/// Spoken left/right cues for the butterfly-hug metronome.
///
/// The metronome fires a cue on every beat (~1s), so cues must play with no
/// network latency. Implementations warm a cache via `prepare()` and then play
/// cached clips synchronously in `cue(_:)`.
protocol ButterflyVoiceCuePlayer: AnyObject {
    /// Warms the cue cache so per-beat cues play instantly.
    func prepare() async
    /// Speaks the cue for the side being tapped.
    func cue(_ side: ButterflySide)
    /// Silences any in-flight cue.
    func stop()
}

/// Default implementation backed by the shared edge-tts `TTSPlayer`.
@MainActor
final class TTSButterflyVoiceCuePlayer: ButterflyVoiceCuePlayer {
    private let tts: TTSPlayer

    init(tts: TTSPlayer) {
        self.tts = tts
    }

    func prepare() async {
        await tts.prefetch(["左", "右"])
    }

    func cue(_ side: ButterflySide) {
        tts.speakCached(side == .left ? "左" : "右")
    }

    func stop() {
        tts.stop()
    }
}
