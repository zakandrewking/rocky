import AVFoundation

/// Plays raw mono PCM from a local speech provider. The shared engine runs at 48 kHz, so streams
/// such as ElevenLabs' 24 kHz output are resampled before they are scheduled.
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
final class LocalPcmPlayer {
    /// Silence appended to the final chunk so the tail isn't clipped.
    private static let finalPaddingSeconds = 0.280

    /// Reported when audio starts and stops, so the UI can show Rocky speaking.
    var onSpeakingChange: ((Bool) -> Void)?

    private let player: AVAudioPlayerNode
    private let outputSampleRate: Double
    private let sourceSampleRate: Double

    private var pendingChunks = 0
    private var queuedSeconds = 0.0
    private var isSpeaking = false

    init(sourceSampleRate: Double) {
        self.outputSampleRate = RockyAudioEngine.shared.sampleRate
        self.sourceSampleRate = sourceSampleRate
        self.player = RockyAudioEngine.shared.player(for: .voice)
    }

    /// Call at the start of each response.
    func beginResponse() {
        chunksThisResponse = 0
    }

    func push(base64: String, isLastChunk: Bool) {
        guard let decoded = Self.decodePCM16LE(base64), !decoded.isEmpty else { return }
        let samples = Self.resample(decoded, from: sourceSampleRate, to: outputSampleRate)
        RockyAudioEngine.shared.ensureRunning()

        let padding = isLastChunk ? Int(Self.finalPaddingSeconds * outputSampleRate) : 0
        let frameCount = AVAudioFrameCount(samples.count + padding)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: RockyAudioEngine.format, frameCapacity: frameCount),
            let channel = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = frameCount
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        if padding > 0 {
            channel.advanced(by: samples.count).update(repeating: 0, count: padding)
        }

        let seconds = Double(frameCount) / outputSampleRate
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
        // Do not restart the graph merely to make an empty player ready. The next push starts the
        // graph and every player before scheduling. Restarting here made each barge-in and pause
        // race WebRTC/AVAudioSession teardown even though there was no sound left to render.
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

    /// Providers use base64 of signed 16-bit little-endian mono samples. Pure, so it is
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

    nonisolated static func resample(_ input: [Float], from sourceRate: Double, to outputRate: Double) -> [Float] {
        guard !input.isEmpty, sourceRate > 0, outputRate > 0 else { return [] }
        guard sourceRate != outputRate else { return input }

        let outputCount = max(1, Int((Double(input.count) * outputRate / sourceRate).rounded()))
        return (0..<outputCount).map { outputIndex in
            let position = Double(outputIndex) * sourceRate / outputRate
            let lower = min(input.count - 1, Int(position))
            let upper = min(input.count - 1, lower + 1)
            let fraction = Float(position - Double(lower))
            return input[lower] + (input[upper] - input[lower]) * fraction
        }
    }
}
