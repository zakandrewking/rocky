import AVFoundation

/// Plays Rocky's Eridian chord layer -- the quiet alien chatter under her voice. Ported from
/// apps/desktop/src/renderer/src/eridianAudio.ts; EridianVoice decides *what* to play, this
/// decides when and renders it.
///
/// Chords are short (≤ 0.22 s) and fully determined by their frequencies, so each is rendered to
/// a PCM buffer and scheduled at an absolute sample time. That buys sample-accurate timing for
/// free, which a callback-driven oscillator would have to work for.
///
/// It runs ahead of the speech it decorates rather than tracking it -- roughly 7.8 words/sec
/// against speech's ~2.5 -- so it chatters and then falls quiet while the voice catches up. That
/// is how it sounds on desktop and is deliberate.
@MainActor
final class EridianAudio {
    /// Defaults from apps/desktop/src/main/index.ts's config, including their clamps.
    static let defaultVolume = 0.045
    static let defaultTimeScale = 0.68

    private let volume: Double
    private let timeScale: Double
    private let player: AVAudioPlayerNode
    private let sampleRate: Double

    /// How much chatter is queued but not yet heard, so a long reply can't build a backlog.
    private var queuedSeconds = 0.0
    private var transcriptBuffer = ""

    init(volume: Double = defaultVolume, timeScale: Double = defaultTimeScale) {
        self.volume = min(0.18, max(0, volume))
        self.timeScale = min(1, max(0.45, timeScale))
        self.sampleRate = RockyAudioEngine.shared.sampleRate
        // Node volume stays at unity: the level lives in each chord's envelope peak, exactly as
        // it does in the Web Audio original.
        self.player = RockyAudioEngine.shared.player(for: .chords)
    }

    // MARK: - Text in

    func pushTranscriptDelta(_ delta: String) {
        let split = EridianVoice.splitStreamingTokens(buffer: transcriptBuffer, delta: delta)
        transcriptBuffer = split.remainder
        schedule(split.complete)
    }

    func flushTranscript() {
        let split = EridianVoice.splitStreamingTokens(buffer: transcriptBuffer, delta: "", flush: true)
        transcriptBuffer = ""
        schedule(split.complete)
    }

    /// The "Rocky is thinking" earcon, played when a response starts.
    func playThinkingPrelude() {
        schedule(["rocky", "thinking", "friend"])
    }

    /// Hard cut, matching desktop: everything sounding or scheduled stops, the partial word is
    /// dropped, and the cursor resets to now.
    func stop() {
        player.stop()
        transcriptBuffer = ""
        queuedSeconds = 0
        // The next scheduled chord restarts the shared graph and player. An empty stopped player
        // must not force an audio-unit restart during barge-in or pause.
    }

    // MARK: - Scheduling

    /// Chords are queued back to back rather than pinned to absolute sample times, so the gap
    /// after each one is rendered into its own buffer as silence. Same result, without depending
    /// on a node clock that resets whenever WebRTC restarts the engine underneath us -- see
    /// HumePcmPlayer for what that cost.
    private func schedule(_ tokens: [String]) {
        guard !tokens.isEmpty, volume > 0 else { return }
        RockyAudioEngine.shared.ensureRunning()

        let gap = 0.018 * timeScale
        for token in tokens {
            for chord in EridianVoice.chords(for: token) {
                // Nothing is queued past this horizon. Overflow chords are dropped rather than
                // deferred, which is what keeps a long reply from becoming a runaway drone.
                guard queuedSeconds < EridianVoice.maxUtteranceSeconds else { return }
                let duration = max(0.045, chord.durationSeconds * timeScale)
                let total = duration + gap
                guard let buffer = render(chord, duration: duration, totalDuration: total) else { continue }
                queuedSeconds += total
                player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        self.queuedSeconds = max(0, self.queuedSeconds - total)
                    }
                }
            }
        }
    }

    /// One chord: its voices summed (not averaged -- each oscillator is full-scale and the
    /// envelope scales the sum, as in Web Audio) under a two-stage exponential attack/decay.
    /// `duration` is the sounding part; `totalDuration` adds the silent gap that follows it.
    private func render(_ chord: EridianChord, duration: Double, totalDuration: Double) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(totalDuration * sampleRate)
        let toneFrames = Int(duration * sampleRate)
        guard frameCount > 0, toneFrames > 0,
            let buffer = AVAudioPCMBuffer(pcmFormat: RockyAudioEngine.format, frameCapacity: frameCount),
            let samples = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = frameCount
        samples.update(repeating: 0, count: Int(frameCount))

        let peak = min(0.18, max(0, volume * (chord.emphasis ? 1.35 : 1)))
        guard peak > 0 else { return nil }
        let attack = min(0.018, duration * 0.3)
        let decayDuration = duration - attack
        let floorLevel = 0.0001

        // Detune in cents by voice index: -2.5, 0, +2.5. The slow beat between the outer voices
        // is the shimmer that makes this sound alien rather than like a plain organ chord.
        let voices = chord.frequencies.enumerated().map { index, frequency in
            frequency * pow(2, (Double(index) - 1) * 2.5 / 1200)
        }

        for frame in 0..<toneFrames {
            let t = Double(frame) / sampleRate
            let envelope: Double
            if t < attack, attack > 0 {
                envelope = floorLevel * pow(max(0.0002, peak) / floorLevel, t / attack)
            } else if decayDuration > 0 {
                envelope = peak * pow(floorLevel / peak, (t - attack) / decayDuration)
            } else {
                envelope = peak
            }
            var value = 0.0
            for frequency in voices {
                value += sin(2 * .pi * frequency * t)
            }
            samples[frame] = Float(value * envelope)
        }
        return buffer
    }
}
