import Foundation

/// Owns one Realtime voice conversation: mints an ephemeral secret directly from OpenAI
/// (OpenAIRealtimeMinter), opens a direct WebRTC connection (RealtimeWebRTCClient), and
/// dispatches tool calls (drive_cm, rotate_degrees, stop_robot, read_distance, set_face --
/// defined in services/device-api/src/session.ts, the single source of truth baked into the
/// bundled session config at build time) onto a connected RobotController. Replaces the fixed
/// five-word vocabulary (VoiceCommandRecognizer) entirely -- this is real conversation, not
/// string matching.
@MainActor
final class RealtimeVoiceSession: ObservableObject {
    enum State: Equatable {
        case disconnected, connecting, connected, failed(String)
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var lastToolCall: String?

    private let client = RealtimeWebRTCClient()
    private var robot: RobotController?
    private var greeted = false

    /// Rocky's own voice, when it's configured: Hume speaks, OpenAI is put in text-only mode and
    /// never makes a sound. Nil falls back to OpenAI's built-in voice over the WebRTC track.
    private let hume = HumeSpeech()
    private var humePlayer: HumePcmPlayer?
    private var humeTextBuffer = ""
    /// The quiet alien chatter under her voice.
    private var eridian: EridianAudio?

    /// `robot` is nil when none was found on the network. That is a supported, ordinary state --
    /// the app is then exactly what apps/desktop is, a voice-only Rocky -- so the movement tools
    /// are dropped from the session rather than left to fail (see OpenAIRealtimeMinter).
    func connect(robot: RobotController?) async {
        guard state == .disconnected || isFailed else { return }
        self.robot = robot
        state = .connecting

        do {
            try AudioSessionManager.configureForVoice()
            startLocalAudio()
            let secret = try await OpenAIRealtimeMinter.mintEphemeralSecret(
                hasRobot: robot != nil,
                speaksWithHume: hume != nil
            )
            RockyLog.write(
                "realtime: minted ephemeral secret (robot: \(robot == nil ? "no" : "yes"), voice: \(hume == nil ? "openai" : "hume"))"
            )

            client.onEvent = { [weak self] event in
                Task { @MainActor in
                    await self?.handle(event)
                }
            }
            client.onConnectionStateChange = { [weak self] connected in
                Task { @MainActor in
                    self?.handleConnectionChange(connected)
                }
            }
            // Rocky speaks first, the way she does on desktop: the session's turn detection only
            // fires on *user* speech, so the opening line needs an explicit nudge once the data
            // channel can actually carry it.
            client.onDataChannelOpen = { [weak self] in
                Task { @MainActor in
                    self?.greetIfNeeded()
                }
            }

            try await client.connect(ephemeralSecret: secret)
            state = .connected
            RockyLog.write("realtime: connected")
        } catch {
            state = .failed(error.localizedDescription)
            RockyLog.write("realtime: connect failed: \(error.localizedDescription)")
        }
    }

    func disconnect() {
        client.close()
        stopLocalAudio()
        hume?.cancel()
        humePlayer = nil
        eridian = nil
        humeTextBuffer = ""
        state = .disconnected
        robot = nil
        greeted = false
    }

    // MARK: - Rocky's voice and her alien chatter

    private func startLocalAudio() {
        eridian = EridianAudio()
        guard let hume else { return }
        let player = HumePcmPlayer()
        humePlayer = player
        hume.onAudio = { [weak player] base64, isLastChunk in
            player?.push(base64: base64, isLastChunk: isLastChunk)
        }
        hume.onError = { message in
            RockyLog.write("hume: \(message)")
        }
    }

    private func stopLocalAudio() {
        eridian?.stop()
        humePlayer?.stop()
    }

    /// Barge-in. The session's own turn detection already cancels the *response* server-side; what
    /// it cannot do is stop audio this app has already queued locally, so that has to happen here
    /// or Rocky keeps talking over the person interrupting her.
    private func handleUserStartedSpeaking() {
        stopLocalAudio()
        hume?.cancel()
        humeTextBuffer = ""
    }

    /// Feeds Rocky's streaming words to Hume a sensible mouthful at a time (see SpeechChunks).
    private func sendToHume(_ delta: String, flush: Bool = false) {
        guard let hume else { return }
        let split = SpeechChunks.split(buffer: humeTextBuffer, delta: delta, flush: flush)
        humeTextBuffer = split.remainder
        for chunk in split.complete {
            hume.speak(chunk, flush: flush && split.remainder.isEmpty)
        }
    }

