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
    private var players: [AVAudioPlayerNode] = []
    private var observer: NSObjectProtocol?

    private init() {
        // WebRTC activating its own voice-processing audio unit reconfigures the shared session
        // underneath this engine, which arrives here as a configuration change.
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { _ in
            Task { @MainActor in
                RockyLog.write("audio: engine configuration changed")
                RockyAudioEngine.shared.ensureRunning()
            }
        }
    }

    /// Attaches a player and returns it ready to be scheduled onto.
    func makePlayer(volume: Float) -> AVAudioPlayerNode {
        let player = AVAudioPlayerNode()
        player.volume = volume
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: Self.format)
        players.append(player)
        ensureRunning()
        return player
    }

    /// Brings the engine *and every player node* back up.
    ///
    /// Both halves matter. WebRTC starting its microphone stops this engine, and restarting an
    /// engine leaves its player nodes not playing -- so buffers scheduled afterwards are never
    /// rendered and their completion handlers never fire. That is silence with no error anywhere:
    /// audio is accepted, queued, and simply never heard, which is exactly what "Rocky never
    /// responded" looked like. Call this before scheduling anything.
    func ensureRunning() {
        let wasRunning = engine.isRunning
        if !wasRunning {
            engine.prepare()
            do {
                try engine.start()
                RockyLog.write("audio: engine (re)started")
            } catch {
                RockyLog.write("audio: engine failed to start: \(error.localizedDescription)")
                return
            }
        }
        for player in players where !wasRunning || !player.isPlaying {
            player.play()
        }
    }

    func stop() {
        engine.stop()
    }
}
