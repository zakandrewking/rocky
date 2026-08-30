import Foundation

/// Streams OpenAI's incremental response text through ElevenLabs Text to Dialogue.
///
/// `eleven_v3_conversational` is not supported by ElevenLabs' ordinary TTS WebSocket. Its TTD
/// socket registers the voice once, accepts incremental `inputs`, and reports an exact PCM turn
/// boundary. One socket is reused across responses; cancellation closes it so already-generated
/// audio cannot leak into the utterance that follows a barge-in.
@MainActor
final class ElevenLabsSpeech: LocalSpeechSynthesizing {
    static let sampleRate = 24_000.0
    static let modelId = "eleven_v3_conversational"

    let providerName = "elevenlabs/eleven_v3_conversational"
    var sampleRate: Double { Self.sampleRate }

    var onAudio: ((_ base64: String, _ isLastChunk: Bool) -> Void)?
    var onError: ((String) -> Void)?
    var onDebug: ((String) -> Void)?

    private let apiKey: String
    private let voiceId: String
    private var socket: URLSessionWebSocketTask?
    private var keepAlive: Task<Void, Never>?
    private var epoch = 0
    /// The first input on a fresh socket starts its first turn implicitly. After a final marker,
    /// the next input explicitly starts a new turn so v3 resets prosody between Rocky replies.
    private var startsNewTurn = false
    private var audioChunksThisTurn = 0

    init?() {
        let key = (Bundle.main.object(forInfoDictionaryKey: "RockyElevenLabsKey") as? String) ?? ""
        let voice = (Bundle.main.object(forInfoDictionaryKey: "RockyElevenLabsVoiceId") as? String) ?? ""
        guard !key.isEmpty, !voice.isEmpty else { return nil }
        apiKey = key
        voiceId = voice
    }

    func speak(_ text: String, flush: Bool) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty || flush else { return }
        let socket = connectIfNeeded()

        var message: [String: Any] = [:]
        if !clean.isEmpty {
            var input: [String: Any] = [
                "text": clean,
                "voice_id": voiceId,
            ]
            if startsNewTurn { input["new_turn"] = true }
            message["inputs"] = [input]
            startsNewTurn = false
        }
        if flush { message["flush"] = true }
        send(message, on: socket, epoch: epoch)
    }

    func cancel() {
        if socket != nil { onDebug?("socket closed for cancellation") }
        epoch += 1
        keepAlive?.cancel()
        keepAlive = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        startsNewTurn = false
        audioChunksThisTurn = 0
    }

    private func connectIfNeeded() -> URLSessionWebSocketTask {
        if let socket { return socket }

        var components = URLComponents(string: "wss://api.elevenlabs.io/v1/text-to-dialogue/stream-input")!
        components.queryItems = [
            .init(name: "model_id", value: Self.modelId),
            // Raw S16LE has exact turn boundaries and feeds LocalPcmPlayer without a codec.
            .init(name: "output_format", value: "pcm_24000"),
        ]
        let socket = URLSession.shared.webSocketTask(with: components.url!)
        self.socket = socket
        socket.resume()
        onDebug?("opening TTD socket (24 kHz PCM)")

        // Credentials in the required registration frame avoid placing the key in a URL or log.
        send(["voices": [voiceId], "xi_api_key": apiKey], on: socket, epoch: epoch)
        receive(on: socket, epoch: epoch)
        armKeepAlive(on: socket, epoch: epoch)
        return socket
    }

    private func send(_ object: [String: Any], on socket: URLSessionWebSocketTask, epoch: Int) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
            let json = String(data: data, encoding: .utf8)
        else {
            onError?("could not encode dialogue message")
            return
        }
        socket.send(.string(json)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                guard let self, epoch == self.epoch else { return }
                self.onError?("send failed: \(error.localizedDescription)")
            }
        }
    }

    private func receive(on socket: URLSessionWebSocketTask, epoch: Int) {
        socket.receive { [weak self] result in
            Task { @MainActor in
                guard let self, epoch == self.epoch else { return }
                switch result {
                case .failure(let error):
                    if (error as NSError).code != NSURLErrorCancelled {
                        self.onError?("socket failed: \(error.localizedDescription)")
                    }
                    if self.socket === socket {
                        self.socket = nil
                        self.keepAlive?.cancel()
                        self.keepAlive = nil
                    }
                case .success(let message):
                    switch message {
                    case .string(let json): self.handle(json)
                    case .data(let data):
                        self.onError?("unexpected binary frame (\(data.count) bytes)")
                    @unknown default: self.onError?("unexpected WebSocket frame")
                    }
                    self.receive(on: socket, epoch: epoch)
                }
            }
        }
    }

    enum ServerFrame: Equatable {
        case audio(String)
        case turnComplete
        case socketFinal
        case error(String)
        case metadata([String])
    }

    nonisolated static func parseServerFrame(_ json: String) -> ServerFrame? {
        guard let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let audio = object["audio"] as? String {
            return .audio(audio)
        }
        if object["is_final_audio_for_turn"] as? Bool == true {
            return .turnComplete
        }
        if let error = object["error"] as? String ?? object["message"] as? String ?? object["detail"] as? String {
            return .error(error)
        }
        if object["is_final"] as? Bool == true {
            return .socketFinal
        }
        return .metadata(object.keys.sorted())
    }

    private func handle(_ json: String) {
        guard let frame = Self.parseServerFrame(json) else {
            onError?("received invalid JSON")
            return
        }
        switch frame {
        case .audio(let audio):
            audioChunksThisTurn += 1
            onAudio?(audio, false)
        case .turnComplete:
            onDebug?("turn complete after \(audioChunksThisTurn) audio chunks")
            // A zero-length final PCM marker lets the player append tail padding and finish only
            // after every preceding buffer has actually played.
            onAudio?("", true)
            startsNewTurn = true
            audioChunksThisTurn = 0
        case .error(let error):
            onError?("server: \(error)")
        case .socketFinal:
            onDebug?("socket acknowledged close")
        case .metadata(let keys):
            onDebug?("ignored server metadata: \(keys.joined(separator: ","))")
        }
    }

    private func armKeepAlive(on socket: URLSessionWebSocketTask, epoch: Int) {
        keepAlive?.cancel()
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self, epoch == self.epoch, self.socket === socket else { return }
                self.send(["keep_alive": true], on: socket, epoch: epoch)
            }
        }
    }
}
