import Foundation

/// One judgment about a single camera frame: what is in view, and whether a person is among it.
///
/// Deliberately more than person-presence. It began as a pure person detector, which made a live
/// failure inevitable and invisible: a friend held a drink up to the camera and asked about it,
/// and Rocky had genuinely never been told anything except "person_present: true" -- the object
/// was never in the model's answer to begin with, so no amount of timing or debounce work could
/// have surfaced it. `scene` is the fix; `personPresent`/`bearing` remain because find-follow
/// navigation and the presence announcements are built on them.
struct SceneReading: Equatable, Sendable {
    let personPresent: Bool
    /// Horizontal position in frame, -1 (left edge) to 1 (right edge), 0 is dead centre. Nil when
    /// no person is present or the model didn't say.
    let bearing: Double?
    /// Short phrase about the nearest person, when one is present. Nil otherwise.
    let person: String?
    /// Short phrase about everything notable in the frame -- people, what they are holding or
    /// wearing, objects, drawings, text, the setting. Filled in whether or not anyone is present,
    /// because "no one is there" and "no one is there, but a drawing is being held up" are
    /// completely different facts to be given.
    let scene: String?

    static let none = SceneReading(personPresent: false, bearing: nil, person: nil, scene: nil)
}

/// One reading plus when it happened. The timestamps are what make "is this a look taken *after*
/// my friend asked me?" answerable, which is the whole basis of `look_now`: sight arrives about
/// once a second and takes a further beat to judge, so the newest reading on hand when a question
/// lands is routinely older than the question.
struct VisionSample: Equatable, Sendable {
    let seq: Int
    /// When the frame left the camera, not when the judgment came back -- the freshness that
    /// matters is the moment the light hit the lens.
    let capturedAt: Date
    let judgedAt: Date
    let reading: SceneReading

    var latency: TimeInterval { judgedAt.timeIntervalSince(capturedAt) }
    func age(at moment: Date = Date()) -> TimeInterval { moment.timeIntervalSince(capturedAt) }
}

/// Rocky's eyes: describes what the camera sees using Gemini Robotics-ER, deliberately a different
/// model and provider than the OpenAI Realtime session carrying Rocky's voice.
///
/// Separate on purpose: the voice model is one continuous session that must not be paused to
/// reason about images, and mixing a second job into it would risk exactly that. This is its own
/// session end to end.
///
/// `gemini-robotics-er-2-streaming-preview` only exists behind the Live API -- a stateful
/// WebSocket, not a one-shot REST call -- so this class holds that connection open for as long as
/// `PersonCamera` is running and feeds it one frame per `read` call, matching the documented
/// "JPEG frames at ≤1fps" input shape a persistent robotics session expects. One request is ever
/// in flight at a time (`PersonCamera` enforces that), so `turnContinuation` only ever needs to
/// hold one waiter.
@MainActor
final class PersonVision {
    private static let host = "generativelanguage.googleapis.com"
    private static let model = "models/gemini-robotics-er-2-streaming-preview"
    private static let requestTimeout: Duration = .seconds(8)

    /// Asks for the whole frame, not just a person in it. The specificity instructions are
    /// load-bearing: "a drink" is useless to a friend asking "what am I holding?", while "a can of
    /// coconut water" is the actual answer. Reading short text aloud is included for the same
    /// reason -- a child holding up a drawing with a word on it expects that word to land.
    private static let systemPrompt = """
        You are the eyes of a small robot, looking out of its front camera at whoever is in front \
        of it. Describe each image you are sent. Reply with exactly one line of JSON and nothing \
        else: {"person_present": true or false, "bearing": a number from -1 (person at the left \
        edge) to 1 (person at the right edge) or null, "person": a short phrase describing the \
        nearest person such as "man, facing camera, smiling" or null, "scene": a short phrase \
        describing everything notable in view}. Always fill in "scene", whether or not anyone is \
        visible: include what people are holding, wearing, or showing you, plus objects, screens, \
        drawings, any short text you can read, and the setting. Name things specifically -- "a can \
        of coconut water", not "a drink". Keep "scene" under 25 words. If more than one person is \
        visible, "person" and "bearing" describe the one closest to the camera. If no person is \
        visible, "person_present" is false, "bearing" and "person" are null, and "scene" still \
        describes the room and anything in it.
        """

