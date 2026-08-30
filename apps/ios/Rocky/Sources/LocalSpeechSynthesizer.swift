import Foundation

/// A text-to-speech stream whose raw PCM can be played by `LocalPcmPlayer`.
@MainActor
protocol LocalSpeechSynthesizing: AnyObject {
    var providerName: String { get }
    var sampleRate: Double { get }
    var onAudio: ((_ base64: String, _ isLastChunk: Bool) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    var onDebug: ((String) -> Void)? { get set }

    func speak(_ text: String, flush: Bool)
    func cancel()
}

enum LocalSpeechProvider: String {
    case elevenlabs
    case hume

    /// Unknown or absent values choose the current default, but generation always writes an
    /// explicit value. Keeping parsing here makes the release switch a single .env setting.
    static func configured(_ value: String?) -> Self {
        Self(rawValue: value?.lowercased() ?? "") ?? .elevenlabs
    }
}

enum ElevenLabsSpeechModel: String {
    case conversationalV3 = "eleven_v3_conversational"
    case flashV25 = "eleven_flash_v2_5"

    static func configured(_ value: String?) -> Self {
        Self(rawValue: value ?? "") ?? .conversationalV3
    }
}

@MainActor
enum LocalSpeechFactory {
    static var configuredProvider: LocalSpeechProvider {
        LocalSpeechProvider.configured(Bundle.main.object(forInfoDictionaryKey: "RockySpeechProvider") as? String)
    }

    static var configuredElevenLabsModel: ElevenLabsSpeechModel {
        ElevenLabsSpeechModel.configured(
            Bundle.main.object(forInfoDictionaryKey: "RockyElevenLabsModel") as? String
        )
    }

    static func make() -> (any LocalSpeechSynthesizing)? {
        switch configuredProvider {
        case .elevenlabs:
            switch configuredElevenLabsModel {
            case .conversationalV3: ElevenLabsSpeech()
            case .flashV25: ElevenLabsFlashSpeech()
            }
        case .hume: HumeSpeech()
        }
    }

    static var missingConfigurationMessage: String {
        switch configuredProvider {
        case .elevenlabs:
            "ElevenLabs credentials are missing from this build; set ELEVENLABS_API_KEY and ELEVENLABS_VOICE_ID, then regenerate and reinstall"
        case .hume:
            "Hume credentials are missing from this build; set HUME_API_KEY and HUME_VOICE_ID, then regenerate and reinstall"
        }
    }
}
