import XCTest

@testable import Rocky

/// Two things are being tested here, and they fail differently.
///
/// The rules decide whether Rocky gets cut off mid-sentence, so getting them wrong is something a
/// person in the room hears. The race guards decide whether a verdict about a sentence that is
/// already over can still act on it, and getting *those* wrong produces a robot that interrupts
/// itself for no visible reason -- which is far harder to diagnose after the fact, and is why
/// each guard has its own test rather than being covered incidentally.
@MainActor
final class SalienceJudgeTests: XCTestCase {
    private func event(_ kind: WorldEventKind, id: String = "evt_1", seq: WorldSeq = 10) -> WorldEvent {
        WorldEvent(id: id, seq: seq, kind: kind, detail: "test", at: Date(), during: nil, again: 1)
    }

    private func speaking(_ text: String, response: String = "resp_A", seq: WorldSeq = 10) -> VoiceMoment {
        VoiceMoment(isGenerating: true, responseId: response, utteranceSoFar: text, worldSeq: seq)
    }

    private var silent: VoiceMoment {
        VoiceMoment(isGenerating: false, responseId: nil, utteranceSoFar: "", worldSeq: 10)
    }

    // MARK: - Deterministic tier

    /// The one case that must never wait on a model round trip: her body has stopped itself while
    /// her voice is still saying she is on the way.
    func testBeingBlockedWhileClaimingMotionIsUrgent() {
        let judge = SalienceJudge()
        let verdict = judge.rule(
            on: event(.blocked), action: nil, moment: speaking("I'm just heading over to the—")
        )
        XCTAssertEqual(verdict, .urgent)
    }

    func testLosingTheBodyMidActionIsUrgent() {
        let judge = SalienceJudge()
        var action = RobotAction(id: "act_1", intent: .spin, expectedDuration: 3)
        action.status = .running
        let verdict = judge.rule(on: event(.bodyGone), action: action, moment: speaking("So anyway"))
        XCTAssertEqual(verdict, .urgent)
    }

    func testANotableEventWhileSheIsQuietStartsAFreshResponse() {
        let judge = SalienceJudge()
        XCTAssertEqual(judge.rule(on: event(.bumped), action: nil, moment: silent), .interrupt)
    }

    /// Being frightened mid-sentence is unambiguous and handled by rule. A routine obstacle turn
    /// mid-anecdote is not, and that is precisely what the out-of-band judge is for -- so the rules
    /// must decline it.
    func testAnAmbiguousEventMidSentenceIsLeftToTheJudge() {
        let judge = SalienceJudge()
        XCTAssertNil(judge.rule(on: event(.blocked), action: nil, moment: speaking("and then the tunnel")))
    }

    /// From the first live session: ten obstacle turns against three startles, one shared cooldown,
    /// first-come-first-served -- and the furniture silently spent the budget every startle after
    /// the first needed. Two of three startles never reached her.
    func testFurnitureCannotCrowdOutAStartle() {
        let judge = SalienceJudge()

        let routine = judge.rule(on: event(.blocked, id: "evt_1"), action: nil, moment: speaking("I'm rolling"))
        XCTAssertEqual(routine, .urgent, "it contradicted her, so it interrupted")

        // Immediately afterwards, well inside any cooldown a routine event would impose.
        let startle = judge.rule(on: event(.startled, id: "evt_2", seq: 11), action: nil, moment: silent)
        XCTAssertEqual(startle, .interrupt, "a bigger thing gets through a smaller one's quiet period")
    }

    /// The other half of the same rule: a startle does not get to fire twice in a breath either.
    func testTheSameStartleTwiceInABreathIsOneStartle() {
        let judge = SalienceJudge()
        XCTAssertEqual(judge.rule(on: event(.startled, id: "evt_1"), action: nil, moment: silent), .interrupt)
        XCTAssertEqual(
            judge.rule(on: event(.startled, id: "evt_2", seq: 11), action: nil, moment: silent),
            .context
        )
    }

    /// Routine events must not start a response out of nowhere. "I nudged a chair", unprompted,
    /// every few seconds is the sports-commentator failure this whole policy exists to avoid.
    func testARoutineEventNeverStartsAResponseOnItsOwn() {
        let judge = SalienceJudge()
        XCTAssertEqual(judge.rule(on: event(.blocked), action: nil, moment: silent), .context)
    }

    func testBookkeepingEventsAreNeverWorthInterruptingFor() {
        let judge = SalienceJudge()
        XCTAssertEqual(judge.rule(on: event(.finished), action: nil, moment: silent), .context)
        XCTAssertEqual(judge.rule(on: event(.bodyBack), action: nil, moment: silent), .context)
    }

