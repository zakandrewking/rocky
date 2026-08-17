import XCTest

@testable import Rocky

/// The scenario matrix from apps/ios/docs/embodiment.md, driven through the real store, the real
/// adapter and the real projector.
///
/// These are the cases the whole design exists for -- "are you doing it", "did you do it", "why
/// did you stop" -- and each one asserts on the *text Rocky is actually shown*, not on internal
/// state. That is deliberate: every unit test elsewhere could pass while the one thing that
/// matters, the picture in front of the model, was still wrong or missing.
///
/// Everything a tool call would do is done here by calling the store directly, because that is
/// exactly what RealtimeVoiceSession's tool handler does; everything the *board* would say goes
/// through BehaviorWorldSource, which is the only place the board's vocabulary is understood.
@MainActor
final class EmbodimentScenarioTests: XCTestCase {
    private var store: WorldStore!
    private var channel: RecordingVoiceChannel!
    private var projector: WorldProjector!
    private var behaviour: BehaviorWorldSource!

    override func setUp() {
        super.setUp()
        store = WorldStore()
        channel = RecordingVoiceChannel()
        projector = WorldProjector(store: store, channel: channel)
        store.onChange = { [weak projector] change in projector?.handle(change) }
        behaviour = BehaviorWorldSource(store: store)
        // The board sends a snapshot twice a second, so "sitting still, listening" is the real
        // resting state -- not the never-heard-from `unknown` a bare store starts in.
        behaviour.handle(.snapshot(mode: "listening", mood: "exploring"))
    }

    override func tearDown() {
        store = nil
        channel = nil
        projector = nil
        behaviour = nil
        super.tearDown()
    }

    /// The newest `<robot-state>` -- the only one that counts. Older ones stay in the conversation
    /// (nothing is ever deleted), so every assertion below deliberately reads *this* one rather
    /// than trusting that only one exists.
    private func liveState() throws -> [String: Any] {
        let id = try XCTUnwrap(projector.liveStateItemId, "nothing has been projected")
        let text = try XCTUnwrap(channel.inserted.last { $0.id == id }?.text)
        return try Self.fields(in: text)
    }

    private func iAm(_ state: [String: Any]) -> String? { state["i_am"] as? String }

    /// What the `robot_gesture` tool does, exactly as the session's handler does it.
    @discardableResult
    private func askForSpin(times: Int = 1) -> RobotAction {
        let action = store.beginAction(.spin, expectedDuration: Double(times) * 2.5 + 6, total: times)
        behaviour.expect(gesture: action.id)
        store.markAction(action.id, status: .accepted)
        return action
    }

    // MARK: - Asked for something, but nothing has happened yet

    /// "Are you doing it?" — no. She asked, the board has not got to it, and that gap is real:
    /// this body honours an intention at its own next safe seam, which can be seconds away.
    func testAcceptedButNotStarted() throws {
        askForSpin()
        projector.flush("test")

        let state = try liveState()
        // A decision, not a queue position. This is the shape that produced "spinning may start
        // when rolling is done" when it was a status word sitting beside a different motion.
        XCTAssertEqual(state["about_to"] as? String, "spin")
        XCTAssertNotNil(state["decided"], "how long ago she decided, since nothing has begun")
        XCTAssertNil(state["going_for"])
        XCTAssertNil(state["how_it_is_going"])
        XCTAssertEqual(iAm(state), "sitting still")
    }

    /// The board acknowledging an intention means *heard*, not *doing*. Claiming otherwise here
    /// would be the exact small lie this design exists to prevent.
    func testAnAcknowledgedIntentionIsStillNotHappening() throws {
        let spin = askForSpin()
        behaviour.handle(.acknowledged(of: "gesture", id: spin.id))
        projector.flush("test")

        XCTAssertEqual(store.action(id: spin.id)?.status, .accepted)
        XCTAssertEqual(store.action(id: spin.id)?.evidence, .confirmed, "confirmed it was heard")
        XCTAssertEqual(iAm(try liveState()), "sitting still")
    }

