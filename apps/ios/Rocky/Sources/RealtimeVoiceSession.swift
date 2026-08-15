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
        case disconnected, connecting, connected, paused, failed(String)
    }

    /// Said once, on waking, and never again -- so Rocky knows she stepped away without that
    /// becoming a standing part of her character.
    private static let wakePrompt = """
        You have just come back after being paused for a moment. Say one short line that shows you
        are back and listening. Do not introduce yourself, do not greet your friend as if meeting
        them, and do not repeat anything from your first greeting. Pick up where you left off.
        """

    /// A paused session is held open, but not forever: the connection would go stale on its own
    /// eventually, and holding a Realtime session all day to save a resume nobody asked for is
    /// not a trade worth making.
    private static let maxPauseBeforeTeardown: Duration = .seconds(600)

    @Published private(set) var state: State = .disconnected
    @Published private(set) var lastToolCall: String?
    /// True while Rocky's voice is actually coming out of the speaker.
    @Published private(set) var speaking = false
    /// False until her first word of the session has been *heard*. The UI keeps the loading
    /// animation up until then, so "loading" ends when Rocky starts talking rather than when a
    /// socket happens to be ready.
    @Published private(set) var hasSpokenOnce = false

    private let client = RealtimeWebRTCClient()
    private var robot: RobotController?
    private var greeted = false

    /// The synthesiser, present only when the active character actually wants one. Characters
    /// voiced by the Realtime model itself speak over the WebRTC track and never touch this --
    /// one network hop instead of two, which is most of why it sounds quicker.
    private let hume: HumeSpeech? = OpenAIRealtimeMinter.characterSpeaksThroughHume ? HumeSpeech() : nil
    private var humePlayer: HumePcmPlayer?
    private var humeTextBuffer = ""
    /// The quiet alien chatter under her voice.
    private var eridian: EridianAudio?

    // MARK: - Turn timing and recovery
    //
    // Every leg of a turn is timed and logged, because "it was slow" and "it never answered" are
    // different faults with different fixes and are indistinguishable from the outside: the log
    // has to say which leg was slow (user stopped → response started → first word → first audio).

    private var micOpen = true
    private var userStoppedSpeakingAt: Date?
    private var responseStartedAt: Date?
    private var firstTextAt: Date?
    private var firstAudioAt: Date?
    private var responseText = ""
    private var firstAudioWatchdog: Task<Void, Never>?
    private var turnWatchdog: Task<Void, Never>?
    private var retriedThisResponse = false
    private var humeSawLastChunk = false
    private var pauseTimeout: Task<Void, Never>?

    /// How long to wait for Hume's first audio before assuming the request was lost.
    private static let firstAudioTimeout: Duration = .milliseconds(2500)

    /// When the user tapped the orb, so the whole startup sequence can be timed end to end --
    /// "slow to respond" needs the clock to start at the tap, not at the first network call.
    private var startedAt: Date?

    /// Marks the tap itself, before any awaiting, so the log covers the gap the user actually
    /// feels between touching the stone and hearing anything.
    func markStarting() {
        startedAt = Date()
        hasSpokenOnce = false
        log("orb tapped, starting up")
    }

    /// `robot` is nil when none was found on the network. That is a supported, ordinary state --
    /// the app is then exactly what apps/desktop is, a voice-only Rocky -- so the movement tools
    /// are dropped from the session rather than left to fail (see OpenAIRealtimeMinter).
    func connect(robot: RobotController?) async {
        guard state == .disconnected || isFailed else { return }
        self.robot = robot
        state = .connecting
        // A reconnect gets a brand-new WebRTC track, which starts enabled. Without resetting this,
        // the gate believes it is already closed, every close is a no-op, and Rocky talks straight
        // into her own microphone -- which the log calls out as "mic gate leaked".
        micOpen = true
        userStoppedSpeakingAt = nil

        let connectStart = Date()
        if let startedAt { log("connect beginning \(Self.ms(since: startedAt)) after the tap") }
        do {
            try await AudioSessionManager.configureForVoice()
            startLocalAudio()
            let secret = try await OpenAIRealtimeMinter.mintEphemeralSecret(hasRobot: robot != nil)
            log(
                "minted secret in \(Self.ms(since: connectStart)) (robot: \(robot == nil ? "no" : "yes"), voice: \(hume == nil ? "openai" : "hume"))"
            )
            let negotiateStart = Date()

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
            // WebRTC has just taken the audio session for the microphone, which stops this
            // engine; bring it back before Rocky has anything to say.
            RockyAudioEngine.shared.ensureRunning()
            state = .connected
            log("webrtc negotiated in \(Self.ms(since: negotiateStart)), connected in \(Self.ms(since: connectStart)) total")
        } catch {
            state = .failed(error.localizedDescription)
            log("connect failed after \(Self.ms(since: connectStart)): \(error.localizedDescription)")
        }
    }

    /// Stops listening and speaking without tearing anything down.
    ///
    /// The WebRTC connection and the Realtime session stay open, which is the whole point: the
    /// conversation lives in that session, so ending it would mean Rocky came back remembering
    /// nothing. Pausing is a local act -- close the microphone, stop the audio already queued.
    func pause() {
        guard state == .connected else { return }
        stopLocalAudio()
        hume?.cancel()
        if responseStartedAt != nil { client.send(ResponseCancelEvent()) }
        finishResponse(reason: "paused")
        setMicrophoneOpen(false, reason: "paused")
        speaking = false
        state = .paused
        log("paused, holding the conversation open")

        pauseTimeout?.cancel()
        pauseTimeout = Task { [weak self] in
            try? await Task.sleep(for: Self.maxPauseBeforeTeardown)
            guard !Task.isCancelled else { return }
            await self?.endLongPause()
        }
    }

    /// Picks the same conversation back up, with a one-off nudge so Rocky knows she was away.
    func resume() {
        guard state == .paused else { return }
        pauseTimeout?.cancel()
        pauseTimeout = nil
        state = .connected
        setMicrophoneOpen(true, reason: "resumed")
        log("resumed, asking Rocky to acknowledge waking")
        client.send(ResponseCreateEvent(instructions: Self.wakePrompt))
    }

    private func endLongPause() {
        guard state == .paused else { return }
        log("paused too long, closing the session")
        disconnect()
    }

    func disconnect() {
        client.close()
        stopLocalAudio()
        hume?.cancel()
        humePlayer = nil
        eridian = nil
        humeTextBuffer = ""
        firstAudioWatchdog?.cancel()
        turnWatchdog?.cancel()
        pauseTimeout?.cancel()
        pauseTimeout = nil
        responseStartedAt = nil
        userStoppedSpeakingAt = nil
        micOpen = true
        speaking = false
        hasSpokenOnce = false
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
        hume.onAudio = { [weak self] base64, isLastChunk in
            guard let self else { return }
            if self.firstAudioAt == nil, let started = self.responseStartedAt {
                self.firstAudioAt = Date()
                self.log("hume first audio after \(Self.ms(since: started)) (text→voice latency)")
            }
            if isLastChunk {
                self.humeSawLastChunk = true
                self.log("hume last chunk received (\(self.humePlayer.map { $0.chunksThisResponse + 1 } ?? 0) chunks this turn)")
            }
            self.humePlayer?.push(base64: base64, isLastChunk: isLastChunk)
        }
        hume.onError = { [weak self] message in
            self?.log("hume error: \(message)")
        }
        player.onSpeakingChange = { [weak self] speaking in
            self?.handleSpeakingChange(speaking)
        }
    }

    private func stopLocalAudio() {
        eridian?.stop()
        humePlayer?.stop()
    }

    /// Barge-in. The server cancels the *response* itself; what it cannot do is stop audio this
    /// app has already queued locally, so that has to happen here or Rocky keeps talking over the
    /// person interrupting her.
    private func handleUserStartedSpeaking() {
        stopLocalAudio()
        hume?.cancel()
        if responseStartedAt != nil { finishResponse(reason: "barge-in") }
    }

    /// Whether this character's voice bypasses WebRTC's echo canceller.
    ///
    /// A Hume-voiced character is played through AVAudioEngine, which is outside the
    /// voice-processing render path, so the microphone genuinely hears her and has to be gated
    /// shut while she speaks. A character voiced by the Realtime model arrives on the WebRTC
    /// track itself, which *is* echo-cancelled -- gating there would buy nothing and would cost
    /// barge-in, since a closed microphone cannot hear an interruption.
    private var needsMicrophoneGate: Bool { hume != nil }

    private func setMicrophoneOpen(_ open: Bool, reason: String) {
        guard needsMicrophoneGate, micOpen != open else { return }
        micOpen = open
        client.setMicrophoneEnabled(open)
        log("mic \(open ? "open" : "closed") (\(reason))")
    }

    /// Rocky's voice and Fathom's arrive by completely different routes, so "she started
    /// speaking" has to be detected differently: Hume reports playback, while the Realtime
    /// model's own speech is only visible here as its transcript arriving.
    private func noteRockyStartedSpeaking() {
        guard !speaking else { return }
        speaking = true
        if !hasSpokenOnce {
            hasSpokenOnce = true
            if let started = startedAt {
                log("READY: first sound \(Self.ms(since: started)) after the orb was tapped")
            }
        }
    }

    private func handleSpeakingChange(_ speaking: Bool) {
        if speaking {
            noteRockyStartedSpeaking()
            setMicrophoneOpen(false, reason: "rocky speaking")
            return
        }
        self.speaking = false
        // Playback draining is not the same as Rocky being finished: if Hume is still streaming,
        // the queue can empty briefly between chunks. Reopening the mic there would put her own
        // remaining audio straight back into the server's ear -- the exact fault this gate exists
        // to prevent. Wait for the chunk Hume marked last; the turn watchdog covers the case
        // where that never comes.
        guard humeSawLastChunk else {
            log("playback drained mid-response, holding the turn open for more audio")
            return
        }
        if let started = responseStartedAt {
            log("rocky finished speaking, \(Self.ms(since: started)) after response started")
        }
        finishResponse(reason: "playback ended")
    }

    /// Feeds Rocky's streaming words to Hume a sensible mouthful at a time (see SpeechChunks).
    private func sendToHume(_ delta: String, flush: Bool = false) {
        guard let hume else { return }
        let split = SpeechChunks.split(buffer: humeTextBuffer, delta: delta, flush: flush)
        humeTextBuffer = split.remainder
        for (index, chunk) in split.complete.enumerated() {
            // Only the genuinely final chunk flushes. `remainder` is the same for every iteration,
            // so testing it alone marked *all* of them final, and Hume answered each with its own
            // end-of-stream -- several "last chunks" per turn, and a turn that looked finished
            // while more audio was still coming.
            let isFinal = flush && split.remainder.isEmpty && index == split.complete.count - 1
            log("hume ← \(chunk.count) chars\(isFinal ? " (final)" : "")")
            hume.speak(chunk, flush: isFinal)
        }
    }

    private func greetIfNeeded() {
        guard !greeted else { return }
        greeted = true
        client.send(ResponseCreateEvent())
        if let startedAt {
            log("asked Rocky to greet, \(Self.ms(since: startedAt)) after the tap")
        }
    }

    // MARK: - Watchdogs
    //
    // Ported from apps/desktop. Both exist because the failure that matters here is silence, and
    // silence is indistinguishable from thinking until you put a clock on it.

    /// Hume was sent text but no audio came back. Usually the socket died quietly; one retry on a
    /// fresh connection recovers it.
    private func armFirstAudioWatchdog() {
        firstAudioWatchdog?.cancel()
        guard hume != nil, !responseText.isEmpty else { return }
        firstAudioWatchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.firstAudioTimeout)
            guard !Task.isCancelled else { return }
            await self?.handleMissingFirstAudio()
        }
    }

    private func handleMissingFirstAudio() {
        guard firstAudioAt == nil, !responseText.isEmpty else { return }
        guard !retriedThisResponse else {
            log("hume produced no audio after retry, giving up on this turn")
            finishResponse(reason: "no audio after retry")
            return
        }
        retriedThisResponse = true
        log("hume produced no audio in 2.5s, retrying on a fresh socket")
        // Cancel first: the original request may be slow rather than lost, and would otherwise
        // deliver its audio after the retry's, speaking the same line twice.
        hume?.cancel()
        humePlayer?.stop()
        humeTextBuffer = ""
        humeSawLastChunk = false
        humePlayer?.beginResponse()
        sendToHume(responseText, flush: true)
        armFirstAudioWatchdog()
    }

    /// Anti-stuck, not anti-failure: if Rocky is still marked as speaking long after she should
    /// have finished, and nothing is actually queued, release the turn so the mic reopens.
    private func armTurnWatchdog() {
        turnWatchdog?.cancel()
        // Only the Hume path can get stuck: it is the one that gates the microphone and plays
        // audio this app has to track itself. When the model does its own speaking, response.done
        // always arrives and ends the turn, so a watchdog there would only ever fire early on a
        // long reply and cut it short.
        guard hume != nil else { return }
        let words = responseText.split(whereSeparator: \.isWhitespace).count
        let budget = min(12_000, max(4_000, 2_000 + words * 420))
        turnWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(budget))
            guard !Task.isCancelled else { return }
            await self?.handleTurnOverrun(budget: budget)
        }
    }

    private func handleTurnOverrun(budget: Int) {
        guard responseStartedAt != nil else { return }
        let queued = humePlayer?.millisecondsUntilPlaybackEnd ?? 0
        // Genuinely still talking: extend rather than cut real audio off mid-word.
        if queued > 750 {
            let grace = min(8_000, Int(queued) + 1_000)
            log("turn watchdog: \(Int(queued))ms still queued, extending \(grace)ms")
            turnWatchdog = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(grace))
                guard !Task.isCancelled else { return }
                await self?.handleTurnOverrun(budget: grace)
            }
            return
        }
        log("turn watchdog: stuck after \(budget)ms with nothing queued, releasing the turn")
        stopLocalAudio()
        finishResponse(reason: "turn watchdog")
    }

    /// One place where a turn ends, however it ended -- the mic reopens here and nowhere else, so
    /// there is no path that leaves Rocky deaf.
    private func finishResponse(reason: String) {
        firstAudioWatchdog?.cancel()
        firstAudioWatchdog = nil
        turnWatchdog?.cancel()
        turnWatchdog = nil
        responseStartedAt = nil
        firstTextAt = nil
        firstAudioAt = nil
        responseText = ""
        humeTextBuffer = ""
        retriedThisResponse = false
        humeSawLastChunk = false
        setMicrophoneOpen(true, reason: reason)
    }

    private func log(_ line: String) {
        RockyLog.write("voice: \(line)")
    }

    private static func ms(since date: Date) -> String {
        "\(Int(Date().timeIntervalSince(date) * 1000))ms"
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
            log("realtime error: \(event.error?.message ?? "unknown")")

        case "input_audio_buffer.speech_started":
            // Only a real interruption if Rocky isn't the one making the noise. The mic is gated
            // shut while she speaks, so this should already be impossible -- if it ever fires
            // mid-response the log says so, and that means the gate leaked.
            if responseStartedAt != nil {
                log("speech_started DURING response — mic gate leaked, treating as barge-in")
            }
            log("user started speaking")
            handleUserStartedSpeaking()

        case "input_audio_buffer.speech_stopped":
            userStoppedSpeakingAt = Date()
            log("user stopped speaking")

        case "response.created":
            responseStartedAt = Date()
            retriedThisResponse = false
            humeSawLastChunk = false
            responseText = ""
            firstTextAt = nil
            firstAudioAt = nil
            if let stopped = userStoppedSpeakingAt {
                log("response started \(Self.ms(since: stopped)) after user stopped (think latency)")
            } else {
                log("response started")
            }
            humePlayer?.beginResponse()
            eridian?.playThinkingPrelude()
            // The chords are already audible, so close the mic now rather than at first audio.
            setMicrophoneOpen(false, reason: "response started")
            // Armed here, not when the text finishes: a response that never produces any text at
            // all would otherwise have no clock on it, and the mic would stay shut for good --
            // which is precisely what "Rocky didn't respond" was. Every closed mic now has a
            // deadline from the moment it closes.
            armTurnWatchdog()

        // Hume path: OpenAI streams words, Hume speaks them, and the chord layer follows the
        // same text.
        case "response.output_text.delta":
            if let delta = event.delta {
                if firstTextAt == nil, let started = responseStartedAt {
                    firstTextAt = Date()
                    log("first word \(Self.ms(since: started)) after response started")
                }
                responseText += delta
                eridian?.pushTranscriptDelta(delta)
                sendToHume(delta)
            }
        case "response.output_text.done":
            responseText = event.text ?? responseText
            sendToHume("", flush: true)
            eridian?.flushTranscript()
            let words = responseText.split(whereSeparator: \.isWhitespace).count
            log("text complete: \(words) words, \(responseText.count) chars")
            armFirstAudioWatchdog()
            armTurnWatchdog()

        // Realtime-voice path: the audio itself arrives on the media track, so the transcript is
        // the only sign here that she has started talking -- and the only thing that can drive
        // the chord layer or end the loading animation.
        case "response.output_audio_transcript.delta":
            if let delta = event.delta {
                if firstAudioAt == nil, let started = responseStartedAt {
                    firstAudioAt = Date()
                    log("first audio \(Self.ms(since: started)) after response started")
                }
                noteRockyStartedSpeaking()
                eridian?.pushTranscriptDelta(delta)
            }
        case "response.output_audio_transcript.done":
            eridian?.flushTranscript()

        case "response.done":
            let status = event.response?.status ?? "unknown"
            if status != "completed" {
                let detail = event.response?.status_details
                log("response ended as \(status): \(detail?.reason ?? detail?.error?.message ?? "no reason given")")
            }
            // With Hume, the turn normally ends when playback does, not when the text does --
            // unless there was no text, in which case nothing will ever play and waiting for
            // playback would hold the microphone shut for nothing.
            if hume == nil {
                speaking = false
                finishResponse(reason: "response done")
            } else if responseText.isEmpty {
                log("response produced no text, nothing to speak — releasing the turn")
                finishResponse(reason: "empty response")
            }

        default:
            // Everything not explicitly handled, minus the high-frequency streaming events. Worth
            // the noise: the turn that failed here did so by way of an event this app never
            // mentioned, which made a 20-second silence look like nothing happening at all.
            if !event.type.hasSuffix(".delta") && !event.type.hasSuffix(".added") {
                log("event: \(event.type)")
            }
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
