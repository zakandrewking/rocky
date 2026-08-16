import XCTest

@testable import Rocky

/// The store's job is to be the one place that is right about the body. These are the properties
/// that have to hold for anything downstream -- the projection, the salience policy, what Rocky
/// actually says -- to be trustworthy. No device, no network, no OpenAI account.
@MainActor
final class WorldStoreTests: XCTestCase {
    private func makeStore() -> WorldStore { WorldStore() }

    // MARK: - Actions

    func testATerminalActionCannotBeResurrected() {
        let store = makeStore()
        let action = store.beginAction(.spin, expectedDuration: 2)
        store.markAction(action.id, status: .lost, reason: "never heard back")

        // The ack the board sent five seconds too late.
        store.markAction(action.id, status: .succeeded, evidence: .confirmed)

        XCTAssertEqual(store.action(id: action.id)?.status, .lost)
    }

    func testANewInstructionSupersedesTheLiveOneButAStopCancelsIt() {
        let store = makeStore()
        let first = store.beginAction(.driveForward, expectedDuration: 3)
        store.markAction(first.id, status: .running, evidence: .assumed)

        _ = store.beginAction(.turn, expectedDuration: 1)
        XCTAssertEqual(store.action(id: first.id)?.status, .superseded)

        let second = store.beginAction(.driveForward, expectedDuration: 3)
        store.markAction(second.id, status: .running, evidence: .assumed)
        _ = store.beginAction(.stop, expectedDuration: 0.3)
        XCTAssertEqual(store.action(id: second.id)?.status, .cancelled)
    }

    /// Only the *live* action rides in the snapshot. Once it is over it is history, and history
    /// lives in events, where nothing can supersede it away.
    func testAFinishedActionLeavesTheSnapshotAndBecomesAnEvent() {
        let store = makeStore()
        let action = store.beginAction(.spin, expectedDuration: 2)
        XCTAssertEqual(store.snapshot.action?.id, action.id)

        store.markAction(action.id, status: .succeeded, evidence: .confirmed)

        XCTAssertNil(store.snapshot.action)
        XCTAssertEqual(store.events.last?.kind, .finished)
        XCTAssertEqual(store.events.last?.during, action.id)
    }

    /// Supersession and cancellation are bookkeeping, not things that happened to the robot. If
    /// they produced events, every command Rocky changed her mind about would leave a permanent
    /// "something happened" she might narrate.
    func testSupersessionIsNotAnEvent() {
        let store = makeStore()
        _ = store.beginAction(.driveForward, expectedDuration: 3)
        _ = store.beginAction(.turn, expectedDuration: 1)

        XCTAssertTrue(store.events.isEmpty)
    }

    /// The deadline is generous on purpose: declaring an action lost early costs Rocky saying she
    /// doesn't know something she does. `tick()` is a one-liner over this, so this is where the
    /// decision is worth pinning down.
    func testWhenAnActionIsConsideredOverdue() {
        var fresh = RobotAction(id: "a", intent: .driveForward, expectedDuration: 3)
        fresh.status = .running
        XCTAssertFalse(fresh.isOverdue)

        // Twice the estimate plus two seconds of slack: a 3s drive has until 8s.
        var late = RobotAction(
            id: "b", intent: .driveForward, expectedDuration: 3, at: Date().addingTimeInterval(-9)
        )
        late.status = .running
        XCTAssertTrue(late.isOverdue)

        var finished = RobotAction(
            id: "c", intent: .driveForward, expectedDuration: 3, at: Date().addingTimeInterval(-9)
        )
        finished.status = .succeeded
        XCTAssertFalse(finished.isOverdue, "something already settled can never go overdue")
    }

    // MARK: - The link

    func testLosingTheBodyLosesTheActionRatherThanFailingIt() {
        let store = makeStore()
        store.heard()
        let action = store.beginAction(.driveForward, expectedDuration: 5)
        store.markAction(action.id, status: .running, evidence: .assumed)

        store.linkLost("wifi dropped")

        XCTAssertEqual(store.action(id: action.id)?.status, .lost)
        XCTAssertEqual(store.snapshot.body, .gone)
        XCTAssertEqual(store.snapshot.doing, .unknown, "with no contact, nothing is known about motion")
        XCTAssertTrue(store.events.contains { $0.kind == .bodyGone })
    }

    func testHearingFromABodyThatWasGoneIsItselfNews() {
        let store = makeStore()
        store.heard()
        store.linkLost("wifi dropped")
        store.heard()

        XCTAssertEqual(store.snapshot.body, .here)
        XCTAssertEqual(store.events.last?.kind, .bodyBack)
    }

    // MARK: - Events

    func testIdenticalEventsInQuickSuccessionCollapse() {
        let store = makeStore()
        store.record(.bumped, detail: "something touched me")
        store.record(.bumped, detail: "something touched me")
        store.record(.bumped, detail: "something touched me")

        XCTAssertEqual(store.events.count, 1, "being poked three times is one thing happening thrice")
        XCTAssertEqual(store.events.last?.again, 3)
    }

    func testDifferentEventsDoNotCollapse() {
        let store = makeStore()
        store.record(.bumped, detail: "something touched me")
        store.record(.startled, detail: "a sudden loud noise")

        XCTAssertEqual(store.events.count, 2)
    }

    // MARK: - Sequence

    func testEverySortOfMutationAdvancesTheWorldSequence() {
        let store = makeStore()
        let start = store.seq

        store.noteDoing(.spinning, cause: .youAsked)
        let afterState = store.seq
        store.record(.bumped, detail: "something touched me")
        let afterEvent = store.seq
        _ = store.beginAction(.spin, expectedDuration: 1)

        XCTAssertGreaterThan(afterState, start)
        XCTAssertGreaterThan(afterEvent, afterState)
        XCTAssertGreaterThan(store.seq, afterEvent)
    }

    /// `moving` describes the body, and `action.status` describes the instruction. Nothing an
    /// action claims may reach through and change what the body is reported to be doing --
    /// otherwise "I'm trying to move but I don't think I'm going anywhere" becomes unsayable.
    func testIntentCannotMakeTheSnapshotClaimMotion() {
        let store = makeStore()
        let action = store.beginAction(.driveForward, expectedDuration: 3)
        store.markAction(action.id, status: .running, evidence: .assumed)
        store.noteBlocked("something was in the way")

        XCTAssertFalse(store.snapshot.moving)
        XCTAssertTrue(store.snapshot.blocked)
        XCTAssertEqual(store.snapshot.action?.status, .running)
    }
}
