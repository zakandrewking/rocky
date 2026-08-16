import XCTest

@testable import Rocky

/// The scenario matrix from apps/ios/docs/embodiment.md, driven through the real store, the real
/// adapters and the real projector.
///
/// These are the cases the whole design exists for -- "are you doing it", "did you do it", "why
/// did you stop" -- and each one asserts on the *text Rocky is actually shown*, not on internal
/// state. That is deliberate: every unit test elsewhere could pass while the one thing that
/// matters, the picture in front of the model, was still wrong or missing.
@MainActor
final class EmbodimentScenarioTests: XCTestCase {
    private var store: WorldStore!
    private var channel: RecordingVoiceChannel!
    private var projector: WorldProjector!
    private var motion: MotionWorldSource!
    private var behaviour: BehaviorWorldSource!

    override func setUp() {
        super.setUp()
        store = WorldStore()
        channel = RecordingVoiceChannel()
        projector = WorldProjector(store: store, channel: channel)
        store.onChange = { [weak projector] change in projector?.handle(change) }
        motion = MotionWorldSource(store: store)
        behaviour = BehaviorWorldSource(store: store)
        store.heard()
    }

    override func tearDown() {
        store = nil
        channel = nil
        projector = nil
        motion = nil
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

    private func action(in state: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(state["doing_because_you_asked"] as? [String: Any])
    }

    // MARK: - Asked to spin, but nothing has happened yet

    /// "Are you doing it?" — no. She asked, and that is all she knows.
    func testAcceptedButNotStarted() throws {
        let spin = store.beginAction(.spin, expectedDuration: 3)
        store.markAction(spin.id, status: .accepted)
        projector.flush("test")

        let described = try action(in: try liveState())
        XCTAssertEqual(described["how_it_is_going"] as? String, "accepted")
        XCTAssertEqual(described["sure"] as? Bool, false)
        XCTAssertNotNil(described["asked"], "how long ago she asked, since nothing has begun")
        XCTAssertNil(described["going_for"])
        XCTAssertEqual(try liveState()["moving"] as? Bool, false)
    }

    /// "Are you doing it?" — yes, and the body said so.
    func testRunningAndConfirmed() throws {
        let spin = store.beginAction(.spin, expectedDuration: 3)
        store.markAction(spin.id, status: .accepted)
        motion.expect(.spin)
        motion.handle(.started(actionId: spin.id))
        projector.flush("test")

        let state = try liveState()
        XCTAssertEqual(state["doing"] as? String, "spinning")
        XCTAssertEqual(state["moving"] as? Bool, true)
        XCTAssertEqual(state["why"] as? String, "you asked")
        XCTAssertEqual(try action(in: state)["sure"] as? Bool, true)
    }

    /// The middle ground, and the reason `evidence` exists: an older board sends no `started`, so
    /// after a beat this is believed rather than known -- and says so.
    func testRunningButOnlyAssumed() throws {
        let drive = store.beginAction(.driveForward, expectedDuration: 3)
        store.markAction(drive.id, status: .running, evidence: .assumed)
        motion.expect(.driveForward)
        projector.flush("test")

        XCTAssertEqual(try action(in: try liveState())["sure"] as? Bool, false)
        XCTAssertEqual(try liveState()["moving"] as? Bool, true)
    }

    // MARK: - How it ended

    /// "Did you do it?" — the action is gone from the live picture, and the durable fact remains.
    func testSucceeded() throws {
        let spin = store.beginAction(.spin, expectedDuration: 2)
        motion.expect(.spin)
        motion.handle(.started(actionId: spin.id))
        motion.handle(.succeeded(actionId: spin.id))
        projector.flush("test")

        XCTAssertNil(try liveState()["doing_because_you_asked"], "it is history now, not a condition")
        XCTAssertEqual(try liveState()["moving"] as? Bool, false)
        let event = try XCTUnwrap(store.events.last)
        XCTAssertEqual(event.kind, .finished)
        XCTAssertTrue(channel.inserted.contains { $0.id == "rw_event_\(event.id)" })
    }

    /// "Why did you stop?" — because the body refused it before it ever began.
    func testFailedBeforeStarting() throws {
        let drive = store.beginAction(.driveForward, expectedDuration: 3)
        store.markAction(drive.id, status: .accepted)
        motion.handle(.failed(actionId: drive.id, reason: "my body was already doing something"))
        projector.flush("test")

        XCTAssertEqual(store.action(id: drive.id)?.status, .failed)
        let event = try XCTUnwrap(store.events.last)
        XCTAssertEqual(event.kind, .failed)
        XCTAssertEqual(event.detail, "my body was already doing something")
        XCTAssertEqual(event.during, drive.id)
    }

    /// "I'm trying to go forward, but something's in my way." All three facts, disagreeing, in one
    /// snapshot -- intent still running, body not moving, way not clear.
    func testPhysicallyBlocked() throws {
        let drive = store.beginAction(.driveForward, expectedDuration: 4)
        motion.expect(.driveForward)
        motion.handle(.started(actionId: drive.id))
        motion.handle(.blocked(actionId: drive.id, reason: "something was in the way"))
        projector.flush("test")

        let state = try liveState()
        XCTAssertEqual(state["moving"] as? Bool, false)
        XCTAssertEqual(state["blocked"] as? Bool, true)
        XCTAssertEqual(state["in_the_way"] as? String, "something was in the way")
        XCTAssertEqual(store.events.last?.kind, .blocked)
    }

    /// A new instruction while one is live. The snapshot carries only the new one -- there is no
    /// version of this in which Rocky is shown two things she is currently doing.
    func testSupersededByAnotherRequest() throws {
        let spin = store.beginAction(.spin, expectedDuration: 4)
        store.markAction(spin.id, status: .running, evidence: .assumed)
        let turn = store.beginAction(.turn, expectedDuration: 1)
        projector.flush("test")

        XCTAssertEqual(store.action(id: spin.id)?.status, .superseded)
        XCTAssertEqual(try action(in: try liveState())["id"] as? String, turn.id)
    }

    // MARK: - Contact

    /// "I sent it, but I've lost track of my body." Not a failure -- nobody said it failed.
    func testLosingContactMidAction() throws {
        let drive = store.beginAction(.driveForward, expectedDuration: 5)
        motion.expect(.driveForward)
        motion.handle(.started(actionId: drive.id))
        motion.handle(.gone("wifi dropped"))
        projector.flush("test")

        XCTAssertEqual(store.action(id: drive.id)?.status, .lost)
        let state = try liveState()
        XCTAssertEqual(state["body"] as? String, "gone")
        XCTAssertEqual(state["doing"] as? String, "not sure")
        XCTAssertEqual(state["moving"] as? Bool, false)
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

        XCTAssertEqual(try liveState()["doing"] as? String, "rolling forward")
        let live = try XCTUnwrap(projector.liveStateItemId)
        let seq = { (id: String) in Int(id.replacingOccurrences(of: "rw_state_", with: "")) ?? 0 }
        for survivor in channel.stateItems where survivor != live {
            XCTAssertLessThan(seq(survivor), seq(live), "anything still readable must be older")
        }
    }

    /// Being poked three times in a second is one thing that happened three times, not three
    /// separate reasons to interrupt someone.
    func testABurstOfIdenticalEventsCollapses() throws {
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
        XCTAssertEqual(store.events.last?.detail, "something touched me")

        behaviour.handle(.transition(mode: "startled", detail: "came close"))
        XCTAssertEqual(store.events.last?.detail, "something came at me")

        behaviour.handle(.transition(mode: "startled", detail: "loud noise"))
        XCTAssertEqual(store.events.last?.detail, "a sudden loud noise")
    }

    /// A turn she asked for and a turn the robot made to avoid a wall look identical on the wire.
    /// Telling them apart is what stops Rocky taking credit for a reflex.
    func testTheSameMotionIsAttributedDifferently() {
        behaviour.handle(.transition(mode: "turning", detail: "gesture: spin"))
        XCTAssertEqual(store.snapshot.cause, .youAsked)

        behaviour.handle(.transition(mode: "turning", detail: "obstacle"))
        XCTAssertEqual(store.snapshot.cause, .reflex)
        XCTAssertEqual(store.events.last?.kind, .blocked)

        behaviour.handle(.transition(mode: "driving", detail: ""))
        XCTAssertEqual(store.snapshot.cause, .onItsOwn)
    }

    /// A gesture's whole life, correlated by the id the board echoes back rather than by timing.
    func testAGestureIsFollowedFromIntentionToDone() throws {
        let spin = store.beginAction(.spin, expectedDuration: 8, total: 2)
        behaviour.expect(gesture: spin.id)
        store.markAction(spin.id, status: .accepted)

        behaviour.handle(.acknowledged(of: "gesture", id: spin.id))
        XCTAssertEqual(store.action(id: spin.id)?.evidence, .confirmed, "heard, not yet happening")
        XCTAssertEqual(store.action(id: spin.id)?.status, .accepted)

        behaviour.handle(.transition(mode: "turning", detail: "gesture: spin"))
        XCTAssertEqual(store.action(id: spin.id)?.status, .running)
        XCTAssertEqual(store.action(id: spin.id)?.done, 1)

        behaviour.handle(.transition(mode: "listening", detail: ""))
        XCTAssertEqual(store.action(id: spin.id)?.status, .running, "one of two done, so not finished")

        behaviour.handle(.transition(mode: "turning", detail: "gesture: spin"))
        behaviour.handle(.transition(mode: "listening", detail: ""))
        XCTAssertEqual(store.action(id: spin.id)?.status, .succeeded)
        XCTAssertEqual(store.action(id: spin.id)?.evidence, .confirmed)
    }

    func testAGestureTheBoardNeverFoundTimeForFails() {
        let spin = store.beginAction(.spin, expectedDuration: 8)
        behaviour.expect(gesture: spin.id)
        store.markAction(spin.id, status: .accepted)

        behaviour.handle(.transition(mode: "listening", detail: "gesture expired: spin"))

        XCTAssertEqual(store.action(id: spin.id)?.status, .failed)
        XCTAssertEqual(store.events.last?.kind, .failed)
    }

    private static func fields(in rendered: String) throws -> [String: Any] {
        let start = try XCTUnwrap(rendered.firstIndex(of: "{"))
        let end = try XCTUnwrap(rendered.lastIndex(of: "}"))
        let object = try JSONSerialization.jsonObject(with: Data(String(rendered[start...end]).utf8))
        return try XCTUnwrap(object as? [String: Any])
    }
}
