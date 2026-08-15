import Foundation

/// Streams text to Hume Octave and hands back raw PCM, ported from
/// apps/desktop/src/main/humeSpeech.ts. This is Rocky's actual voice -- when it is configured,
/// OpenAI is put in text-only mode and never speaks.
///
/// One socket per conversation, opened lazily and reused. There is no cancel message in the
/// protocol: closing the socket *is* the cancel, and the next `speak` transparently reconnects.
@MainActor
final class HumeSpeech {
    /// Raw PCM from Hume: signed 16-bit little-endian, mono, always this rate. Hume does not
    /// report it, so it is fixed here exactly as the desktop client fixes it.
    static let sampleRate = 48_000.0

    var onAudio: ((_ base64: String, _ isLastChunk: Bool) -> Void)?
    var onError: ((String) -> Void)?

    private let apiKey: String
    private let voiceId: String
    private var socket: URLSessionWebSocketTask?
    /// Bumped on every cancel/close so a socket that was already in flight can't deliver audio
    /// into the conversation that replaced it. The desktop original has exactly this race.
    private var epoch = 0

    /// Present only when both credentials were baked in at build time (see scripts/generate.sh).
    /// Nil means no Hume, and the caller should leave OpenAI speaking in its own voice.
    init?() {
        let key = (Bundle.main.object(forInfoDictionaryKey: "RockyHumeKey") as? String) ?? ""
        let voice = (Bundle.main.object(forInfoDictionaryKey: "RockyHumeVoiceId") as? String) ?? ""
        guard !key.isEmpty, !voice.isEmpty else { return nil }
        apiKey = key
        voiceId = voice
    }

    func speak(_ text: String, flush: Bool) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let socket = connectIfNeeded()
        let message: [String: Any] = [
            "text": clean,
            "voice": ["id": voiceId],
            "flush": flush,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: message),
            let json = String(data: data, encoding: .utf8)
        else { return }
        socket.send(.string(json)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.onError?(error.localizedDescription) }
        }
    }

    /// Closing the socket is how Hume is told to stop talking.
    func cancel() {
        epoch += 1
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func connectIfNeeded() -> URLSessionWebSocketTask {
        if let socket { return socket }

        var components = URLComponents(string: "wss://api.hume.ai/v0/tts/stream/input")!
        components.queryItems = [
            .init(name: "api_key", value: apiKey),
            // JSON text frames carrying base64 audio, rather than binary frames.
            .init(name: "no_binary", value: "true"),
            // Low latency; requires a voice on every utterance, which speak() always sends.
            .init(name: "instant_mode", value: "true"),
            // No WAV header per chunk, so chunks concatenate straight into the playback timeline.
            .init(name: "strip_headers", value: "true"),
            .init(name: "format_type", value: "pcm"),
            .init(name: "version", value: "2"),
        ]

        let socket = URLSession.shared.webSocketTask(with: components.url!)
        self.socket = socket
        socket.resume()
        receive(on: socket, epoch: epoch)
        return socket
    }

    private func receive(on socket: URLSessionWebSocketTask, epoch: Int) {
        socket.receive { [weak self] result in
            Task { @MainActor in
                guard let self, epoch == self.epoch else { return }
                switch result {
                case .failure(let error):
                    // Cancelling is how this client stops Hume talking, so the resulting error is
                    // expected bookkeeping, not a fault worth reporting.
                    if (error as NSError).code != NSURLErrorCancelled {
                        self.onError?(error.localizedDescription)
                    }
                    if self.socket === socket { self.socket = nil }
                case .success(let message):
                    if case .string(let json) = message { self.handle(json) }
                    self.receive(on: socket, epoch: epoch)
                }
            }
        }
    }

    /// Frames are JSON lines; anything that isn't an audio frame (timestamps, metadata, or
    /// something we don't model) is ignored rather than treated as an error.
    private func handle(_ json: String) {
        guard let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["type"] as? String == "audio",
            let audio = object["audio"] as? String
        else { return }
        onAudio?(audio, object["is_last_chunk"] as? Bool ?? false)
    }
}