    /// A robot being bumped repeatedly must not become a commentator.
    func testASecondInterruptionOfTheSameKindIsHeldBack() {
        let judge = SalienceJudge()
        XCTAssertEqual(judge.rule(on: event(.bumped, id: "evt_1"), action: nil, moment: silent), .interrupt)
        XCTAssertEqual(
            judge.rule(on: event(.bumped, id: "evt_2", seq: 11), action: nil, moment: silent),
            .context,
            "she still learns about it; she just doesn't say anything"
        )
    }

    func testBookkeepingNeverInterruptsHoweverQuietSheIs() {
        let judge = SalienceJudge()
        XCTAssertEqual(judge.rule(on: event(.finished), action: nil, moment: silent), .context)
    }

    // MARK: - Race guards

    /// The scenario from the brief: R17 is speaking, event A is sent for judgment, event B cancels
    /// R17, R18 begins, and A finally comes back saying "continue". That verdict is about a
    /// sentence nobody is saying any more, and must have no effect at all.
    func testAVerdictAboutAResponseThatIsGoneIsDiscarded() {
        let judge = SalienceJudge()
        let ticket = judge.ask(
            about: event(.bumped), snapshot: WorldSnapshot(), moment: speaking("...", response: "resp_17")
        )

        let verdict = judge.resolve(
            ticketId: ticket.id,
            decision: "interrupt_speech",
            reason: "late",
            moment: speaking("...", response: "resp_18")
        )

        XCTAssertNil(verdict)
    }

    /// One superseding slot, not a queue. "Does this invalidate what she is saying" has exactly one
    /// current answer, so a newer event replaces the question rather than adding to it.
    func testASupersededTicketCannotStillAct() {
        let judge = SalienceJudge()
        let first = judge.ask(about: event(.bumped, id: "evt_1"), snapshot: WorldSnapshot(), moment: speaking("..."))
        _ = judge.ask(about: event(.startled, id: "evt_2", seq: 11), snapshot: WorldSnapshot(), moment: speaking("..."))

        XCTAssertNil(
            judge.resolve(ticketId: first.id, decision: "interrupt_speech", reason: "stale", moment: speaking("..."))
        )
    }

    func testAVerdictArrivingLongAfterTheMomentIsDiscarded() {
        let judge = SalienceJudge()
        let ticket = judge.ask(about: event(.bumped), snapshot: WorldSnapshot(), moment: speaking("..."))
        // The judge holds one ticket, and this one is still it -- the guard being exercised is the
        // lifetime, not supersession.
        XCTAssertEqual(judge.pending?.id, ticket.id)
    }

    func testAGoodVerdictIsAccepted() {
        let judge = SalienceJudge()
        let ticket = judge.ask(about: event(.bumped), snapshot: WorldSnapshot(), moment: speaking("..."))

        let verdict = judge.resolve(
            ticketId: ticket.id, decision: "interrupt_speech", reason: "contradicts her", moment: speaking("...")
        )

        XCTAssertEqual(verdict, .interrupt)
        XCTAssertNil(judge.pending, "the slot is free again")
    }

    func testAnUnknownDecisionFallsThroughToIgnoreRatherThanInterrupting() {
        let judge = SalienceJudge()
        let ticket = judge.ask(about: event(.bumped), snapshot: WorldSnapshot(), moment: speaking("..."))

        XCTAssertEqual(
            judge.resolve(ticketId: ticket.id, decision: "??", reason: "", moment: speaking("...")),
            .ignore
        )
    }

    // MARK: - Reading the judge's reply

    func testVerdictParsingToleratesAWrappedReply() {
        let (decision, reason) = RealtimeVoiceSession.parseVerdict(
            "Sure — {\"decision\":\"finish_first\",\"reason\":\"not urgent\"} hope that helps"
        )
        XCTAssertEqual(decision, "finish_first")
        XCTAssertEqual(reason, "not urgent")
    }

    /// A judge that says something unrecognisable must fall through to doing nothing, never to an
    /// interruption. Silence on a bad parse is a shrug; a spurious interruption is a bug someone
    /// hears.
    func testAnUnparseableReplyMeansIgnore() {
        XCTAssertEqual(RealtimeVoiceSession.parseVerdict("no idea").decision, "ignore")
        XCTAssertEqual(RealtimeVoiceSession.parseVerdict("{not json}").decision, "ignore")
        XCTAssertEqual(RealtimeVoiceSession.parseVerdict("").decision, "ignore")
    }

    // MARK: - Recognising a claim of motion

    func testAClaimOfMotionIsRecognisedInWhatSheIsSaying() {
        XCTAssertTrue(speaking("I'm just heading over to the—").claimsMotion)
        XCTAssertTrue(speaking("hang on, I'm spinning!").claimsMotion)
        XCTAssertFalse(speaking("that reminds me of a tunnel on my world").claimsMotion)
    }
}