    /// Nothing is ever assumed to have started. Ticking on with no word from the board must not
    /// quietly promote an intention into a movement.
    func testWaitingDoesNotTurnAnIntentionIntoAMovement() {
        let spin = askForSpin()
        for _ in 0..<5 { store.tick() }

        XCTAssertEqual(store.action(id: spin.id)?.status, .accepted)
        XCTAssertFalse(store.snapshot.moving)
    }

    /// "Are you doing it?" — yes, and the body said so.
    func testRunningAndConfirmed() throws {
        askForSpin()
        behaviour.handle(.transition(mode: "turning", detail: "gesture: spin"))
        projector.flush("test")

        let state = try liveState()
        XCTAssertEqual(iAm(state), "spinning")
        XCTAssertEqual(state["because"] as? String, "you asked me to")
        XCTAssertNil(state["about_to"], "it is happening, so there is nothing to be about to do")
    }

    // MARK: - How it ended

    /// "Did you do it?" — the action is gone from the live picture, and the durable fact remains.
    func testSucceeded() throws {
        askForSpin()
        behaviour.handle(.transition(mode: "turning", detail: "gesture: spin"))
        behaviour.handle(.transition(mode: "listening", detail: ""))
        projector.flush("test")

        XCTAssertNil(try liveState()["about_to"], "it is history now, not a condition")
        XCTAssertEqual(iAm(try liveState()), "sitting still")
        let event = try XCTUnwrap(store.events.last)
        XCTAssertEqual(event.kind, .finished)
        XCTAssertTrue(channel.inserted.contains { $0.id == "rw_event_\(event.id)" })
    }

    /// "Why didn't you?" — because the board never found a free moment before the wish expired.
    func testAnIntentionTheBoardNeverGotToFails() throws {
        let spin = askForSpin()
        behaviour.handle(.transition(mode: "listening", detail: "gesture expired: spin"))
        projector.flush("test")

        XCTAssertEqual(store.action(id: spin.id)?.status, .failed)
        let event = try XCTUnwrap(store.events.last)
        XCTAssertEqual(event.kind, .failed)
        XCTAssertEqual(event.during, spin.id)
    }

    /// Repeats are counted from the board's own transitions, so "one of two" is something she
    /// actually knows rather than something timed.
    func testARepeatedGestureIsFollowedThroughToTheEnd() throws {
        let spin = askForSpin(times: 2)
        behaviour.handle(.acknowledged(of: "gesture", id: spin.id))

        behaviour.handle(.transition(mode: "turning", detail: "gesture: spin"))
        XCTAssertEqual(store.action(id: spin.id)?.done, 1)
        behaviour.handle(.transition(mode: "listening", detail: ""))
        XCTAssertEqual(store.action(id: spin.id)?.status, .running, "one of two done, so not finished")

        behaviour.handle(.transition(mode: "turning", detail: "gesture: spin"))
        behaviour.handle(.transition(mode: "listening", detail: ""))
        XCTAssertEqual(store.action(id: spin.id)?.status, .succeeded)
        XCTAssertEqual(store.action(id: spin.id)?.evidence, .confirmed)
    }

    func testAMixedRoutineIsOneCorrelatedAction() {
        let routine = store.beginAction(.routine, expectedDuration: 16, total: 3)
        behaviour.expect(gesture: routine.id)
        store.markAction(routine.id, status: .accepted)
        behaviour.handle(.acknowledged(of: "routine", id: routine.id))

        behaviour.handle(.transition(mode: "turning", detail: "gesture: spin id:\(routine.id) step:1/3"))
        behaviour.handle(.transition(mode: "listening", detail: ""))
        XCTAssertEqual(store.action(id: routine.id)?.done, 1)
        XCTAssertEqual(store.action(id: routine.id)?.status, .running)

        behaviour.handle(.transition(mode: "recovering", detail: "gesture: wiggle id:\(routine.id) step:2/3"))
        behaviour.handle(.transition(mode: "listening", detail: ""))
        behaviour.handle(.transition(mode: "turning", detail: "gesture: spin id:\(routine.id) step:3/3"))
        behaviour.handle(.transition(mode: "listening", detail: ""))

        XCTAssertEqual(store.action(id: routine.id)?.done, 3)
        XCTAssertEqual(store.action(id: routine.id)?.status, .succeeded)
        XCTAssertEqual(store.action(id: routine.id)?.evidence, .confirmed)
    }

