import Foundation

/// One judgment about a single camera frame: is a person in it, and roughly where.
struct PersonDetection: Equatable, Sendable {
    let personPresent: Bool
    /// Horizontal position in frame, -1 (left edge) to 1 (right edge), 0 is dead centre. Nil when
    /// no person is present or the model didn't say.
    let bearing: Double?
    /// One short phrase the model used to describe what it saw, for the debug panel only.
    let description: String?

    static let none = PersonDetection(personPresent: false, bearing: nil, description: nil)
}

/// Finds a person in a camera frame using Gemini Robotics-ER, deliberately a different model and
/// provider than the OpenAI Realtime session carrying Rocky's voice.
///
/// Separate on purpose: the voice model is one continuous session that must not be paused to
/// reason about images, and mixing a second job into it would risk exactly that. This is its own
/// session end to end.
///
/// `gemini-robotics-er-2-streaming-preview` only exists behind the Live API -- a stateful
/// WebSocket, not a one-shot REST call -- so this class holds that connection open for as long as
/// `PersonCamera` is running and feeds it one frame per `detectPerson` call, matching the
/// documented "JPEG frames at ≤1fps" input shape a persistent robotics session expects. One
/// request is ever in flight at a time (`PersonCamera` enforces that), so `turnContinuation` only
/// ever needs to hold one waiter.
@MainActor
final class PersonVision {
    private static let host = "generativelanguage.googleapis.com"
    private static let model = "models/gemini-robotics-er-2-streaming-preview"
    private static let requestTimeout: Duration = .seconds(8)

    private static let systemPrompt = """
        You are a vision sensor for a small robot's camera. Look at each image you're sent and \
        report whether a person is visible. Reply with exactly one line of JSON and nothing else: \
        {"person_present": true or false, "bearing": a number from -1 (person at the left edge) \
        to 1 (person at the right edge) or null, "description": a short phrase like "person, \
        facing camera" or null}. If more than one person is visible, report the one closest to \
        the camera. If no person is visible, person_present is false and bearing is null.
        """

    private var socket: URLSessionWebSocketTask?
    private var epoch = 0
    private var setupComplete = false
    private var setupContinuation: CheckedContinuation<Void, Error>?
    private var turnContinuation: CheckedContinuation<PersonDetection, Error>?
    private var turnText = ""
    /// Bumped every time a new setup/turn continuation is armed, so a stale watchdog from a
    /// request that already resolved can never time out a later, unrelated one sharing the same
    /// slot -- request N's watchdog checks it is still request N before acting.
    private var setupGeneration = 0
    private var turnGeneration = 0

    /// Sends one JPEG frame over the session (connecting and completing setup first if needed)
    /// and returns the parsed judgment for that frame.
    func detectPerson(in jpegData: Data) async throws -> PersonDetection {
        let socket = try await connectIfNeeded()
        turnGeneration += 1
        let generation = turnGeneration
        return try await withCheckedThrowingContinuation { continuation in
            turnContinuation = continuation
            send(
                [
                    "clientContent": [
                        "turns": [[
                            "role": "user",
                            "parts": [
                                ["inlineData": ["mimeType": "image/jpeg", "data": jpegData.base64EncodedString()]],
                                ["text": "What do you see?"],
                            ],
                        ]],
                        "turnComplete": true,
                    ]
                ],
                on: socket
            )
            armWatchdog { [weak self] in
                guard let self, generation == self.turnGeneration else { return }
                self.failTurn(RockyError.timedOut("gemini vision turn"))
            }
        }
    }

    /// Closes the session. Safe to call whether or not one is open; the next `detectPerson` call
    /// reconnects from scratch.
    func disconnect() {
        epoch += 1
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        setupComplete = false
        failSetup(RockyError.disconnected)
        failTurn(RockyError.disconnected)
    }

    private func connectIfNeeded() async throws -> URLSessionWebSocketTask {
        if let socket, setupComplete { return socket }

        guard let apiKey = Bundle.main.object(forInfoDictionaryKey: "RockyGeminiKey") as? String,
            !apiKey.isEmpty
        else {
            throw RockyError.commandFailed(
                "no Gemini API key baked into this build -- run apps/ios/scripts/generate.sh with GEMINI_API_KEY set in the repo root .env, then rebuild"
            )
        }

        epoch += 1
        let currentEpoch = epoch
        var components = URLComponents(
            string: "wss://\(Self.host)/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        )!
        components.queryItems = [.init(name: "key", value: apiKey)]
        let socket = URLSession.shared.webSocketTask(with: components.url!)
        self.socket = socket
        socket.resume()
        receive(on: socket, epoch: currentEpoch)

        setupGeneration += 1
        let generation = setupGeneration
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            setupContinuation = continuation
            send(
                [
                    "setup": [
                        "model": Self.model,
                        "generationConfig": ["responseModalities": ["TEXT"]],
                        "systemInstruction": ["parts": [["text": Self.systemPrompt]]],
                    ]
                ],
                on: socket
            )
            armWatchdog { [weak self] in
                guard let self, generation == self.setupGeneration else { return }
                self.failSetup(RockyError.timedOut("gemini vision setup"))
            }
        }
        return socket
    }