    private var socket: URLSessionWebSocketTask?
    private var epoch = 0
    private var setupComplete = false
    private var setupContinuation: CheckedContinuation<Void, Error>?
    private var turnContinuation: CheckedContinuation<SceneReading, Error>?
    private var turnText = ""
    private var turnStartedAt: Date?
    /// Bumped every time a new setup/turn continuation is armed, so a stale watchdog from a
    /// request that already resolved can never time out a later, unrelated one sharing the same
    /// slot -- request N's watchdog checks it is still request N before acting.
    private var setupGeneration = 0
    private var turnGeneration = 0

    /// Sends one JPEG frame over the session (connecting and completing setup first if needed)
    /// and returns the parsed judgment for that frame.
    func read(frame jpegData: Data) async throws -> SceneReading {
        let socket = try await connectIfNeeded()
        turnGeneration += 1
        let generation = turnGeneration
        turnStartedAt = Date()
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
                RockyLog.write("vision: turn timed out after \(Self.requestTimeout)")
                self.failTurn(RockyError.timedOut("gemini vision turn"))
            }
        }
    }

    /// Closes the session. Safe to call whether or not one is open; the next `read` call
    /// reconnects from scratch.
    func disconnect() {
        guard socket != nil else { return }
        RockyLog.write("vision: disconnecting")
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
            RockyLog.write("vision: no Gemini API key baked into this build")
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

        let connectStart = Date()
        RockyLog.write("vision: opening a session with \(Self.model)")
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
                RockyLog.write("vision: setup timed out after \(Self.requestTimeout)")
                self.failSetup(RockyError.timedOut("gemini vision setup"))
            }
        }
        RockyLog.write("vision: session ready in \(Int(Date().timeIntervalSince(connectStart) * 1000))ms")
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
                RockyLog.write("vision: send failed: \(error.localizedDescription)")
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
                        RockyLog.write("vision: socket failed: \(error.localizedDescription)")
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
            let reading = Self.parseReading(text)
            // The model's own words, verbatim and timestamped by RockyLog. When a reading turns
            // out to be wrong or empty, this is the only line that says whether the model saw it
            // and phrased it badly or never saw it at all -- and the two have opposite fixes.
            let elapsed = turnStartedAt.map { "\(Int(Date().timeIntervalSince($0) * 1000))ms" } ?? "?"
            RockyLog.write(
                "vision: reply in \(elapsed): \(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))"
            )
            if reading == .none && !text.isEmpty {
                RockyLog.write("vision: that reply parsed to nothing at all")
            }
            turnStartedAt = nil
            let continuation = turnContinuation
            turnContinuation = nil
            continuation?.resume(returning: reading)
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
    /// still be understood; one that's unrecognisable should read as "saw nothing" rather than
    /// crash the camera loop.
    ///
    /// `scene` survives a `person_present: false` reading, unlike the person-only fields. That
    /// asymmetry is the point: an empty room with a drawing held up in it is not the same fact as
    /// an empty room.
    nonisolated static func parseReading(_ text: String) -> SceneReading {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end
        else { return .none }
        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .none }

        let present = object["person_present"] as? Bool ?? false
        // "description" is the key the earlier person-only prompt used. Still read as a fallback
        // so a model reply in the old shape degrades to the old behaviour rather than to silence.
        let person = phrase(object["person"] ?? object["description"])
        return SceneReading(
            personPresent: present,
            bearing: present ? (object["bearing"] as? Double).map({ $0.clamped(to: -1...1) }) : nil,
            person: present ? person : nil,
            scene: phrase(object["scene"])
        )
    }

    private nonisolated static func phrase(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else { return nil }
        return text
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
