import Foundation

/// Streams a user-created personality through ElevenLabs' text-to-speech WebSocket. A fresh
/// socket is used for each answer so cancellation is immediate and no text crosses turns.
@MainActor
final class ElevenLabsSpeech: LocalSpeechSynthesizing {
    let providerName = "elevenlabs"
    let sampleRate = 24_000.0

    var onAudio: ((_ base64: String, _ isLastChunk: Bool) -> Void)?
    var onError: ((String) -> Void)?

    private let apiKey: String
    private let voiceID: String
    private let stability: Double
    private let speed: Double
    private var socket: URLSessionWebSocketTask?
    private var epoch = 0
    private var pendingAudio: String?

    init?(voiceID: String, stability: Double, speed: Double) {
        let key = (Bundle.main.object(forInfoDictionaryKey: "RockyElevenLabsKey") as? String) ?? ""
        guard !key.isEmpty else { return nil }
        apiKey = key
        self.voiceID = voiceID
        self.stability = stability
        self.speed = speed
    }

    func speak(_ text: String, flush: Bool) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty || flush else { return }
        let socket = connectIfNeeded()

        if !clean.isEmpty {
            send([
                "text": clean + " ",
                "try_trigger_generation": flush,
            ], on: socket)
        }
        if flush {
            // An empty text frame signals end-of-sequence and causes ElevenLabs to flush audio.
            send(["text": ""], on: socket)
        }
    }

    func cancel() {
        epoch += 1
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        pendingAudio = nil
    }

    private func connectIfNeeded() -> URLSessionWebSocketTask {
        if let socket { return socket }

        var components = URLComponents(
            string: "wss://api.elevenlabs.io/v1/text-to-speech/\(voiceID)/stream-input"
        )!
        components.queryItems = [
            .init(name: "model_id", value: "eleven_flash_v2_5"),
            .init(name: "output_format", value: "pcm_24000"),
            .init(name: "auto_mode", value: "true"),
            .init(name: "inactivity_timeout", value: "180"),
        ]
        let socket = URLSession.shared.webSocketTask(with: components.url!)
        self.socket = socket
        let currentEpoch = epoch
        socket.resume()
        receive(on: socket, epoch: currentEpoch)
        send([
            "text": " ",
            "xi_api_key": apiKey,
            "voice_settings": [
                "stability": stability,
                "similarity_boost": 0.75,
                "style": 0,
                "use_speaker_boost": true,
                "speed": speed,
            ],
        ], on: socket)
        return socket
    }

    private func send(_ object: [String: Any], on socket: URLSessionWebSocketTask) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
            let json = String(data: data, encoding: .utf8)
        else { return }
        socket.send(.string(json)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.onError?(error.localizedDescription) }
        }
    }

    private func receive(on socket: URLSessionWebSocketTask, epoch: Int) {
        socket.receive { [weak self] result in
            Task { @MainActor in
                guard let self, epoch == self.epoch else { return }
                switch result {
                case .failure(let error):
                    if (error as NSError).code != NSURLErrorCancelled {
                        self.onError?(error.localizedDescription)
                    }
                    if self.socket === socket { self.socket = nil }
                case .success(let message):
                    if case .string(let json) = message { self.handle(json, socket: socket) }
                    if self.socket === socket { self.receive(on: socket, epoch: epoch) }
                }
            }
        }
    }

    private func handle(_ json: String, socket: URLSessionWebSocketTask) {
        guard let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if let audio = object["audio"] as? String, !audio.isEmpty {
            if let pendingAudio { onAudio?(pendingAudio, false) }
            pendingAudio = audio
        }
        if object["isFinal"] as? Bool == true {
            if let pendingAudio { onAudio?(pendingAudio, true) }
            pendingAudio = nil
            self.socket = nil
            epoch += 1
            socket.cancel(with: .normalClosure, reason: nil)
        }
        if let error = object["message"] as? String,
            object["error"] != nil || object["status"] as? String == "error"
        {
            onError?(error)
        }
    }
}
