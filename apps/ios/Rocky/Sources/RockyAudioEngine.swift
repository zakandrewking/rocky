import AVFoundation

/// One AVAudioEngine shared by everything Rocky plays locally: her Hume voice and the Eridian
/// chord layer each get their own player node into the same mixer.
///
/// Deliberately one engine, not one per feature (desktop uses a separate AudioContext for each,
/// which is free in a browser and is not here): a second engine means a second render thread
/// contending for the same audio session that WebRTC is already driving the microphone through.
///
/// Everything runs at 48 kHz mono float, which is what Hume sends, so its PCM needs no rate
/// conversion on the hot path; the mixer converts once to whatever the hardware wants.
@MainActor
final class RockyAudioEngine {
    static let shared = RockyAudioEngine()

    static let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    var sampleRate: Double { Self.format.sampleRate }

    private let engine = AVAudioEngine()
    private var started = false

    private init() {}

    /// Attaches a player and returns it started, ready to be scheduled onto.
    func makePlayer(volume: Float) -> AVAudioPlayerNode {
        let player = AVAudioPlayerNode()
        player.volume = volume
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: Self.format)
        try? start()
        player.play()
        return player
    }

    func start() throws {
        guard !started else { return }
        engine.prepare()
        try engine.start()
        started = true
    }

    func stop() {
        guard started else { return }
        engine.stop()
        started = false
    }

    /// The engine stops itself if the audio session is interrupted or the route changes under it;
    /// callers about to schedule audio use this to bring it back rather than going silent.
    func restartIfNeeded() {
        guard started, !engine.isRunning else { return }
        started = false
        try? start()
    }
}