    private func greetIfNeeded() {
        guard !greeted else { return }
        greeted = true
        client.send(ResponseCreateEvent())
        RockyLog.write("realtime: asked Rocky to greet")
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func handleConnectionChange(_ connected: Bool) {
        guard !connected, state == .connected || state == .connecting else { return }
        state = .failed("voice connection lost")
        RockyLog.write("realtime: connection lost")
    }

    private func handle(_ event: RealtimeServerEvent) async {
        switch event.type {
        case "error":
            RockyLog.write("realtime error: \(event.error?.message ?? "unknown")")

        case "input_audio_buffer.speech_started":
            handleUserStartedSpeaking()

        case "response.created":
            humePlayer?.beginResponse()
            eridian?.playThinkingPrelude()

        // Hume path: OpenAI streams words, Hume speaks them, and the chord layer follows the
        // same text.
        case "response.output_text.delta":
            if let delta = event.delta {
                eridian?.pushTranscriptDelta(delta)
                sendToHume(delta)
            }
        case "response.output_text.done":
            sendToHume("", flush: true)
            eridian?.flushTranscript()

        // OpenAI-voice path: the audio itself arrives on the media track, and only its transcript
        // comes through here -- still enough to drive the chords.
        case "response.output_audio_transcript.delta":
            if let delta = event.delta { eridian?.pushTranscriptDelta(delta) }
        case "response.output_audio_transcript.done":
            eridian?.flushTranscript()

        default:
            break
        }
        for call in event.toolCalls {
            guard let name = call.name, let callId = call.call_id else { continue }
            await performToolCall(name: name, argumentsJSON: call.arguments ?? "{}", callId: callId)
        }
    }

    private func performToolCall(name: String, argumentsJSON: String, callId: String) async {
        RockyLog.write("tool call: \(name) \(argumentsJSON)")
        lastToolCall = name
        let output: String
        do {
            output = try await execute(name: name, argumentsJSON: argumentsJSON)
        } catch {
            output = Self.encodeResult(["success": false, "error": error.localizedDescription])
        }
        client.send(FunctionCallOutputEvent(callId: callId, output: output))
        client.send(ResponseCreateEvent())
    }

    private func execute(name: String, argumentsJSON: String) async throws -> String {
        guard let robot else { throw RobotError.disconnected }
        let data = Data(argumentsJSON.utf8)

        switch name {
        case "drive_cm":
            let args = try JSONDecoder().decode(DriveArgs.self, from: data)
            try await robot.drive(distanceCm: args.distanceCm, speed: args.speed ?? RobotLimits.defaultSpeed)
            return Self.encodeResult(["success": true])

        case "rotate_degrees":
            let args = try JSONDecoder().decode(TurnArgs.self, from: data)
            try await robot.turn(degrees: args.degrees, speed: args.speed ?? RobotLimits.defaultSpeed)
            return Self.encodeResult(["success": true])

        case "stop_robot":
            try await robot.stop()
            return Self.encodeResult(["success": true])

        case "read_distance":
            let cm = try await robot.readDistanceCm()
            return Self.encodeResult(["success": true, "distanceCm": cm])

        case "set_face":
            let args = try JSONDecoder().decode(FaceArgs.self, from: data)
            guard let face = FaceState(rawValue: args.face) else {
                return Self.encodeResult(["success": false, "error": "unknown face \(args.face)"])
            }
            try await robot.setFace(face)
            return Self.encodeResult(["success": true])

        default:
            return Self.encodeResult(["success": false, "error": "unknown tool \(name)"])
        }
    }

    private struct DriveArgs: Decodable {
        let distanceCm: Double
        let speed: Double?
    }

    private struct TurnArgs: Decodable {
        let degrees: Double
        let speed: Double?
    }

    private struct FaceArgs: Decodable {
        let face: String
    }

    /// Encodes a small, flat JSON object for a function_call_output. Values are deliberately
    /// restricted to the handful of types tool results actually need -- this isn't a general
    /// JSON encoder, just enough to avoid hand-building JSON strings with string interpolation.
    private static func encodeResult(_ fields: [String: Any]) -> String {
        var parts: [String] = []
        for (key, value) in fields {
            let encodedValue: String
            switch value {
            case let bool as Bool:
                encodedValue = bool ? "true" : "false"
            case let number as Double:
                encodedValue = String(number)
            case let string as String:
                let escaped = string
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                encodedValue = "\"\(escaped)\""
            default:
                encodedValue = "null"
            }
            parts.append("\"\(key)\":\(encodedValue)")
        }
        return "{\(parts.joined(separator: ","))}"
    }
}
