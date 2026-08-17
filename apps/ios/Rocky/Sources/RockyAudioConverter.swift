// Adapted from the RTCAudioDevice example linked by WebRTC.
// Original example copyright (c) 2022 Yury Yaroshevich, MIT.

@preconcurrency import AVFoundation

/// Allocation-free format conversion for WebRTC's realtime microphone callback.
final class RockyAudioConverter: @unchecked Sendable {
    private var converter: AudioConverterRef?

    init?(from: AVAudioFormat, to: AVAudioFormat) {
        guard from.sampleRate == to.sampleRate,
            AudioConverterNew(from.streamDescription, to.streamDescription, &converter) == noErr
        else { return nil }
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
    }

    func convert(
        frameCount: AVAudioFrameCount,
        from input: UnsafePointer<AudioBufferList>,
        to output: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        guard let converter else { return kAudio_ParamError }
        return AudioConverterConvertComplexBuffer(converter, frameCount, input, output)
    }
}
