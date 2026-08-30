import Foundation

/// The conversational transport under Rocky's existing turn, world, tool, and speech machinery.
///
/// Both implementations emit the small `RealtimeServerEvent` vocabulary consumed by
/// `RealtimeVoiceSession`. The OpenAI implementation receives those events directly. The ER2
/// prototype translates Gemini Live messages at this seam, which keeps the experiment honest:
/// only the reasoning/listening transport changes, while persona, robot tools, ElevenLabs,
/// interruption, playback, and diagnostics stay comparable.
protocol RealtimeVoiceClient: AnyObject, Sendable {
    var onEvent: (@Sendable (RealtimeServerEvent) -> Void)? { get set }
    var onConnectionStateChange: (@Sendable (Bool) -> Void)? { get set }
    var onDataChannelOpen: (@Sendable () -> Void)? { get set }

    var isDataChannelOpen: Bool { get }
    var supportsOutOfBandResponses: Bool { get }
    var supportsDynamicBodyConfiguration: Bool { get }
    var engineName: String { get }

    func connect(credential: String, hasBody: Bool) async throws
    func send<T: Encodable>(_ event: T)
    @discardableResult func send(jsonObject: [String: Any]) -> Bool
    func setMicrophoneEnabled(_ enabled: Bool)
    func setRemoteAudioEnabled(_ enabled: Bool)
    /// Lets transports distinguish nearby speech from Rocky's own locally-rendered voice.
    func setLocalPlaybackActive(_ active: Bool)
    func close()
}

extension RealtimeVoiceClient {
    func setLocalPlaybackActive(_: Bool) {}
}

enum VoiceEngine: String {
    case realtime
    case er2

    static var configured: VoiceEngine {
        let value = Bundle.main.object(forInfoDictionaryKey: "RockyVoiceEngine") as? String
        return Self(rawValue: value?.lowercased() ?? "") ?? .realtime
    }

    var displayName: String {
        switch self {
        case .realtime: "openai-realtime"
        case .er2: "gemini-er2-live"
        }
    }

    var hasCredential: Bool {
        let key: String
        switch self {
        case .realtime: key = "RockyOpenAIKey"
        case .er2: key = "RockyGeminiKey"
        }
        return !((Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? "").isEmpty
    }

    var missingCredentialMessage: String {
        switch self {
        case .realtime:
            "No OpenAI key baked in — set OPENAI_API_KEY, regenerate, and rebuild."
        case .er2:
            "No Gemini key baked in — set GEMINI_API_KEY, regenerate, and rebuild."
        }
    }

    func makeClient() -> any RealtimeVoiceClient {
        switch self {
        case .realtime: RealtimeWebRTCClient()
        case .er2: ER2LiveVoiceClient()
        }
    }
}

extension RealtimeWebRTCClient: RealtimeVoiceClient {
    var supportsOutOfBandResponses: Bool { true }
    var supportsDynamicBodyConfiguration: Bool { true }
    var engineName: String { VoiceEngine.realtime.displayName }

    func connect(credential: String, hasBody _: Bool) async throws {
        try await connect(ephemeralSecret: credential)
    }
}
