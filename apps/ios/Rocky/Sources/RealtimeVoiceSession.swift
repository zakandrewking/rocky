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

    /// One unobtrusive bridge after a deliberate pause. It neither retries an interrupted greeting
    /// nor turns silence into a generic assistant asking the friend to supply a new topic.
    static let resumePrompt = """
        Continue the shared moment in your established voice with exactly one short declarative
        line. Do not refer to the interruption or describe your readiness, attention, or
        availability. Do not ask anything or invite the friend to supply a topic. If there is no
        clear continuing topic, express simple pleasure in the friend's presence and stop.
        """

    /// A reflex is allowed to sound immediate only on the path that has actually preempted any
    /// words already in the speaker. This promise is enforced by `interrupt(because:)` below.
    static func immediateReactionPrompt(to event: WorldEvent) -> String {
        """
        A surprising thing just happened to you: \(event.detail). This response is immediate: any
        speech already in progress has been stopped instead of playing before this reaction. Say
        one short reflexive line in your own voice. Do not name a state or mode, and do not ask
        what to do next.
        """
    }

    /// A reaction deliberately saved until the current utterance ends is memory, not a reflex.
    /// Make the temporal distinction explicit so a delayed note cannot open with “Whoa”.
    static func rememberedReactionPrompt(to event: WorldEvent) -> String {
        """
        This happened to you earlier: \(event.detail). It did not interrupt the shared
        conversation. If it is still worth mentioning, say one short line that clearly remembers
        it as finished, using past tense. Do not act freshly surprised and never begin with Whoa,
        Wow, Oh, Ah, Ow, or a gasp. Do not name a state or mode, and do not ask what to do next.
        """
    }

    /// Function output is an implementation seam, not a fresh conversational topic. The generic
    /// continuation used in the failed story session made the model announce every move in its
    /// own response. This returns attention to the relationship without casting the person as an
    /// operator whose request Rocky is executing.
    static let toolFollowupPrompt = """
        Continue the shared conversation as a self-directed alien friend, not the tool call. Tools
        and body state are silent body language, never a new conversational turn. Continue the
        current thought, story, game, song, joke, or explanation naturally without a fresh
        acknowledgement, movement report, capability explanation, or invitation. If the thought
        was already complete, produce no additional words or movement calls. Any ordinary text in
        the earlier response was withheld from speech because it accompanied a tool call;
        include the actual conversational answer here if it has not yet been heard. If the
        friend's whole turn was a playful physical idea and your silent movement or light choice
        already answered it, produce no words; never narrate waiting, momentum, future motion, or
        a color change.
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
    private var greeted = false

    // MARK: - The world
    //
    // The authoritative picture of the body, and the machinery that decides what reaches Rocky.
    // Public for the debug panel, which is the whole point of building it this way: what she knew
    // and when she knew it is inspectable rather than reconstructed.

    let world = WorldStore()
    private lazy var projector = WorldProjector(store: world, channel: self)
    private let salience = SalienceJudge()
    private lazy var behaviorSource = BehaviorWorldSource(store: world)
    private var behavior: BehaviorMonitor?
    /// Fixed for the lifetime of one Realtime conversation. Changing personality starts a new
    /// session rather than mutating a character's voice and memory halfway through a thought.
    private var activeCharacterID = PersonalityCatalog.defaultCharacterID
    /// Capability currently advertised to Realtime; the physical link may change while paused.
    private var sessionHasBody: Bool?
    private var worldTicker: Task<Void, Never>?

    /// The synthesiser, present only when the active character actually wants one. Characters
    /// voiced by the Realtime model itself speak over the WebRTC track and never touch this --
    /// one network hop instead of two, which is most of why it sounds quicker.
    private var hume: HumeSpeech?
    private var humePlayer: HumePcmPlayer?
    private var storySounds: StorySoundEffects?
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
    /// The exact text currently being synthesized. Usually this is the response text; during an
    /// interleaved performance it is only the current say step, so a Hume retry cannot accidentally
    /// speak the entire performance at once and skip its movement cues.
    private var humeUtteranceText = ""
    private var firstAudioWatchdog: Task<Void, Never>?
    private var turnWatchdog: Task<Void, Never>?
    private var retriedThisResponse = false
    private var humeSawLastChunk = false
    private var pauseTimeout: Task<Void, Never>?
    private var isPaused = false

    // MARK: - Response lifecycle
    //
    // The Realtime API allows exactly one in-band response at a time; a second `response.create`
    // while one is live is rejected outright. Before this, two separate paths could each ask for
    // one (a tool-call follow-up and an unprompted reaction to a bump), and whichever lost simply
    // vanished with an error in the log. Everything that wants Rocky to speak now goes through
    // `requestResponse`, and exactly one request can be waiting.

    private var activeResponseId: String?
    /// The identity of the utterance people can still hear. Unlike `activeResponseId`, this stays
    /// set after Realtime finishes generating text and until local Hume playback actually drains.
    private var utteranceResponseId: String?
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

    private struct PerformancePlayback {
        let id: String
        let steps: [RobotPerformance.Step]
        var nextIndex = 0
        /// A say or sound step currently being heard. If interrupted, replay it from its beginning
        /// rather than skipping words merely because synthesis had already started.
        var currentStepIndex: Int? = nil
    }

    private var queuedPerformance: PerformancePlayback?
    private var activePerformance: PerformancePlayback?
    private var suspendedPerformance: PerformancePlayback?
    /// Speech and effects tell us when playback really ends. Movement now gets the same treatment:
    /// wait for the correlated board transition instead of pretending a socket write moved wheels.
    private var performanceWaitingForActionId: String?
    private var performanceMovementFallback: Task<Void, Never>?
    private var performancePauseTask: Task<Void, Never>?

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

    /// `behavior` is nil, or present but not connected, when no robot was found on the network.
    /// That is a supported, ordinary state -- the app is then exactly what apps/desktop is, a
    /// voice-only Rocky -- so the body tools are dropped from the session rather than left to fail
    /// (see OpenAIRealtimeMinter).
    func connect(behavior: BehaviorMonitor?, characterID: String) async {
        self.behavior = behavior
        guard state == .disconnected || isFailed else { return }
        activeCharacterID = PersonalityCatalog.resolvedID(characterID)
        hume = OpenAIRealtimeMinter.characterSpeaksThroughHume(characterID: activeCharacterID)
            ? HumeSpeech()
            : nil
        state = .connecting
        wakeBodyIfStill(reason: "voice start")
        // A reconnect gets a brand-new WebRTC track, which starts enabled.
        micOpen = true
        isPaused = false
        userStoppedSpeakingAt = nil

        wireWorld(behavior: behavior)

        let connectStart = Date()
        if let startedAt { log("connect beginning \(Self.ms(since: startedAt)) after the tap") }
        do {
            try await AudioSessionManager.configureForVoice()
            startLocalAudio()
            let hasBody = behavior?.connected == true
            let secret = try await OpenAIRealtimeMinter.mintEphemeralSecret(
                hasBody: hasBody,
                characterID: activeCharacterID
            )
            sessionHasBody = hasBody
            log(
                "minted secret in \(Self.ms(since: connectStart)) (body: \(hasBody ? "yes" : "none"), voice: \(hume == nil ? "openai" : "hume"))"
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
                    self?.syncBodyAvailability()
                    self?.greetIfNeeded()
                }
            }

            try await client.connect(ephemeralSecret: secret)
            // WebRTC has just taken the audio session for the microphone, which stops this
            // engine; bring it back before Rocky has anything to say.
            RockyAudioEngine.shared.ensureRunning()
            state = .connected
            syncBodyAvailability()
            log("webrtc negotiated in \(Self.ms(since: negotiateStart)), connected in \(Self.ms(since: connectStart)) total")
        } catch {
            state = .failed(error.localizedDescription)
            log("connect failed after \(Self.ms(since: connectStart)): \(error.localizedDescription)")
        }
    }

    // MARK: - Wiring the world

    /// Points the world model at the body, and the salience judge at the data channel.
    private func wireWorld(behavior: BehaviorMonitor?) {
        world.onChange = { [weak self] change in
            self?.worldChanged(change)
        }
        salience.askOutOfBand = { [weak self] ticket, prompt in
            self?.sendSalienceRequest(ticket, prompt)
        }
        behavior?.onBoardMessage = { [weak self] message in
            guard let self else { return }
            self.behaviorSource.handle(message)
            // Connection readiness can precede the board's hello, while BehaviorMonitor still
            // carries the mood from before a power cycle. Re-check the confirmed hello so a newly
            // rebooted still body always wakes during an active conversation.
            if case .hello(_, let mood) = message, mood == "still" {
                self.wakeBodyIfStill(reason: "robot hello")
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
    }

    /// The one place a change in the world becomes a decision about speech. Projection happens
    /// for everything; interrupting almost never does.
    private func worldChanged(_ change: WorldChange) {
        projector.handle(change)
        if case .state(let snapshot) = change,
            let waiting = performanceWaitingForActionId,
            snapshot.action?.id == waiting,
            snapshot.action?.status == .running
        {
            finishPerformanceMovementOnset(actionId: waiting, confirmed: true)
        }
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
            if responseStartedAt != nil {
                interrupt(because: event)
            } else {
                requestResponse(
                    instructions: Self.immediateReactionPrompt(to: event),
                    reason: "reacting immediately to \(event.id)"
                )
            }
        }
    }

    private func currentMoment() -> VoiceMoment {
        VoiceMoment(
            isUttering: responseStartedAt != nil,
            responseId: utteranceResponseId,
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
                requestResponse(
                    instructions: Self.rememberedReactionPrompt(to: event),
                    reason: "remembering \(event.id) after the utterance"
                )
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
        guard responseStartedAt != nil else { return }
        let responseId = utteranceResponseId
        let generatingResponseId = activeResponseId
        log(
            "interrupting \(responseId ?? "local playback") for \(event.id) "
                + "(\(event.kind.rawValue))"
        )

        // Preserve an interleaved story before stopping its players. Their drain callbacks are
        // synchronous, and without this they can advance the performance at the interruption.
        suspendActivePerformance(notifyVoice: true, reason: "body reacted to \(event.id)")

        if let generatingResponseId {
            client.send(ResponseCancelEvent(responseId: generatingResponseId))
            client.send(OutputAudioBufferClearEvent())
        }
        stopLocalAudio()
        hume?.cancel()
        if generatingResponseId != nil, let itemId = currentAssistantItemId, let started = audioStartedAt {
            // Approximate, and honestly so: on WebRTC the exact playback position is not
            // reported, so this is how long audio had been arriving. Erring long would delete
            // words she did say; erring short leaves a fragment she did not. Elapsed-since-first-
            // audio is the closest thing to the truth available here.
            let heard = Int(Date().timeIntervalSince(started) * 1000)
            client.send(ConversationItemTruncateEvent(itemId: itemId, audioEndMs: heard))
        }
        if let responseId {
            WorldLog.shared.closeLedger(responseId, outcome: "interrupted", interruptedBy: event.id)
        }
        speaking = false
        finishResponse(reason: "interrupted by \(event.id)")

        let reaction = (Self.immediateReactionPrompt(to: event), "interrupted by \(event.id)")
        // When generation already ended, only local Hume playback was interrupted. Its queue is
        // empty now, so the reaction can start immediately. A live server response must first
        // acknowledge cancellation or response.create may overtake response.cancel.
        guard let generatingResponseId else {
            requestResponse(instructions: reaction.0, reason: reaction.1)
            return
        }
        parkedRequest = reaction
        cancelWatchdog?.cancel()
        cancelWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            await self?.forceReleaseAfterCancel(generatingResponseId)
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
        if behavior?.stillForVoicePause(id: "voice-paused") == true {
            log("robot moved into still (voice paused)")
        }
        suspendActivePerformance(notifyVoice: false, reason: "voice paused")
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
        wakeBodyIfStill(reason: "voice resume")
        client.setRemoteAudioEnabled(true)
        refreshMicrophone("resumed")
        if let suspendedPerformance {
            self.suspendedPerformance = nil
            queuedPerformance = suspendedPerformance
            log("resumed, continuing the interrupted performance")
            startQueuedPerformance()
        } else {
            log("resumed, asking Rocky for a natural continuation")
            requestResponse(instructions: Self.resumePrompt, reason: "resumed")
        }
    }

    /// Keeps the conversation but changes whether Rocky is offered physical tools. This makes a
    /// robot found after startup or during a pause usable without creating a new voice session.
    func bodyAvailabilityChanged(_ hasBody: Bool) {
        guard state == .connected || state == .paused, sessionHasBody != hasBody,
            let update = OpenAIRealtimeMinter.bodySessionUpdate(
                hasBody: hasBody,
                characterID: activeCharacterID
            )
        else { return }
        guard client.send(jsonObject: update) else {
            log("body capability update waiting for the data channel")
            return
        }
        sessionHasBody = hasBody
        log("body capability updated: \(hasBody ? "connected" : "voice only")")
        if hasBody { wakeBodyIfStill(reason: "robot found") }
    }

    private func syncBodyAvailability() {
        bodyAvailabilityChanged(behavior?.connected == true)
    }

    /// Startup safety belongs to the board; waking for an active conversation belongs here. This
    /// happens before Rocky can choose a gesture, and also when a body arrives after voice did.
    private func wakeBodyIfStill(reason: String) {
        guard state == .connecting || state == .connected,
            behavior?.wakeFromStill(id: "voice-active") == true
        else { return }
        log("robot moved from still to exploring (\(reason))")
    }

    private func endLongPause() {
        guard state == .paused else { return }
        log("paused too long, closing the session")
        disconnect()
    }

    func disconnect() {
        client.close()
        queuedPerformance = nil
        activePerformance = nil
        suspendedPerformance = nil
        cancelPerformanceTiming()
        stopLocalAudio()
        hume?.cancel()
        hume = nil
        humePlayer = nil
        storySounds = nil
        eridian = nil
        humeTextBuffer = ""
        sessionHasBody = nil
        firstAudioWatchdog?.cancel()
        turnWatchdog?.cancel()
        pauseTimeout?.cancel()
        pauseTimeout = nil
        worldTicker?.cancel()
        worldTicker = nil
        responseStartedAt = nil
        utteranceResponseId = nil
        userStoppedSpeakingAt = nil
        micOpen = true
        isPaused = false
        speaking = false
        hasSpokenOnce = false
        state = .disconnected
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
        // The Eridian chord layer belongs to Rocky's Hume voice, not to Realtime-voiced
        // characters such as Fathom.
        eridian = hume == nil ? nil : EridianAudio()
        let effects = StorySoundEffects()
        storySounds = effects
        effects.onFinished = { [weak self] in
            guard self?.activePerformance != nil else { return }
            self?.advancePerformance()
        }
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
        storySounds?.stop()
    }

    /// Barge-in. The server cancels the *response* itself; what it cannot do is stop audio this
    /// app has already queued locally, so that has to happen here or Rocky keeps talking over the
    /// person interrupting her.
    private func handleUserStartedSpeaking() {
        // Clear a performance before stopping its player. `stop()` synchronously reports playback
        // drained; leaving the script active there would advance to the next movement exactly when
        // the person was trying to interrupt it.
        suspendActivePerformance(notifyVoice: true, reason: "friend interrupted")
        // Stop local output before reopening the WebRTC microphone. Reversing these two steps
        // creates a small but repeatable window in which Hume's last queued audio is streamed as
        // if it were the friend's interruption.
        stopLocalAudio()
        hume?.cancel()
        if responseStartedAt != nil { finishResponse(reason: "barge-in") }
    }

    /// Pause is the only reason the microphone track closes. Hume and every local effect now play
    /// through WebRTC's injected voice-processing device, so its AEC removes Rocky while keeping
    /// real nearby speech available to semantic VAD throughout her response.
    private func refreshMicrophone(_ reason: String) {
        let open = Self.microphoneShouldBeOpen(isPaused: isPaused)
        guard micOpen != open else { return }
        micOpen = open
        client.setMicrophoneEnabled(open)
        log("mic \(open ? "open" : "closed") (\(reason))")
    }

    static func microphoneShouldBeOpen(isPaused: Bool) -> Bool {
        !isPaused
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
            return
        }
        self.speaking = false
        // Playback draining is not the same as Rocky being finished: if Hume is still streaming,
        // the queue can empty briefly between chunks. Wait for the chunk Hume marked last before
        // ending the utterance; the microphone itself stays continuously open.
        guard humeSawLastChunk else {
            log("playback drained mid-response, holding the turn open for more audio")
            return
        }
        if activePerformance != nil {
            advancePerformance()
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
        guard hume != nil, !humeUtteranceText.isEmpty else { return }
        firstAudioWatchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.firstAudioTimeout)
            guard !Task.isCancelled else { return }
            await self?.handleMissingFirstAudio()
        }
    }

    private func handleMissingFirstAudio() {
        guard firstAudioAt == nil, !humeUtteranceText.isEmpty else { return }
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
        sendToHume(humeUtteranceText, flush: true)
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
        let words = humeUtteranceText.split(whereSeparator: \.isWhitespace).count
        // A performance's entire script arrives inside function arguments, so it can have no
        // output_text while the model is still validly generating. Give that generation the full
        // ceiling; once a say step begins, the ordinary word-based playback budget takes over.
        let budget = humeUtteranceText.isEmpty
            ? 12_000
            : min(12_000, max(4_000, 2_000 + words * 420))
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
        finishResponse(reason: "turn watchdog")
        stopLocalAudio()
    }

    /// One place where a turn ends, however it ended. The microphone stays open across ordinary
    /// turns and this refresh only matters if pause raced with response completion.
    private func finishResponse(reason: String) {
        firstAudioWatchdog?.cancel()
        firstAudioWatchdog = nil
        turnWatchdog?.cancel()
        turnWatchdog = nil
        responseStartedAt = nil
        utteranceResponseId = nil
        firstTextAt = nil
        firstAudioAt = nil
        audioStartedAt = nil
        responseText = ""
        humeUtteranceText = ""
        utteranceSoFar = ""
        currentAssistantItemId = nil
        humeTextBuffer = ""
        retriedThisResponse = false
        humeSawLastChunk = false
        queuedPerformance = nil
        activePerformance = nil
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
            if responseStartedAt != nil {
                log("speech_started DURING response — semantic VAD barge-in")
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
            projector.flush("user stopped speaking")

        case "response.created":
            activeResponseId = event.response?.id
            utteranceResponseId = event.response?.id
            awaitingResponse = false
            cancelWatchdog?.cancel()
            responseStartedAt = Date()
            retriedThisResponse = false
            humeSawLastChunk = false
            responseText = ""
            humeUtteranceText = ""
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
            // Armed here so a response that never produces text cannot hold the turn forever.
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
            }
        case "response.output_text.done":
            responseText = event.text ?? responseText
            eridian?.flushTranscript()

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
            // The one thing missing when "she talked about the body again" had to be diagnosed:
            // the log knew how many words she said and not which. Everything else here is already
            // recorded against a response id, so her own words belong beside them.
            if !utteranceSoFar.isEmpty { log("said: \(utteranceSoFar)") }

        case "output_audio_buffer.started":
            // WebRTC's own signal that audio is actually leaving for the speaker -- a better
            // clock for "how much did they hear" than the transcript, which runs ahead of it.
            audioStartedAt = Date()

        case "response.done":
            let status = event.response?.status ?? "unknown"
            let toolCalls = event.toolCalls
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
            // unless there was no text, in which case nothing will ever play.
            if hume == nil {
                speaking = false
                finishResponse(reason: "response done")
            } else if toolCalls.isEmpty, !responseText.isEmpty {
                // Hold Hume text until the response shape is known. The model can emit a spoken
                // preamble before a function item; streaming that immediately made movement tools
                // audible as “I will now...” announcements before we knew a tool was coming.
                humeUtteranceText = responseText
                log("said: \(responseText)")
                sendToHume(responseText, flush: true)
                armFirstAudioWatchdog()
                armTurnWatchdog()
            } else if !toolCalls.isEmpty, !responseText.isEmpty {
                log("withheld \(responseText.count)-character tool preamble from speech")
            } else if !toolCalls.contains(where: {
                $0.name == "robot_performance" || $0.name == "resume_robot_performance"
            }) {
                log("response produced no text, nothing to speak — releasing the turn")
                finishResponse(reason: "empty response")
            }
            releaseParkedRequest()

        default:
            // Everything not explicitly handled, minus the high-frequency streaming events. Worth
            // the noise: the turn that failed here did so by way of an event this app never
            // mentioned, which made a 20-second silence look like nothing happening at all.
            // The conversation.item.* echoes are excluded from the prose log: every projection
            // produces one, so at a few per second they would bury the turn timings this log
            // exists for -- and world.jsonl already records each projection with its item id.
            if !event.type.hasSuffix(".delta") && !event.type.hasSuffix(".added")
                && !event.type.hasPrefix("conversation.item.") {
                log("event: \(event.type)")
            }
        }
        // Every tool result first, then exactly one request to speak. A response per call meant a
        // turn with two tool calls asked for two responses, and the second was rejected -- the
        // model had answered, and nothing came out.
        let calls = event.toolCalls
        var performancePrepared = false
        for call in calls {
            guard let name = call.name, let callId = call.call_id else { continue }
            performancePrepared = await performToolCall(
                name: name, argumentsJSON: call.arguments ?? "{}", callId: callId
            ) || performancePrepared
        }
        if !calls.isEmpty {
            if performancePrepared {
                startQueuedPerformance()
            } else {
                requestResponse(
                    instructions: Self.toolFollowupPrompt,
                    reason: "after \(calls.compactMap(\.name).joined(separator: "+"))"
                )
            }
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

    private func performToolCall(name: String, argumentsJSON: String, callId: String) async -> Bool {
        RockyLog.write("tool call: \(name) \(argumentsJSON)")
        WorldLog.shared.write(.tool, "\(name) \(argumentsJSON)", seq: world.seq)
        lastToolCall = name
        let output: String
        do {
            output = try await execute(name: name, argumentsJSON: argumentsJSON, callId: callId)
        } catch {
            log("tool call \(name) failed: \(error.localizedDescription)")
            output = Self.encodeResult(["ok": false, "problem": error.localizedDescription])
        }
        client.send(FunctionCallOutputEvent(callId: callId, output: output))
        return (name == "robot_performance" || name == "resume_robot_performance")
            && queuedPerformance != nil
    }

    private func execute(name: String, argumentsJSON: String, callId: String) async throws -> String {
        let data = Data(argumentsJSON.utf8)
        guard let behavior, behavior.connected else {
            return Self.encodeResult(["ok": false, "problem": "my body isn't with me right now"])
        }

        switch name {
        case "set_robot_mood":
            let args = try JSONDecoder().decode(MoodArgs.self, from: data)
            // Deliberately not an action. How wound up she is has no beginning, middle or end to
            // track. The board itself makes "still" a hard stop and reports the resulting
            // listening transition; registering a second phone-side action would race that truth.
            behaviorSource.expectFeelingChange()
            behavior.setMood(args.mood, id: "mood")
            world.noteFeeling(args.mood)
            return Self.encodeResult(["ok": true])

        case "robot_light":
            let args = try JSONDecoder().decode(LightArgs.self, from: data)
            guard RobotPerformance.supportedLightColors.contains(args.color) else {
                return Self.encodeResult(["ok": false, "problem": "I don't know that color"])
            }
            let durationMs = max(200, min(10_000, args.durationMs))
            behavior.setLight(args.color, durationMs: durationMs, id: callId)
            return Self.encodeResult(["ok": true])

        case "robot_gesture":
            let args = try JSONDecoder().decode(GestureArgs.self, from: data)
            guard let intent = ActionIntent(rawValue: args.gesture), intent.isGesture else {
                return Self.encodeResult(["ok": false, "problem": "I don't know that movement"])
            }
            let times = max(1, min(10, Int(args.times ?? 1)))
            // A deliberate gesture now preempts autonomous movement on receipt. The expected
            // duration remains a bound for calling it lost, never proof that the wheels began.
            let action = world.beginAction(
                intent, expectedDuration: Double(times) * 2.5 + 6, total: times
            )
            behaviorSource.expect(gesture: action.id)
            behavior.requestGesture(args.gesture, times: times, id: action.id)
            world.markAction(action.id, status: .accepted)
            return Self.decided(action)

        case "robot_routine":
            let args = try JSONDecoder().decode(RoutineArgs.self, from: data)
            let moves = Array(args.moves.filter(RobotPerformance.supportedMoves.contains).prefix(8))
            guard moves.count >= 2 else {
                return Self.encodeResult(["ok": false, "problem": "I need at least two valid moves"])
            }
            let action = world.beginAction(
                .routine, expectedDuration: Double(moves.count) * 3.5 + 6, total: moves.count
            )
            behaviorSource.expect(gesture: action.id)
            behavior.requestRoutine(moves, id: action.id)
            world.markAction(action.id, status: .accepted)
            return Self.decided(action)

        case "robot_performance":
            guard hume != nil else {
                return Self.encodeResult([
                    "ok": false, "problem": "this voice cannot play an interleaved performance"
                ])
            }
            let steps = try RobotPerformance.decode(argumentsJSON)
            suspendedPerformance = nil
            queuedPerformance = PerformancePlayback(id: callId, steps: steps)
            return Self.encodeResult(["ok": true])

        case "resume_robot_performance":
            guard let suspendedPerformance else {
                return Self.encodeResult([
                    "ok": false, "problem": "there is no interrupted performance to resume"
                ])
            }
            self.suspendedPerformance = nil
            queuedPerformance = suspendedPerformance
            return Self.encodeResult(["ok": true])

        case "stop_robot":
            let action = world.beginAction(.stop, expectedDuration: 0.3)
            behavior.stopMoving()
            world.markAction(action.id, status: .accepted)
            world.noteDoing(.still, cause: .deliberate)
            world.markAction(action.id, status: .succeeded, evidence: .assumed)
            return Self.decided(action)

        case "get_robot_state":
            return Self.encodeState(world)

        default:
            return Self.encodeResult(["ok": false, "problem": "I don't have that"])
        }
    }

    /// What a movement tool returns, and deliberately all it returns.
    ///
    /// A *decision*, not a receipt and not a job number. `{"success": true}` was read, entirely
    /// reasonably, as "I did it". Its replacement said "accepted -- on its way, not yet happening"
    /// and was read, just as reasonably, as a work queue: the first live session produced
    /// "spinning may start when rolling is done", which is a faithful reading of a pending job
    /// sitting beside a different current motion.
    ///
    /// Both were the same mistake in opposite directions. What a creature has after deciding to
    /// spin is not a completed spin and not a queue position -- it is an intention, and the
    /// natural thing to say is "okay, spinning!". So that is what this returns, and the prompt
    /// says how to speak it.
    private static func decided(_ action: RobotAction) -> String {
        encodeResult(["action_id": action.id, "decided_to": action.intent.word])
    }

    /// Rocky's memory of herself, rendered from the one authoritative store -- the same words the
    /// pushed sensation uses, so asking and being told can never disagree or sound like different
    /// voices.
    private static func encodeState(_ world: WorldStore) -> String {
        let snapshot = world.snapshot
        var now: [String: Any] = ["i_am": snapshot.visibleDoing]
        if snapshot.doing != .still, let because = snapshot.cause.phrase { now["because"] = because }
        if snapshot.blocked { now["something_in_my_way"] = true }
        if snapshot.body != .here { now["out_of_touch"] = true }
        var fields: [String: Any] = ["right_now": now]
        if let feeling = snapshot.feeling { fields["feeling"] = feeling }

        // History, newest first. This is what makes "did that work?" answerable about something
        // that finished a minute ago -- the live picture has long since stopped carrying it, and
        // that is correct: it is a memory now, not a condition.
        fields["i_have_just"] = world.actions.reversed().prefix(5).map { action in
            var entry = WorldProjector.describe(action)
            entry["when"] = WorldWords.ago(Date().timeIntervalSince(action.endedAt ?? action.requestedAt))
            return entry
        }
        fields["happened_to_me"] = world.events.reversed().prefix(5).map { event in
            ["what": event.detail, "when": WorldWords.ago(event.secondsAgo)]
        }

        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else { return encodeResult(["ok": false, "problem": "I can't tell right now"]) }
        return json
    }

    private struct MoodArgs: Decodable {
        let mood: String
    }

    private struct GestureArgs: Decodable {
        let gesture: String
        let times: Double?
    }

    private struct LightArgs: Decodable {
        let color: String
        let durationMs: Int

        enum CodingKeys: String, CodingKey {
            case color
            case durationMs = "duration_ms"
        }
    }

    private struct RoutineArgs: Decodable {
        let moves: [String]
    }

    private func startQueuedPerformance() {
        guard let queued = queuedPerformance else { return }
        queuedPerformance = nil
        activePerformance = queued
        if responseStartedAt == nil { responseStartedAt = Date() }
        responseText = queued.steps.compactMap { step in
            if case .say(let text) = step { return text }
            return nil
        }.joined(separator: " ")
        utteranceSoFar = responseText
        log("performance started with \(queued.steps.count) interleaved steps")
        advancePerformance()
    }

    /// Advances only after the preceding spoken segment has actually drained from the speaker.
    /// Movement is dispatched at that audible boundary, then the next say step begins synthesis
    /// immediately so the body beat fills the small text-to-speech gap instead of creating one.
    private func advancePerformance() {
        firstAudioWatchdog?.cancel()
        turnWatchdog?.cancel()
        humeTextBuffer = ""
        humeSawLastChunk = false

        if var performance = activePerformance {
            performance.currentStepIndex = nil
            activePerformance = performance
        }

        while var performance = activePerformance, performance.nextIndex < performance.steps.count {
            let stepIndex = performance.nextIndex
            let stepNumber = stepIndex + 1
            let step = performance.steps[stepIndex]
            performance.nextIndex += 1

            switch step {
            case .move(let move):
                performance.currentStepIndex = stepIndex
                activePerformance = performance
                if dispatchPerformanceMove(move, performanceId: performance.id, step: stepNumber) {
                    return
                }
            case .sound(let sound):
                performance.currentStepIndex = stepIndex
                activePerformance = performance
                guard let effect = StorySoundEffect(rawValue: sound), let storySounds else { continue }
                log("performance step \(stepNumber) played \(sound)")
                storySounds.play(effect)
                return
            case .light(let color, let durationMs):
                performance.currentStepIndex = stepIndex
                activePerformance = performance
                if let behavior, behavior.connected {
                    behavior.setLight(
                        color, durationMs: durationMs,
                        id: "\(performance.id)-light-\(stepNumber)"
                    )
                    log("performance step \(stepNumber) lit \(color) for \(durationMs)ms")
                } else {
                    log("performance light skipped because the body is away")
                }
            case .say(let text):
                performance.currentStepIndex = stepIndex
                activePerformance = performance
                firstAudioAt = nil
                humeUtteranceText = text
                humePlayer?.beginResponse()
                eridian?.pushTranscriptDelta(text)
                eridian?.flushTranscript()
                log("performance said: \(text)")
                sendToHume(text, flush: true)
                armFirstAudioWatchdog()
                armTurnWatchdog()
                return
            case .pause(let durationMs):
                performance.currentStepIndex = stepIndex
                activePerformance = performance
                log("performance step \(stepNumber) paused \(durationMs)ms")
                performancePauseTask?.cancel()
                let performanceId = performance.id
                performancePauseTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(durationMs))
                    guard !Task.isCancelled else { return }
                    self?.finishPerformancePause(performanceId: performanceId, stepIndex: stepIndex)
                }
                return
            }
        }

        activePerformance = nil
        suspendedPerformance = nil
        cancelPerformanceTiming()
        log("performance finished")
        finishResponse(reason: "performance ended")
    }

    private func suspendActivePerformance(notifyVoice: Bool, reason: String) {
        guard var performance = activePerformance else { return }
        cancelPerformanceTiming()
        performance.nextIndex = RobotPerformance.resumeIndex(
            nextIndex: performance.nextIndex,
            currentStepIndex: performance.currentStepIndex
        )
        performance.currentStepIndex = nil
        activePerformance = nil
        suspendedPerformance = performance
        log("performance paused at step \(performance.nextIndex + 1)/\(performance.steps.count) (\(reason))")

        guard notifyVoice, client.isDataChannelOpen else { return }
        let itemId = "performance_paused_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        client.send(
            ConversationItemCreateEvent(
                id: itemId,
                text: """
                    <performance-paused>The performance was interrupted before step \
                    \(performance.nextIndex + 1) of \(performance.steps.count). Its unheard steps \
                    are held locally. Do not claim it finished.</performance-paused>
                    """
            )
        )
    }

    /// Returns true when playback is waiting for the board to physically begin the movement.
    private func dispatchPerformanceMove(_ move: String, performanceId: String, step: Int) -> Bool {
        guard let behavior, behavior.connected else {
            log("performance movement skipped because the body is away")
            return false
        }
        guard let intent = ActionIntent(rawValue: move), intent.isGesture else {
            log("performance movement skipped because \(move) is unknown")
            return false
        }
        let action = world.beginAction(intent, expectedDuration: 8.5)
        behaviorSource.expect(gesture: action.id)
        behavior.requestGesture(move, id: action.id)
        world.markAction(action.id, status: .accepted)
        log("performance step \(step) moved \(move) (\(performanceId))")
        performanceWaitingForActionId = action.id
        performanceMovementFallback?.cancel()
        performanceMovementFallback = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.finishPerformanceMovementOnset(actionId: action.id, confirmed: false)
        }
        return true
    }

    private func finishPerformanceMovementOnset(actionId: String, confirmed: Bool) {
        guard performanceWaitingForActionId == actionId, activePerformance != nil else { return }
        performanceWaitingForActionId = nil
        performanceMovementFallback?.cancel()
        performanceMovementFallback = nil
        log("performance movement \(confirmed ? "started on robot" : "start wait timed out") (\(actionId))")
        advancePerformance()
    }

    private func finishPerformancePause(performanceId: String, stepIndex: Int) {
        guard activePerformance?.id == performanceId,
            activePerformance?.currentStepIndex == stepIndex
        else { return }
        performancePauseTask = nil
        advancePerformance()
    }

    private func cancelPerformanceTiming() {
        performanceWaitingForActionId = nil
        performanceMovementFallback?.cancel()
        performanceMovementFallback = nil
        performancePauseTask?.cancel()
        performancePauseTask = nil
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
}
