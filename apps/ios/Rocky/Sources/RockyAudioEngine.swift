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

    /// The things Rocky plays. Fixed channels rather than a player per session: connecting again
    /// used to attach another set of nodes to the same engine and never detach the old
    /// ones.
    enum Channel: CaseIterable {
        case voice, chords, effects
    }

    private let engine = AVAudioEngine()
    private var players: [Channel: AVAudioPlayerNode] = [:]
    private var observer: NSObjectProtocol?
    private var mutedSpeechListenerInstalled = false

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
                RockyAudioEngine.shared.reconnectPlayers()
                RockyAudioEngine.shared.ensureRunning()
            }
        }
    }

    /// The player for a channel, attached on first use and reused for the app's lifetime.
    func player(for channel: Channel) -> AVAudioPlayerNode {
        if let existing = players[channel] {
            ensureRunning()
            return existing
        }
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: Self.format)
        players[channel] = player
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
    /// Re-establishes every player's connection to the mixer.
    ///
    /// A configuration change does not merely stop the engine, it tears the graph down: the
    /// hardware format has changed, so existing connections are invalid. Restarting without
    /// reconnecting leaves nodes that accept buffers, report themselves as playing, and render
    /// nothing -- audio queued forever, no completion handler, no error. That is the fault that
    /// survived two previous fixes; the giveaway was a watchdog reporting the *same* queued
    /// milliseconds six seconds apart.
    func reconnectPlayers() {
        for player in players.values {
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: Self.format)
        }
        RockyLog.write("audio: players reconnected")
    }

    func ensureRunning() {
        let wasRunning = engine.isRunning
        if !wasRunning {
            // The engine only stops on us when something tore the graph down, so rebuild the
            // connections before starting rather than trusting them to have survived.
            reconnectPlayers()
            engine.prepare()
            do {
                try engine.start()
                RockyLog.write("audio: engine (re)started")
            } catch {
                RockyLog.write("audio: engine failed to start: \(error.localizedDescription)")
                return
            }
        }
        for player in players.values where !wasRunning || !player.isPlaying {
            player.play()
        }
    }

    /// Arms the input side of this engine as an echo-cancelled barge-in detector.
    ///
    /// Hume is rendered through this engine rather than WebRTC, so WebRTC cannot remove Rocky's
    /// own voice from its microphone track. That track remains disabled while she talks. Apple's
    /// voice-processing audio unit can still distinguish nearby speech from audio rendered by
    /// this same engine, however, and its muted-speech callback lets us reopen WebRTC as soon as a
    /// friend begins speaking without ever forwarding Rocky's own voice to the model.
    ///
    /// Returns false rather than disturbing playback if the device cannot create the
    /// voice-processing input. The ordinary half-duplex echo gate remains the fallback.
    @discardableResult
    func installMutedSpeechActivityListener(onSpeechStarted: @escaping @MainActor () -> Void) -> Bool {
        let input = engine.inputNode
        if !input.isVoiceProcessingEnabled {
            engine.stop()
            do {
                try input.setVoiceProcessingEnabled(true)
            } catch {
                RockyLog.write("audio: local barge-in unavailable: \(error.localizedDescription)")
                return false
            }
        }

        input.isVoiceProcessingInputMuted = true
        let installed = input.setMutedSpeechActivityEventListener { event in
            // Keep the realtime audio callback tiny; all session mutation belongs on MainActor.
            guard event.rawValue == 0 else { return }
            Task { @MainActor in onSpeechStarted() }
        }
        guard installed else {
            RockyLog.write("audio: local barge-in listener was rejected")
            return false
        }
        mutedSpeechListenerInstalled = true
        ensureRunning()
        RockyLog.write("audio: local barge-in detector armed")
        return true
    }

    func removeMutedSpeechActivityListener() {
        guard mutedSpeechListenerInstalled else { return }
        _ = engine.inputNode.setMutedSpeechActivityEventListener(nil)
        mutedSpeechListenerInstalled = false
    }

    func stop() {
        engine.stop()
    }
}
