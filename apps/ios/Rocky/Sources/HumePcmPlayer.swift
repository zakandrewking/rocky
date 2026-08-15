import AVFoundation

/// Plays the PCM Hume streams back, ported from apps/desktop/src/renderer/src/humePcmAudio.ts.
///
/// Desktop schedules each chunk at an absolute time on the AudioContext clock. This does not: it
/// queues buffers back to back on an AVAudioPlayerNode and lets the node play them in order,
/// which is gapless by construction.
///
/// That divergence is deliberate and was earned. Absolute sample times depend on a clock that
/// resets to zero whenever the node is stopped -- and iOS stops it for us, because WebRTC taking
/// the audio session for the microphone restarts the whole engine. Every version of "keep our own
/// cursor on that clock" produced audio scheduled into the far future: silence, with no error
/// raised, no buffer ever completing, and nothing in the API to notice it by.
@MainActor
final class HumePcmPlayer {
    /// Silence appended to the final chunk so the tail isn't clipped.
    private static let finalPaddingSeconds = 0.280

    /// Reported when audio starts and stops, so the UI can show Rocky speaking.
    var onSpeakingChange: ((Bool) -> Void)?

    private let player: AVAudioPlayerNode
    private let sampleRate: Double

    private var pendingChunks = 0
    private var queuedSeconds = 0.0
    private var isSpeaking = false

    init() {
        self.sampleRate = RockyAudioEngine.shared.sampleRate
        self.player = RockyAudioEngine.shared.player(for: .voice)
    }

    /// Call at the start of each response.
    func beginResponse() {
        chunksThisResponse = 0
    }

    func push(base64: String, isLastChunk: Bool) {
        guard let samples = Self.decodePCM16LE(base64), !samples.isEmpty else { return }
        RockyAudioEngine.shared.ensureRunning()

        let padding = isLastChunk ? Int(Self.finalPaddingSeconds * sampleRate) : 0
        let frameCount = AVAudioFrameCount(samples.count + padding)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: RockyAudioEngine.format, frameCapacity: frameCount),
            let channel = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = frameCount
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        if padding > 0 {
            channel.advanced(by: samples.count).update(repeating: 0, count: padding)
        }

        let seconds = Double(frameCount) / sampleRate
        pendingChunks += 1
        chunksThisResponse += 1
        queuedSeconds += seconds
        setSpeaking(true)
        // .dataPlayedBack fires when the audio has actually been heard, not merely consumed --
        // which is what "Rocky finished speaking" has to mean for the mic to reopen safely.
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.chunkFinished(seconds: seconds) }
        }
    }

    /// Roughly how much audio is still to be heard -- enough to tell "Rocky is mid-sentence" from
    /// "Rocky is stuck", which is all the turn watchdog needs of it.
    var millisecondsUntilPlaybackEnd: Double {
        max(0, queuedSeconds * 1000)
    }

    var speaking: Bool { isSpeaking }

    /// Total audio pushed this response, for the logs: "no audio at all" and "audio that stopped
    /// early" are different failures and look identical from the outside.
    private(set) var chunksThisResponse = 0

    /// Barge-in: drop everything queued, or the next thing Rocky says waits behind audio nobody
    /// is listening to any more.
    func stop() {
        player.stop()
        pendingChunks = 0
        chunksThisResponse = 0
        queuedSeconds = 0
        // stop() leaves the node not playing; this puts it back, engine included.
        RockyAudioEngine.shared.ensureRunning()
        setSpeaking(false)
    }

    private func chunkFinished(seconds: Double) {
        pendingChunks = max(0, pendingChunks - 1)
        queuedSeconds = max(0, queuedSeconds - seconds)
        if pendingChunks == 0 {
            queuedSeconds = 0
            setSpeaking(false)
        }
    }

    private func setSpeaking(_ speaking: Bool) {
        guard speaking != isSpeaking else { return }
        isSpeaking = speaking
        onSpeakingChange?(speaking)
    }

    /// Hume's wire format: base64 of signed 16-bit little-endian mono samples. Pure, so it is
    /// deliberately not actor-bound -- it runs wherever the socket callback landed.
    nonisolated static func decodePCM16LE(_ base64: String) -> [Float]? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        return data.withUnsafeBytes { raw -> [Float] in
            let count = raw.count / 2
            var out = [Float](repeating: 0, count: count)
            for index in 0..<count {
                let low = UInt16(raw[index * 2])
                let high = UInt16(raw[index * 2 + 1])
                out[index] = Float(Int16(bitPattern: low | (high << 8))) / 32768
            }
            return out
        }
    }
}
