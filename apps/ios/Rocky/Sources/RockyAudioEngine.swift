@preconcurrency import AVFoundation

/// Main-actor facade for the single audio graph shared by WebRTC and everything Rocky renders.
///
/// The underlying device is injected into WebRTC, so its voice-processing I/O unit owns both the
/// microphone and the speaker. Local speech, chords, and story effects enter that same output mixer and
/// therefore become part of the acoustic-echo-cancellation reference. This is what permits a
/// continuously open microphone without Rocky transcribing or interrupting herself.
@MainActor
final class RockyAudioEngine {
    static let shared = RockyAudioEngine()
    nonisolated static let audioDevice = RockyRTCAudioDevice()

    nonisolated static let format = AVAudioFormat(
        standardFormatWithSampleRate: 48_000, channels: 1
    )!
    var sampleRate: Double { Self.format.sampleRate }

    enum Channel: CaseIterable {
        case voice, chords, effects
    }

    private init() {}

    func player(for channel: Channel) -> AVAudioPlayerNode {
        Self.audioDevice.player(for: channel)
    }

    func ensureRunning() {
        Self.audioDevice.ensureRunning()
    }
}
