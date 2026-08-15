import AVFoundation

/// Plays the PCM Hume streams back, ported from apps/desktop/src/renderer/src/humePcmAudio.ts.
///
/// Chunks are scheduled on an absolute timeline rather than queued: each starts at
/// `max(now + lead, nextStart)` so consecutive chunks butt up against each other gaplessly even
/// though they arrive at whatever pace the network allows.
@MainActor
final class HumePcmPlayer {
    /// How far ahead of "now" a chunk is scheduled, so scheduling never races the render thread.
    private static let scheduleLead = 0.012
    /// Silence appended to the final chunk so the tail isn't clipped.
    private static let finalPaddingSeconds = 0.280

    /// Reported when audio starts and stops, so the UI can show Rocky speaking.
    var onSpeakingChange: ((Bool) -> Void)?

    private let player: AVAudioPlayerNode
    private let sampleRate: Double
    private let initialDelay: Double

    private var nextStartFrame: AVAudioFramePosition = 0
    private var delayNextChunk = false
    private var pendingChunks = 0
    private var isSpeaking = false

    /// `initialDelaySeconds` holds the first chunk of each response back a little, which lets the
    /// Eridian chord layer lead the voice (desktop's ROCKY_HUME_EXTRA_DELAY_MS, default 0).
    init(initialDelaySeconds: Double = 0) {
        self.initialDelay = min(1, max(0, initialDelaySeconds))
        self.sampleRate = RockyAudioEngine.shared.sampleRate
        self.player = RockyAudioEngine.shared.makePlayer(volume: 1)
    }

    /// Call at the start of each response so the extra first-chunk delay applies again.
    func beginResponse() {
        delayNextChunk = initialDelay > 0
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

        let extraDelay = delayNextChunk ? initialDelay : 0
        delayNextChunk = false
        let now = currentFrame()
        let start = max(now + AVAudioFramePosition((Self.scheduleLead + extraDelay) * sampleRate), nextStartFrame)
        nextStartFrame = start + AVAudioFramePosition(frameCount)

        pendingChunks += 1
        chunksThisResponse += 1
        setSpeaking(true)
        player.scheduleBuffer(buffer, at: AVAudioTime(sampleTime: start, atRate: sampleRate)) { [weak self] in
            Task { @MainActor in self?.chunkFinished() }
        }
    }

    /// Milliseconds of audio still queued ahead of now -- used to tell "Rocky is mid-sentence"
    /// apart from "Rocky is stuck".
    var millisecondsUntilPlaybackEnd: Double {
        max(0, Double(nextStartFrame - currentFrame()) / sampleRate * 1000)
    }

    var speaking: Bool { isSpeaking }

    /// Total audio pushed this response, for the logs: "no audio at all" and "audio that stopped
    /// early" are different failures and look identical from the outside.
    private(set) var chunksThisResponse = 0

    /// Barge-in: drop everything queued and reset the timeline, or the next thing Rocky says
    /// would wait behind audio nobody is listening to any more.
    func stop() {
        player.stop()
        pendingChunks = 0
        chunksThisResponse = 0
        delayNextChunk = false
        RockyAudioEngine.shared.ensureRunning()
        // AVAudioPlayerNode.stop() resets the node's own sample clock to zero, so a cursor taken
        // from the old timeline is meaningless afterwards. Carrying it over scheduled the next
        // audio tens of seconds into the future -- which is silence, not a delay, and looked
        // exactly like Rocky ignoring you.
        nextStartFrame = 0
        setSpeaking(false)
    }

    private func chunkFinished() {
        pendingChunks = max(0, pendingChunks - 1)
        if pendingChunks == 0 { setSpeaking(false) }
    }

    private func setSpeaking(_ speaking: Bool) {
        guard speaking != isSpeaking else { return }
        isSpeaking = speaking
        onSpeakingChange?(speaking)
    }

    /// Zero, not `nextStartFrame`, when the node isn't rendering yet: a node that has just been
    /// started is at the beginning of its clock, and answering with a stale cursor is what pushed
    /// audio into the far future after a stop.
    private func currentFrame() -> AVAudioFramePosition {
        guard let nodeTime = player.lastRenderTime,
            let playerTime = player.playerTime(forNodeTime: nodeTime)
        else { return 0 }
        return playerTime.sampleTime
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