    private func armWatchdog(_ onTimeout: @escaping () -> Void) {
        Task {
            try? await Task.sleep(for: Self.requestTimeout)
            onTimeout()
        }
    }

    private func send(_ object: [String: Any], on socket: URLSessionWebSocketTask) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
            let json = String(data: data, encoding: .utf8)
        else { return }
        socket.send(.string(json)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.failSetup(RockyError.commandFailed(error.localizedDescription))
                self?.failTurn(RockyError.commandFailed(error.localizedDescription))
            }
        }
    }

    private func receive(on socket: URLSessionWebSocketTask, epoch: Int) {
        socket.receive { [weak self] result in
            Task { @MainActor in
                guard let self, epoch == self.epoch else { return }
                switch result {
                case .failure(let error):
                    let isCancel = (error as NSError).code == NSURLErrorCancelled
                    if self.socket === socket {
                        self.socket = nil
                        self.setupComplete = false
                    }
                    if !isCancel {
                        self.failSetup(RockyError.commandFailed(error.localizedDescription))
                        self.failTurn(RockyError.commandFailed(error.localizedDescription))
                    }
                case .success(let message):
                    switch message {
                    case .string(let json): self.handle(json)
                    case .data(let data):
                        if let json = String(data: data, encoding: .utf8) { self.handle(json) }
                    @unknown default: break
                    }
                    if self.socket === socket { self.receive(on: socket, epoch: epoch) }
                }
            }
        }
    }

    /// Frames are JSON lines conforming to `BidiGenerateContentServerMessage`: a `setupComplete`
    /// acknowledgement once, then a `serverContent` per turn with streamed text parts, closed by
    /// `turnComplete`.
    private func handle(_ json: String) {
        guard let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if object["setupComplete"] != nil {
            setupComplete = true
            let continuation = setupContinuation
            setupContinuation = nil
            continuation?.resume()
            return
        }

        guard let serverContent = object["serverContent"] as? [String: Any] else { return }
        // Confirmed against the real API (2026-08-21): with responseModalities: ["TEXT"], the
        // model's reply arrives as `outputTranscription.text`, not `modelTurn.parts[].text` --
        // the latter is what the reference docs describe, but isn't what the server actually
        // sends for this config. Both are read so a future/alternate config isn't silently dropped.
        if let modelTurn = serverContent["modelTurn"] as? [String: Any],
            let parts = modelTurn["parts"] as? [[String: Any]]
        {
            for part in parts {
                if let text = part["text"] as? String { turnText += text }
            }
        }
        if let text = (serverContent["outputTranscription"] as? [String: Any])?["text"] as? String {
            turnText += text
        }
        if serverContent["turnComplete"] as? Bool == true {
            let text = turnText
            turnText = ""
            let continuation = turnContinuation
            turnContinuation = nil
            continuation?.resume(returning: Self.parseDetection(text))
        }
    }

    private func failSetup(_ error: Error) {
        let continuation = setupContinuation
        setupContinuation = nil
        continuation?.resume(throwing: error)
    }

    private func failTurn(_ error: Error) {
        let continuation = turnContinuation
        turnContinuation = nil
        continuation?.resume(throwing: error)
    }

    /// Tolerant on purpose: a reply that wraps its JSON in a sentence, or omits a field, should
    /// still be understood; one that's unrecognisable should read as "no person" rather than
    /// crash the camera loop.
    nonisolated static func parseDetection(_ text: String) -> PersonDetection {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end
        else { return .none }
        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .none }

        let present = object["person_present"] as? Bool ?? false
        guard present else { return .none }
        let bearing = (object["bearing"] as? Double).map { $0.clamped(to: -1...1) }
        let description = (object["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PersonDetection(
            personPresent: true,
            bearing: bearing,
            description: (description?.isEmpty == false) ? description : nil
        )
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
