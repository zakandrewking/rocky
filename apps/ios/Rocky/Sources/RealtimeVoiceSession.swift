import Foundation

/// Owns one Realtime voice conversation, and owns Rocky's sense of her own body while it runs.
///
/// Two responsibilities that used to be one. The conversation half is unchanged from before:
/// mint an ephemeral secret (OpenAIRealtimeMinter), open a direct WebRTC connection
/// (RealtimeWebRTCClient), time every leg of every turn, and keep the microphone honest. The
/// embodiment half is new, and lives mostly elsewhere on purpose -- WorldStore holds what is
/// true, WorldProjector decides what Rocky gets told, SalienceJudge decides whether it is worth
/// interrupting her for, and this class is the only thing that talks to OpenAI. See
/// apps/ios/docs/embodiment.md.
///
/// The rule that shapes the tool handling below: **a tool call registers an intent and returns.**
/// It never waits for the body. What actually happened arrives afterwards, as its own truth, and
/// reaches Rocky as state and events rather than as a return value. A function returning `true`
/// is not evidence that a robot moved, and the previous version of this file treated it as if it
/// were.
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

    /// What to say about something that just happened to her body. Phrased as a thing already
    /// over, because it is: a flinch lasts under a second and she cannot speak in under two.
    private static func reactionPrompt(to event: WorldEvent) -> String {
        """
        This just happened to your body: \(event.detail). It is over now. Say one short line
        reacting to it as something that happened to you, in your own way of speaking. Do not name
        it, do not describe it as a state or a mode, and do not ask what to do next.
        """
    }

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

    // MARK: - The world
    //
    // The authoritative picture of the body, and the machinery that decides what reaches Rocky.
    // Public for the debug panel, which is the whole point of building it this way: what she knew
    // and when she knew it is inspectable rather than reconstructed.

    let world = WorldStore()
    private lazy var projector = WorldProjector(store: world, channel: self)
    private let salience = SalienceJudge()
    private lazy var motionSource = MotionWorldSource(store: world)
    private lazy var behaviorSource = BehaviorWorldSource(store: world)
    private var behavior: BehaviorMonitor?
    private var worldTicker: Task<Void, Never>?

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
    private var isPaused = false
    /// True while Rocky's own un-cancelled audio could otherwise be heard as an interruption.
    private var gatedForOwnVoice = false

    // MARK: - Response lifecycle
    //
    // The Realtime API allows exactly one in-band response at a time; a second `response.create`
    // while one is live is rejected outright. Before this, two separate paths could each ask for
    // one (a tool-call follow-up and an unprompted reaction to a bump), and whichever lost simply
    // vanished with an error in the log. Everything that wants Rocky to speak now goes through
    // `requestResponse`, and exactly one request can be waiting.

    private var activeResponseId: String?
    /// Set the instant `response.create` goes out, cleared when the response is created or the
    /// attempt fails. The id only arrives on `response.created`, which is at least a round trip
    /// later -- so without this, two requests inside that window both look like the first one, and
    /// the second is rejected with "Conversation already has an active response". Two tool calls
    /// in one turn produced exactly that.
    private var awaitingResponse = false
    private var parkedRequest: (instructions: String?, reason: String)?
    /// Fires if the `response.done` that should follow a cancel never turns up, so an interrupted
    /// turn can never leave Rocky permanently unable to ask for another response.
    private var cancelWatchdog: Task<Void, Never>?
    /// The assistant message item currently being spoken -- needed to truncate it if she is cut
    /// off, so her memory of what she said matches what was actually heard.
    private var currentAssistantItemId: String?
    private var audioStartedAt: Date?
    private var utteranceSoFar = ""
    /// Salience judgments run as out-of-band responses on the same data channel as everything
    /// else, so their ids have to be recognised or their deltas would be mistaken for speech.
    private var salienceResponses: [String: String] = [:]
    private var salienceText: [String: String] = [:]
    /// An event judged worth reacting to, but not worth cutting a sentence in half for.
    private var reactAfterUtterance: WorldEvent?

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
    func connect(robot: RobotController?, behavior: BehaviorMonitor? = nil) async {
        self.behavior = behavior
        guard state == .disconnected || isFailed else { return }
        self.robot = robot
        state = .connecting
        // A reconnect gets a brand-new WebRTC track, which starts enabled. Without resetting this,
        // the gate believes it is already closed, every close is a no-op, and Rocky talks straight
        // into her own microphone -- which the log calls out as "mic gate leaked".
        micOpen = true
        isPaused = false
        gatedForOwnVoice = false
        userStoppedSpeakingAt = nil

        wireWorld(robot: robot, behavior: behavior)

        let connectStart = Date()
        if let startedAt { log("connect beginning \(Self.ms(since: startedAt)) after the tap") }
        do {
            try await AudioSessionManager.configureForVoice()
            startLocalAudio()
            let body: OpenAIRealtimeMinter.Body =
                robot != nil ? .driving : (behavior?.connected == true ? .watching : .none)
            let secret = try await OpenAIRealtimeMinter.mintEphemeralSecret(body: body)
            log(
                "minted secret in \(Self.ms(since: connectStart)) (body: \(body), voice: \(hume == nil ? "openai" : "hume"))"
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

    // MARK: - Wiring the world

    /// Points the world model at whichever body was found, and points the salience judge at the
    /// data channel. Only one payload runs on the board at a time, so at most one of these two
    /// sources will ever see traffic -- but both are wired, because which one it is is discovered
    /// at runtime, not chosen here.
    private func wireWorld(robot: RobotController?, behavior: BehaviorMonitor?) {
        world.onChange = { [weak self] change in
            self?.worldChanged(change)
        }
        salience.askOutOfBand = { [weak self] ticket, prompt in
            self?.sendSalienceRequest(ticket, prompt)
        }
        behavior?.onBoardMessage = { [weak self] message in
            self?.behaviorSource.handle(message)
        }
        if let robot {
            Task {
                await robot.observe { [weak self] report in
                    Task { @MainActor in self?.motionSource.handle(report) }
                }
                // A connected motion agent is a body that is present. Nothing else says so: this
                // agent sends no unprompted traffic, so without this the world would open with
                // "my body is gone" while the robot sat there answering commands.
                if await robot.isConnected { self.world.heard() }
            }
        }
        worldTicker?.cancel()
        worldTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await self?.tickWorld()
            }
        }
    }

    private func tickWorld() {
        world.tick()
        projector.checkpoint()
    }

    /// The one place a change in the world becomes a decision about speech. Projection happens
    /// for everything; interrupting almost never does.
    private func worldChanged(_ change: WorldChange) {
        projector.handle(change)
        guard case .event(let event) = change else { return }
        consider(event)
    }

    private func consider(_ event: WorldEvent) {
        let moment = currentMoment()
        if let verdict = salience.rule(on: event, action: world.liveAction, moment: moment) {
            apply(verdict, to: event)
            return
        }
        // Genuinely ambiguous, and she is mid-sentence. Ask her -- out of band, so the question
        // and the answer never touch the conversation she is having.
        salience.ask(about: event, snapshot: world.snapshot, moment: moment)
    }

    private func apply(_ verdict: SalienceVerdict, to event: WorldEvent) {
        switch verdict {
        case .ignore, .context:
            break  // she already knows; the projection did that
        case .afterUtterance:
            reactAfterUtterance = event
        case .interrupt, .urgent:
            if activeResponseId != nil {
                interrupt(because: event)
            } else {
                requestResponse(instructions: Self.reactionPrompt(to: event), reason: "reacting to \(event.id)")
            }
        }
    }

    private func currentMoment() -> VoiceMoment {
        VoiceMoment(
            isGenerating: activeResponseId != nil,
            responseId: activeResponseId,
            utteranceSoFar: utteranceSoFar,
            worldSeq: world.seq
        )
    }

    // MARK: - Speaking

    /// The single door to `response.create`. Anything that wants Rocky to say something asks here,
    /// and one request at most can be waiting -- a newer reason to speak replaces an older one
    /// rather than queueing behind it, because by the time the older one gets its turn the moment
    /// that prompted it has passed.
    private func requestResponse(instructions: String? = nil, reason: String) {
        guard client.isDataChannelOpen, !isPaused else { return }
        if activeResponseId != nil || awaitingResponse {
            parkedRequest = (instructions, reason)
            log("holding a response request (\(reason)) until the current one finishes")
            return
        }
        awaitingResponse = true
        // Nothing goes out until she has the current picture. This is the promise the whole design
        // rests on: every response Rocky begins, begins grounded.
        projector.flush(reason)
        client.send(ResponseCreateEvent(instructions: instructions))
        WorldLog.shared.write(.response, "asked for a response: \(reason)", seq: world.seq)
    }

    private func releaseParkedRequest() {
        guard let parked = parkedRequest else {
            if let event = reactAfterUtterance {
                reactAfterUtterance = nil
                requestResponse(instructions: Self.reactionPrompt(to: event), reason: "reacting after the utterance")
            }
            return
        }
        parkedRequest = nil
        reactAfterUtterance = nil
        requestResponse(instructions: parked.instructions, reason: parked.reason)
    }

    /// The full interruption, in the order that actually works.
    ///
    /// Cancelling stops the model generating, but it cannot un-send audio already buffered for
    /// playback, and it does not stop a synthesiser running outside WebRTC entirely. Truncating
    /// last is what keeps her memory of what she said matching what was heard -- otherwise she
    /// remembers finishing a sentence nobody heard the end of, and refers back to it.
    private func interrupt(because event: WorldEvent) {
        guard let responseId = activeResponseId else { return }
        log("interrupting \(responseId) for \(event.id) (\(event.kind.rawValue))")
        client.send(ResponseCancelEvent(responseId: responseId))
        client.send(OutputAudioBufferClearEvent())
        stopLocalAudio()
        hume?.cancel()
        if let itemId = currentAssistantItemId, let started = audioStartedAt {
            // Approximate, and honestly so: on WebRTC the exact playback position is not
            // reported, so this is how long audio had been arriving. Erring long would delete
            // words she did say; erring short leaves a fragment she did not. Elapsed-since-first-
            // audio is the closest thing to the truth available here.
            let heard = Int(Date().timeIntervalSince(started) * 1000)
            client.send(ConversationItemTruncateEvent(itemId: itemId, audioEndMs: heard))
        }
        WorldLog.shared.closeLedger(responseId, outcome: "interrupted", interruptedBy: event.id)
        speaking = false
        finishResponse(reason: "interrupted by \(event.id)")
        // Parked, not sent. The server has not processed the cancel yet, and a `response.create`
        // that overtakes it is rejected outright -- so the reaction goes out on the
        // `response.done` the cancel produces. The watchdog covers the case where it never does.
        parkedRequest = (Self.reactionPrompt(to: event), "interrupted by \(event.id)")
        cancelWatchdog?.cancel()
        cancelWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            await self?.forceReleaseAfterCancel(responseId)
        }
    }

    private func forceReleaseAfterCancel(_ responseId: String) {
        guard activeResponseId == responseId else { return }
        log("no response.done after cancelling \(responseId); releasing anyway")
        activeResponseId = nil
        awaitingResponse = false
        releaseParkedRequest()
    }

    // MARK: - Out-of-band salience

    private func sendSalienceRequest(_ ticket: SalienceTicket, _ prompt: String) {
        guard client.isDataChannelOpen else { return }
        client.send(
            OutOfBandResponseEvent(
                metadata: ["purpose": "salience", "ticket": ticket.id],
                instructions: prompt,
                input: "Decide now."
            )
        )
    }

    /// A judgment came back. Everything about whether it still means anything lives in the judge;
    /// this only has to not act on a nil.
    private func resolveSalience(ticketId: String, text: String) {
        // Read before resolving: the judge clears its pending slot as part of deciding, and the
        // event this was ever about is only recoverable from the ticket.
        let eventId = salience.pending?.id == ticketId ? salience.pending?.eventId : nil
        let (decision, reason) = Self.parseVerdict(text)
        guard let verdict = salience.resolve(
            ticketId: ticketId, decision: decision, reason: reason, moment: currentMoment()
        ) else { return }
        guard let eventId, let event = world.events.last(where: { $0.id == eventId }) else { return }
        apply(verdict, to: event)
    }

    /// Tolerant on purpose. A judge that wraps its JSON in a sentence should still be understood;
    /// one that says something unrecognisable should fall through to "ignore" rather than to a
    /// crash or, worse, to an interruption.
    static func parseVerdict(_ text: String) -> (decision: String, reason: String) {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            return ("ignore", "no JSON in the reply")
        }
        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ("ignore", "unparseable reply") }
        return (
            object["decision"] as? String ?? "ignore",
            object["reason"] as? String ?? "no reason given"
        )
    }

    /// Stops listening and speaking without tearing anything down.
    ///
    /// The WebRTC connection and the Realtime session stay open, which is the whole point: the
    /// conversation lives in that session, so ending it would mean Rocky came back remembering
    /// nothing. Pausing is a local act -- close the microphone, stop the audio already queued.
    func pause() {
        guard state == .connected else { return }
        // Set first: finishResponse below reopens the microphone, and pausing has to outrank that.
        isPaused = true
        stopLocalAudio()
        hume?.cancel()
        // Unconditionally, not only mid-response: generation may have finished while audio is
        // still arriving, and cancelling a response that has already ended is harmless.
        client.send(ResponseCancelEvent(responseId: activeResponseId))
        // Silences a character voiced by the Realtime model, whose audio plays through the peer
        // connection rather than any local player -- stopping local audio leaves it talking.
        client.setRemoteAudioEnabled(false)
        activeResponseId = nil
        awaitingResponse = false
        cancelWatchdog?.cancel()
        parkedRequest = nil
        reactAfterUtterance = nil
        finishResponse(reason: "paused")
        refreshMicrophone("paused")
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
        isPaused = false
        state = .connected
        client.setRemoteAudioEnabled(true)
        refreshMicrophone("resumed")
        log("resumed, asking Rocky to acknowledge waking")
        requestResponse(instructions: Self.wakePrompt, reason: "resumed")
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
        worldTicker?.cancel()
        worldTicker = nil
        responseStartedAt = nil
        userStoppedSpeakingAt = nil
        micOpen = true
        isPaused = false
        gatedForOwnVoice = false
        speaking = false
        hasSpokenOnce = false
        state = .disconnected
        robot = nil
        greeted = false
        activeResponseId = nil
        awaitingResponse = false
        cancelWatchdog?.cancel()
        cancelWatchdog = nil
        parkedRequest = nil
        reactAfterUtterance = nil
        currentAssistantItemId = nil
        utteranceSoFar = ""
        salienceResponses = [:]
        salienceText = [:]
        // The conversation is gone, so every item id in it is gone with it -- but the body is
        // exactly where it was, so the store is deliberately left alone.
        projector.reset()
        salience.reset()
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
                self.audioStartedAt = Date()
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

    /// Two separate reasons the microphone might be shut, deliberately not conflated.
    ///
    /// The echo gate is a workaround for one character's audio path and is off for the rest.
    /// Pausing is what the user asked for and applies to everyone -- routing it through the gate
    /// meant that for a character which needs no gate, pause left the microphone wide open and
    /// the conversation carried on underneath a UI that said "paused".
    private func refreshMicrophone(_ reason: String) {
        let open = !isPaused && !(needsMicrophoneGate && gatedForOwnVoice)
        guard micOpen != open else { return }
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
            gatedForOwnVoice = true
            refreshMicrophone("rocky speaking")
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
        requestResponse(reason: "greeting")
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
        audioStartedAt = nil
        responseText = ""
        utteranceSoFar = ""
        currentAssistantItemId = nil
        humeTextBuffer = ""
        retriedThisResponse = false
        humeSawLastChunk = false
        gatedForOwnVoice = false
        refreshMicrophone(reason)
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
        // Out-of-band salience judgments arrive on the same data channel as Rocky's own speech.
        // Routing them out first, before anything else looks at them, is what stops a judgment
        // being mistaken for her talking -- which would start watchdogs, gate the microphone and
        // put deliberation into the chord layer.
        if handleOutOfBand(event) { return }

        switch event.type {
        case "error":
            log("realtime error: \(event.error?.message ?? "unknown")")
            // A rejected `response.create` never becomes a response, so nothing else would ever
            // clear this -- and Rocky would be silent for the rest of the session.
            if awaitingResponse {
                awaitingResponse = false
                releaseParkedRequest()
            }

        case "input_audio_buffer.speech_started":
            // Only a real interruption if Rocky isn't the one making the noise. The mic is gated
            // shut while she speaks, so this should already be impossible -- if it ever fires
            // mid-response the log says so, and that means the gate leaked.
            if responseStartedAt != nil {
                log("speech_started DURING response — mic gate leaked, treating as barge-in")
            }
            log("user started speaking")
            handleUserStartedSpeaking()
            // The earliest reliable warning that a response is coming. Getting the current picture
            // in now, rather than when the response is already being generated, is what makes
            // "every response begins grounded" true for turns the person starts.
            projector.flush("user started speaking")

        case "input_audio_buffer.speech_stopped":
            userStoppedSpeakingAt = Date()
            log("user stopped speaking")
            // The user's turn is now an item in the conversation, so the live snapshot is no
            // longer the last thing in it -- replacing it from here on costs a cache miss.
            projector.noteConversationAdvanced()
            projector.flush("user stopped speaking")

        case "response.created":
            activeResponseId = event.response?.id
            awaitingResponse = false
            cancelWatchdog?.cancel()
            // A response always appends at least one item.
            projector.noteConversationAdvanced()
            responseStartedAt = Date()
            retriedThisResponse = false
            humeSawLastChunk = false
            responseText = ""
            utteranceSoFar = ""
            currentAssistantItemId = nil
            audioStartedAt = nil
            firstTextAt = nil
            firstAudioAt = nil
            recordLedger()
            if let stopped = userStoppedSpeakingAt {
                log("response started \(Self.ms(since: stopped)) after user stopped (think latency)")
            } else {
                log("response started")
            }
            humePlayer?.beginResponse()
            eridian?.playThinkingPrelude()
            // The chords are already audible, so close the mic now rather than at first audio.
            gatedForOwnVoice = true
            refreshMicrophone("response started")
            // Armed here, not when the text finishes: a response that never produces any text at
            // all would otherwise have no clock on it, and the mic would stay shut for good --
            // which is precisely what "Rocky didn't respond" was. Every closed mic now has a
            // deadline from the moment it closes.
            armTurnWatchdog()

        case "response.output_item.added":
            // The only event carrying the assistant item's id, and truncating an interrupted
            // utterance needs it. Captured for message items only; a function_call item has
            // nothing spoken to truncate.
            if event.item?.type == "message", let id = event.item?.id {
                currentAssistantItemId = id
            }

        // Hume path: OpenAI streams words, Hume speaks them, and the chord layer follows the
        // same text.
        case "response.output_text.delta":
            if let delta = event.delta {
                if firstTextAt == nil, let started = responseStartedAt {
                    firstTextAt = Date()
                    log("first word \(Self.ms(since: started)) after response started")
                }
                responseText += delta
                utteranceSoFar += delta
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
                    audioStartedAt = Date()
                    log("first audio \(Self.ms(since: started)) after response started")
                }
                utteranceSoFar += delta
                noteRockyStartedSpeaking()
                eridian?.pushTranscriptDelta(delta)
            }
        case "response.output_audio_transcript.done":
            eridian?.flushTranscript()

        case "output_audio_buffer.started":
            // WebRTC's own signal that audio is actually leaving for the speaker -- a better
            // clock for "how much did they hear" than the transcript, which runs ahead of it.
            audioStartedAt = Date()

        case "response.done":
            let status = event.response?.status ?? "unknown"
            if status != "completed" {
                let detail = event.response?.status_details
                log("response ended as \(status): \(detail?.reason ?? detail?.error?.message ?? "no reason given")")
            }
            if let id = event.response?.id, let usage = event.response?.usage, let input = usage.input_tokens {
                // The measurement that says whether editing conversation history is costing
                // anything. A response whose cached share has collapsed, sitting directly under a
                // projection, is this design's bill arriving.
                WorldLog.shared.recordCost(
                    id,
                    inputTokens: input,
                    cachedTokens: usage.input_token_details?.cached_tokens ?? 0,
                    cachedPercent: usage.cachedPercent
                )
            }
            if let id = event.response?.id, id == activeResponseId {
                WorldLog.shared.closeLedger(id, outcome: status)
                activeResponseId = nil
                cancelWatchdog?.cancel()
                cancelWatchdog = nil
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
            releaseParkedRequest()

        default:
            // Everything not explicitly handled, minus the high-frequency streaming events. Worth
            // the noise: the turn that failed here did so by way of an event this app never
            // mentioned, which made a 20-second silence look like nothing happening at all.
            // Any item that is not our own live snapshot means the snapshot is no longer the tail.
            if event.type.hasPrefix("conversation.item."), event.type.hasSuffix("created"),
                event.item?.id != projector.liveStateItemId {
                projector.noteConversationAdvanced()
            }
            // The conversation.item.* echoes are excluded from the prose log: every state
            // projection produces a created and a deleted, so at a few per second they would bury
            // the turn timings this log exists for -- and world.jsonl already records each
            // projection with its item id.
            if !event.type.hasSuffix(".delta") && !event.type.hasSuffix(".added")
                && !event.type.hasPrefix("conversation.item.") {
                log("event: \(event.type)")
            }
        }
        // Every tool result first, then exactly one request to speak. A response per call meant a
        // turn with two tool calls asked for two responses, and the second was rejected -- the
        // model had answered, and nothing came out.
        let calls = event.toolCalls
        for call in calls {
            guard let name = call.name, let callId = call.call_id else { continue }
            await performToolCall(name: name, argumentsJSON: call.arguments ?? "{}", callId: callId)
        }
        if !calls.isEmpty {
            requestResponse(reason: "after \(calls.compactMap(\.name).joined(separator: "+"))")
        }
    }

    /// Returns true when the event belonged to a salience judgment and has been dealt with.
    private func handleOutOfBand(_ event: RealtimeServerEvent) -> Bool {
        if event.type == "response.created", let ticket = event.response?.metadata?["ticket"],
            let id = event.response?.id {
            salienceResponses[id] = ticket
            salienceText[id] = ""
            return true
        }
        guard let responseId = event.response_id ?? event.response?.id,
            let ticket = salienceResponses[responseId]
        else { return false }

        switch event.type {
        case "response.output_text.delta":
            salienceText[responseId, default: ""] += event.delta ?? ""
        case "response.output_text.done":
            if let text = event.text { salienceText[responseId] = text }
        case "response.done":
            let text = salienceText[responseId] ?? ""
            salienceResponses.removeValue(forKey: responseId)
            salienceText.removeValue(forKey: responseId)
            resolveSalience(ticketId: ticket, text: text)
        default:
            break
        }
        return true
    }

    /// Writes down what Rocky actually had in front of her at the instant this response began.
    ///
    /// Recorded here rather than reconstructed later, because reconstruction is exactly what
    /// cannot be trusted: by the time anyone asks "what did she know when she said that", the
    /// world has moved on and the superseded state is gone.
    private func recordLedger() {
        guard let responseId = activeResponseId else { return }
        let action = world.liveAction
        WorldLog.shared.record(
            ResponseLedger(
                id: responseId,
                at: Date(),
                worldSeq: world.seq,
                activeAction: action.map {
                    "\($0.id) \($0.intent.word) \($0.status.rawValue) (\($0.evidence.rawValue))"
                },
                mostRecentEvent: world.mostRecentEvent.map {
                    "\($0.id) \($0.kind.rawValue) \(WorldWords.ago($0.secondsAgo))"
                },
                liveStateItem: projector.liveStateItemId,
                supersededStateItems: projector.supersededStateItemIds
            )
        )
    }

    // MARK: - Tools

    private func performToolCall(name: String, argumentsJSON: String, callId: String) async {
        RockyLog.write("tool call: \(name) \(argumentsJSON)")
        WorldLog.shared.write(.tool, "\(name) \(argumentsJSON)", seq: world.seq)
        lastToolCall = name
        let output: String
        do {
            output = try await execute(name: name, argumentsJSON: argumentsJSON)
        } catch {
            output = Self.encodeResult(["ok": false, "problem": error.localizedDescription])
        }
        client.send(FunctionCallOutputEvent(callId: callId, output: output))
        projector.noteConversationAdvanced()
    }

    private func execute(name: String, argumentsJSON: String) async throws -> String {
        let data = Data(argumentsJSON.utf8)

        // Handled first, and without a RobotController: these reach the board's own behaviour
        // loop, which is running precisely when there is no motion server to hold.
        switch name {
        case "set_robot_mood":
            let args = try JSONDecoder().decode(MoodArgs.self, from: data)
            guard let behavior else { return Self.encodeResult(["ok": false, "problem": "no body listening"]) }
            // Deliberately not an action. How wound up she is has no beginning, middle or end to
            // track -- and registering it as one would supersede whatever movement was actually
            // in flight, so settling down mid-spin would silently abandon the spin.
            behavior.setMood(args.mood, id: "mood")
            world.noteFeeling(args.mood)
            return Self.encodeResult(["ok": true])

        case "robot_gesture":
            let args = try JSONDecoder().decode(GestureArgs.self, from: data)
            guard let behavior else { return Self.encodeResult(["ok": false, "problem": "no body listening"]) }
            let times = max(1, min(10, Int(args.times ?? 1)))
            let intent: ActionIntent = args.gesture == "wiggle" ? .wiggle : .spin
            // The board honours gestures at its own seams, so this is genuinely open-ended: the
            // expected duration is a bound for calling it lost, not a promise about when.
            let action = world.beginAction(
                intent, expectedDuration: Double(times) * 2.5 + 6, total: times
            )
            behaviorSource.expect(gesture: action.id)
            behavior.requestGesture(args.gesture, times: times, id: action.id)
            world.markAction(action.id, status: .accepted)
            return Self.accepted(action)

        case "get_robot_state":
            return Self.encodeState(world)

        case "stop_robot" where robot == nil:
            guard let behavior else { return Self.encodeResult(["ok": false, "problem": "no body listening"]) }
            let action = world.beginAction(.stop, expectedDuration: 0.3)
            behavior.stopMoving()
            world.markAction(action.id, status: .accepted)
            world.noteDoing(.still, cause: .youAsked)
            world.markAction(action.id, status: .succeeded, evidence: .assumed)
            return Self.accepted(action)

        default:
            break
        }

        guard let robot else { throw RobotError.disconnected }

        switch name {
        case "drive_cm":
            let args = try JSONDecoder().decode(DriveArgs.self, from: data)
            let speed = args.speed ?? RobotLimits.defaultSpeed
            let action = world.beginAction(
                args.distanceCm < 0 ? .driveBackward : .driveForward,
                expectedDuration: RobotLimits.estimatedDriveSeconds(distanceCm: args.distanceCm, speed: speed)
            )
            motionSource.expect(action.intent)
            world.markAction(action.id, status: .accepted)
            await robot.drive(actionId: action.id, distanceCm: args.distanceCm, speed: speed)
            return Self.accepted(action)

        case "rotate_degrees":
            let args = try JSONDecoder().decode(TurnArgs.self, from: data)
            let speed = args.speed ?? RobotLimits.defaultSpeed
            let action = world.beginAction(
                abs(args.degrees) >= 300 ? .spin : .turn,
                expectedDuration: RobotLimits.estimatedTurnSeconds(degrees: args.degrees, speed: speed)
            )
            motionSource.expect(action.intent)
            world.markAction(action.id, status: .accepted)
            await robot.turn(actionId: action.id, degrees: args.degrees, speed: speed)
            return Self.accepted(action)

        case "stop_robot":
            let action = world.beginAction(.stop, expectedDuration: 0.3)
            world.markAction(action.id, status: .accepted)
            world.noteDoing(.still, cause: .youAsked)
            await robot.stop(actionId: action.id)
            return Self.accepted(action)

        case "read_distance":
            // A query, not a movement: the answer *is* the point, and it arrives in milliseconds,
            // so there is nothing here for the action lifecycle to describe.
            let cm = try await robot.readDistanceCm()
            return Self.encodeResult(["ok": true, "nearestCm": cm])

        case "set_face":
            let args = try JSONDecoder().decode(FaceArgs.self, from: data)
            guard let face = FaceState(rawValue: args.face) else {
                return Self.encodeResult(["ok": false, "problem": "no such face"])
            }
            try await robot.setFace(face)
            return Self.encodeResult(["ok": true])

        case "set_lights":
            let args = try JSONDecoder().decode(LightArgs.self, from: data)
            try await robot.setLights(red: args.red, green: args.green, blue: args.blue)
            return Self.encodeResult(["ok": true])

        default:
            return Self.encodeResult(["ok": false, "problem": "I don't have that"])
        }
    }

    /// What a movement tool returns, and deliberately all it returns.
    ///
    /// `accepted` means the instruction is on its way. It is not a claim that anything moved, and
    /// the tool description says so in as many words -- because the previous `{"success": true}`
    /// was read, entirely reasonably, as "I did it", and Rocky would announce a spin that had not
    /// begun and might never happen.
    private static func accepted(_ action: RobotAction) -> String {
        encodeResult([
            "action_id": action.id,
            "status": "accepted",
            "means": "on its way to your body — not yet happening. You will feel it when it does.",
        ])
    }

    /// Rocky's memory of herself, rendered from the one authoritative store -- the same picture
    /// the pushed state carries, so asking and being told can never disagree.
    private static func encodeState(_ world: WorldStore) -> String {
        var fields: [String: Any] = [:]
        let snapshot = world.snapshot
        fields["now"] = [
            "body": snapshot.body.rawValue,
            "doing": snapshot.doing.word,
            "moving": snapshot.moving,
            "why": snapshot.cause.phrase,
            "blocked": snapshot.blocked,
        ]
        if let feeling = snapshot.feeling { fields["feeling"] = feeling }
        if let cm = snapshot.nearestCm, let measured = snapshot.measuredAt {
            fields["nearest_cm"] = Int(cm.rounded())
            fields["measured"] = WorldWords.ago(Date().timeIntervalSince(measured))
        }
        if let action = snapshot.action {
            fields["right_now"] = WorldProjector.describe(action)
        }
        // Recent history, newest first. This is what makes "did that work?" answerable about an
        // action that finished a minute ago -- the live snapshot has long since stopped carrying
        // it, and that is correct: it is history now, not a condition.
        fields["just_did"] = world.actions.reversed().prefix(5).map { action in
            var entry = WorldProjector.describe(action)
            entry["when"] = WorldWords.ago(Date().timeIntervalSince(action.endedAt ?? action.requestedAt))
            return entry
        }
        fields["just_happened"] = world.events.reversed().prefix(5).map { event in
            [
                "what": event.kind.rawValue,
                "detail": event.detail,
                "when": WorldWords.ago(event.secondsAgo),
            ]
        }

        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else { return encodeResult(["ok": false, "problem": "I can't tell right now"]) }
        return json
    }

    private struct DriveArgs: Decodable {
        let distanceCm: Double
        let speed: Double?
    }

    private struct TurnArgs: Decodable {
        let degrees: Double
        let speed: Double?
    }

    private struct LightArgs: Decodable {
        let red: Int
        let green: Int
        let blue: Int
    }

    private struct MoodArgs: Decodable {
        let mood: String
    }

    private struct GestureArgs: Decodable {
        let gesture: String
        let times: Double?
    }

    private struct FaceArgs: Decodable {
        let face: String
    }

    /// Encodes a small, flat JSON object for a function_call_output. Values are deliberately
    /// restricted to the handful of types tool results actually need -- this isn't a general
    /// JSON encoder, just enough to avoid hand-building JSON strings with string interpolation.
    private static func encodeResult(_ fields: [String: Any]) -> String {
        var parts: [String] = []
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
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

// MARK: - VoiceChannel

/// The narrow surface the projector is allowed to use. Everything else about the Realtime
/// connection is private to this class, so there is exactly one way for a robot fact to become
/// something Rocky knows.
extension RealtimeVoiceSession: VoiceChannel {
    var canReachVoice: Bool { client.isDataChannelOpen && !isPaused }

    func insertWorldItem(id: String, text: String) {
        client.send(ConversationItemCreateEvent(id: id, text: text))
    }

    func removeWorldItem(id: String) {
        client.send(ConversationItemDeleteEvent(id: id))
    }
}
