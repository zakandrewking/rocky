import Foundation

/// A text-to-speech stream whose raw PCM can be played by `LocalPcmPlayer`.
/// Rocky uses Hume; user-created personalities use ElevenLabs.
@MainActor
protocol LocalSpeechSynthesizing: AnyObject {
    var providerName: String { get }
    var sampleRate: Double { get }
    var onAudio: ((_ base64: String, _ isLastChunk: Bool) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }

    func speak(_ text: String, flush: Bool)
    func cancel()
}
