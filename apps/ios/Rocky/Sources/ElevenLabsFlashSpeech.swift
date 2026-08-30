import Foundation

/// Rocky1 through ElevenLabs' low-latency HTTP audio stream.
///
/// OpenAI's complete text is already available before this request starts: Rocky intentionally
/// withholds it until `response.done` proves it is speech rather than a tool preamble. ElevenLabs
/// recommends HTTP streaming in exactly that case, and unlike its WebSocket pools this endpoint
/// is available on the current account. Raw PCM bytes are forwarded as each URLSession data chunk
/// arrives; the whole file is never buffered before playback.
@MainActor
final class ElevenLabsFlashSpeech: LocalSpeechSynthesizing {
    static let sampleRate = 24_000.0
    static let modelId = "eleven_flash_v2_5"

    let providerName = "elevenlabs/eleven_flash_v2_5"
    var sampleRate: Double { Self.sampleRate }

    var onAudio: ((_ base64: String, _ isLastChunk: Bool) -> Void)?
    var onError: ((String) -> Void)?
    var onDebug: ((String) -> Void)?

    private let apiKey: String
    private let voiceId: String
    private var pendingText = ""
    private var epoch = 0
    private var streamDelegate: StreamDelegate?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var responseOK = false
    private var errorBody = Data()
    private var audioChunksThisTurn = 0
    private var requestStartedAt: Date?

    init?() {
        let key = (Bundle.main.object(forInfoDictionaryKey: "RockyElevenLabsKey") as? String) ?? ""
        let voice = (Bundle.main.object(forInfoDictionaryKey: "RockyElevenLabsVoiceId") as? String) ?? ""
        guard !key.isEmpty, !voice.isEmpty else { return nil }
        apiKey = key
        voiceId = voice
    }

    func speak(_ text: String, flush: Bool) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty {
            if !pendingText.isEmpty { pendingText += " " }
            pendingText += clean
        }
        guard flush, !pendingText.isEmpty else { return }
        let utterance = pendingText
        pendingText = ""
        startStream(text: utterance)
    }

    func cancel() {
        if task != nil { onDebug?("HTTP stream cancelled") }
        epoch += 1
        pendingText = ""
        task?.cancel()
        session?.invalidateAndCancel()
        clearRequest()
    }

    private func startStream(text: String) {
        // A previous request should have reached its final marker before another response begins.
        // Cancel defensively so a late provider tail can never enter the next utterance.
        if task != nil { cancel() }

        let escapedVoice = voiceId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? voiceId
        var components = URLComponents(
            string: "https://api.elevenlabs.io/v1/text-to-speech/\(escapedVoice)/stream"
        )!
        components.queryItems = [
            .init(name: "output_format", value: "pcm_24000"),
            .init(name: "optimize_streaming_latency", value: "3"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "text": text,
            "model_id": Self.modelId,
        ])

        let requestEpoch = epoch
        let delegate = StreamDelegate(owner: self, epoch: requestEpoch)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        streamDelegate = delegate
        self.session = session
        self.task = task
        responseOK = false
        errorBody = Data()
        audioChunksThisTurn = 0
        requestStartedAt = Date()
        onDebug?("opening HTTP PCM stream for \(text.count) chars")
        task.resume()
    }

    private func received(response: URLResponse, epoch requestEpoch: Int) -> Bool {
        guard requestEpoch == epoch else { return false }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        responseOK = (200..<300).contains(status)
        if !responseOK { onDebug?("HTTP stream rejected with status \(status)") }
        return true
    }

    private func received(data: Data, epoch requestEpoch: Int) {
        guard requestEpoch == epoch else { return }
        if responseOK {
            audioChunksThisTurn += 1
            onAudio?(data.base64EncodedString(), false)
        } else if errorBody.count < 16_384 {
            errorBody.append(data)
        }
    }

    private func completed(error: Error?, epoch requestEpoch: Int) {
        guard requestEpoch == epoch else { return }
        if let error, (error as NSError).code != NSURLErrorCancelled {
            onError?("HTTP stream failed: \(error.localizedDescription)")
            clearRequest()
            return
        }
        guard responseOK else {
            onError?("server: \(Self.errorMessage(from: errorBody))")
            clearRequest()
            return
        }
        let elapsed = requestStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
        onDebug?("turn complete after \(audioChunksThisTurn) audio chunks in \(elapsed)ms")
        // Exact playback completion remains owned by LocalPcmPlayer, including its tail padding.
        onAudio?("", true)
        clearRequest()
    }

    private func clearRequest() {
        task = nil
        session?.finishTasksAndInvalidate()
        session = nil
        streamDelegate = nil
        responseOK = false
        errorBody = Data()
        requestStartedAt = nil
    }

    nonisolated static func errorMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8) ?? "unknown provider error"
        }
        if let detail = object["detail"] as? [String: Any] {
            return detail["message"] as? String ?? detail["status"] as? String ?? "unknown provider error"
        }
        return object["message"] as? String ?? object["error"] as? String ?? "unknown provider error"
    }

    /// URLSession delivers response/data/completion in order on its delegate queue. Each callback
    /// crosses to MainActor before touching voice state; `epoch` makes late cancellation callbacks
    /// harmless.
    private final class StreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private weak var owner: ElevenLabsFlashSpeech?
        private let epoch: Int

        init(owner: ElevenLabsFlashSpeech, epoch: Int) {
            self.owner = owner
            self.epoch = epoch
        }

        nonisolated func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
        ) {
            Task { @MainActor [weak owner, epoch] in
                let accepted = owner?.received(response: response, epoch: epoch) ?? false
                completionHandler(accepted ? .allow : .cancel)
            }
        }

        nonisolated func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive data: Data
        ) {
            Task { @MainActor [weak owner, epoch] in
                owner?.received(data: data, epoch: epoch)
            }
        }

        nonisolated func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            Task { @MainActor [weak owner, epoch] in
                owner?.completed(error: error, epoch: epoch)
            }
        }
    }
}