    func testAnOldPhysicalMoveCannotBeCreditedToANewerWish() {
        let old = askForSpin()
        let newer = store.beginAction(.wiggle, expectedDuration: 8)
        behaviour.expect(gesture: newer.id)
        store.markAction(newer.id, status: .accepted)

        behaviour.handle(.transition(mode: "turning", detail: "gesture: spin id:\(old.id) step:1/1"))
        behaviour.handle(.transition(mode: "listening", detail: ""))

        XCTAssertEqual(store.action(id: old.id)?.status, .superseded)
        XCTAssertEqual(store.action(id: newer.id)?.status, .accepted)
        XCTAssertEqual(store.action(id: newer.id)?.done, 0)

        behaviour.handle(.transition(mode: "recovering", detail: "gesture: wiggle id:\(newer.id) step:1/1"))
        XCTAssertEqual(store.action(id: newer.id)?.status, .running)
        XCTAssertEqual(store.action(id: newer.id)?.done, 1)
    }

    func testLateGestureAckCannotMoveRunningTruthBackward() {
        let spin = askForSpin()
        behaviour.handle(.transition(mode: "turning", detail: "gesture: spin id:\(spin.id) step:1/1"))

        behaviour.handle(.acknowledged(of: "gesture", id: spin.id))

        XCTAssertEqual(store.action(id: spin.id)?.status, .running)
        XCTAssertEqual(store.action(id: spin.id)?.evidence, .confirmed)
    }

    /// A new instruction while one is live. The snapshot carries only the new one -- there is no
    /// version of this in which Rocky is shown two things she is currently doing.
    func testSupersededByAnotherRequest() throws {
        let spin = askForSpin()
        behaviour.handle(.transition(mode: "turning", detail: "gesture: spin"))
        let wiggle = store.beginAction(.wiggle, expectedDuration: 4)
        projector.flush("test")

        XCTAssertEqual(store.action(id: spin.id)?.status, .superseded)
        XCTAssertEqual(try liveState()["about_to"] as? String, "wiggle")
        XCTAssertEqual(store.snapshot.action?.id, wiggle.id)
    }

    /// A stop cancels rather than supersedes -- "you told me to stop" and "never mind, doing this
    /// instead" are different sentences.
    func testStopCancelsWhateverWasHappening() {
        let spin = askForSpin()
        behaviour.handle(.transition(mode: "turning", detail: "gesture: spin"))
        _ = store.beginAction(.stop, expectedDuration: 0.3)

        XCTAssertEqual(store.action(id: spin.id)?.status, .cancelled)
    }

    func testGoingStillCancelsAnInterruptedGesture() {
        let spin = askForSpin()
        behaviour.handle(.transition(mode: "turning", detail: "gesture: spin"))

        behaviour.handle(.transition(mode: "listening", detail: "still interlock"))

        XCTAssertEqual(store.action(id: spin.id)?.status, .cancelled)
        XCTAssertEqual(store.action(id: spin.id)?.evidence, .confirmed)
        XCTAssertEqual(store.action(id: spin.id)?.reason, "I went still before I finished")
        XCTAssertEqual(store.snapshot.doing, .still)
    }

    // MARK: - The world happening to her

    /// "I tried, but something's in the way." The body stopped itself; nothing she asked for did
    /// this, and the attribution has to survive.
    func testPhysicallyBlocked() throws {
        behaviour.handle(.transition(mode: "driving", detail: ""))
        behaviour.handle(.transition(mode: "turning", detail: "obstacle"))
        projector.flush("test")

        XCTAssertEqual(try liveState()["because"] as? String, "I couldn't help it")
        XCTAssertEqual(store.events.last?.kind, .blocked)
        XCTAssertEqual(store.events.last?.detail, "something got in my way and I had to turn")
    }

    /// "I asked, but I've lost track of my body." Not a failure -- nobody said it failed.
    func testLosingContactMidAction() throws {
        let spin = askForSpin()
        behaviour.handle(.transition(mode: "turning", detail: "gesture: spin"))
        behaviour.handle(.disconnected)
        projector.flush("test")

        XCTAssertEqual(store.action(id: spin.id)?.status, .lost)
        let state = try liveState()
        XCTAssertEqual(iAm(state), "not sure")
        XCTAssertEqual(state["out_of_touch"] as? String, "completely — I cannot feel myself")
    }

    // MARK: - Churn

    /// The robot moves through nine states while Rocky is mid-sentence. Whatever survives in
    /// history, the newest snapshot is the current one and every survivor is strictly older -- so
    /// "highest seq wins" is a max, never a merge, and there is nothing to piece together.
    ///
    /// Not "exactly one", and that is deliberate: deleting a superseded snapshot would rewrite the
    /// cached prefix behind everything said since. See WorldProjector -- this is the invariant
    /// that actually holds, and it is the one the system prompt states.
    func testTheNewestPictureAlwaysWinsHoweverMuchChurnThereWas() throws {
        for mode in ["driving", "settling", "turning", "settling", "listening", "dizzy", "settling", "listening", "driving"] {
            behaviour.handle(.transition(mode: mode, detail: ""))
            projector.flush("test")
        }

        XCTAssertEqual(iAm(try liveState()), "rolling forward")
        let live = try XCTUnwrap(projector.liveStateItemId)
        let seq = { (id: String) in Int(id.replacingOccurrences(of: "rw_state_", with: "")) ?? 0 }
        for survivor in channel.stateItems where survivor != live {
            XCTAssertLessThan(seq(survivor), seq(live), "anything still readable must be older")
        }
    }

    /// Being poked three times in a second is one thing that happened three times, not three
    /// separate reasons to interrupt someone.
    func testABurstOfIdenticalEventsCollapses() {
        behaviour.handle(.transition(mode: "dizzy", detail: "bump"))
        behaviour.handle(.transition(mode: "dizzy", detail: "bump"))
        behaviour.handle(.transition(mode: "dizzy", detail: "bump"))

        let bumps = store.events.filter { $0.kind == .bumped }
        XCTAssertEqual(bumps.count, 1)
        XCTAssertEqual(bumps.first?.again, 3)
    }

    // MARK: - Reading the board's own vocabulary

    /// The board says "dizzy" and "startled". Neither is a word Rocky may use, and the reason for
    /// each is the difference between two quite different sentences -- so the reason has to
    /// survive the translation.
    func testTheBoardsStateNamesBecomeThingsAPersonCouldSay() {
        behaviour.handle(.transition(mode: "dizzy", detail: "bump"))
        XCTAssertEqual(store.snapshot.doing, .spinning)
        XCTAssertEqual(store.snapshot.cause, .reflex)
        XCTAssertEqual(store.events.last?.detail, "something bumped into me")

        behaviour.handle(.transition(mode: "startled", detail: "came close"))
        XCTAssertEqual(store.events.last?.detail, "something came right at me — I jumped and bolted backwards")

        behaviour.handle(.transition(mode: "startled", detail: "loud noise"))
        XCTAssertEqual(store.events.last?.detail, "a sudden loud noise — it made me jump and run")
    }

    /// A spin she asked for, a spin because something bumped it, and driving of its own accord all
    /// look similar on the wire. Telling them apart is what stops Rocky taking credit for a
    /// reflex, or apologising for something she chose.
    func testTheSameMotionIsAttributedDifferently() {
        askForSpin()
        behaviour.handle(.transition(mode: "turning", detail: "gesture: spin"))
        XCTAssertEqual(store.snapshot.cause, .youAsked)

        behaviour.handle(.transition(mode: "dizzy", detail: "bump"))
        XCTAssertEqual(store.snapshot.cause, .reflex)

        behaviour.handle(.transition(mode: "driving", detail: ""))
        XCTAssertEqual(store.snapshot.cause, .onItsOwn)
    }

    private static func fields(in rendered: String) throws -> [String: Any] {
        let start = try XCTUnwrap(rendered.firstIndex(of: "{"))
        let end = try XCTUnwrap(rendered.lastIndex(of: "}"))
        let object = try JSONSerialization.jsonObject(with: Data(String(rendered[start...end]).utf8))
        return try XCTUnwrap(object as? [String: Any])
    }
}
