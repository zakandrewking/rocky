import XCTest

@testable import Rocky

/// A stand-in for the Realtime data channel. The projector is the only thing allowed to put robot
/// facts into the conversation, so recording exactly what it inserts and deletes is enough to
/// test the whole boundary with no WebRTC, no network and no OpenAI account.
@MainActor
final class RecordingVoiceChannel: VoiceChannel {
    var canReachVoice = true
    private(set) var inserted: [(id: String, text: String)] = []
    private(set) var removed: [String] = []

    /// The item ids the conversation actually holds right now.
    var liveItemIds: [String] {
        inserted.map(\.id).filter { !removed.contains($0) }
    }

    var liveStateItems: [String] {
        liveItemIds.filter { $0.hasPrefix("rw_state_") }
    }

    func insertWorldItem(id: String, text: String) {
        inserted.append((id, text))
    }

    func removeWorldItem(id: String) {
        removed.append(id)
    }
}

@MainActor
final class WorldProjectorTests: XCTestCase {
    private func make() -> (WorldStore, RecordingVoiceChannel, WorldProjector) {
        let store = WorldStore()
        let channel = RecordingVoiceChannel()
        let projector = WorldProjector(store: store, channel: channel)
        store.onChange = { [weak projector] change in projector?.handle(change) }
        return (store, channel, projector)
    }

    // MARK: - Supersession

    /// The property everything else rests on. Superseded state is not merely older -- it is gone
    /// from the conversation, so there is no stale snapshot available for a response to read.
    func testOnlyOneStateSnapshotIsEverLive() {
        let (store, channel, projector) = make()
        store.heard()
        store.noteDoing(.spinning, cause: .youAsked)
        projector.flush("test")
        store.noteDoing(.still, cause: .onItsOwn)
        projector.flush("test")
        store.noteBlocked("something was in the way")
        projector.flush("test")

        XCTAssertEqual(channel.liveStateItems.count, 1)
        XCTAssertEqual(channel.liveStateItems.first, projector.liveStateItemId)
        XCTAssertEqual(channel.removed.count, 2, "each new snapshot deletes the one it replaces")
    }

    /// Delete before insert, never after: the other order leaves a window where two snapshots are
    /// both in history, and a response created inside it could read the older one.
    func testTheOldSnapshotIsDeletedBeforeTheNewOneArrives() {
        let (store, channel, projector) = make()
        store.heard()
        store.noteDoing(.spinning, cause: .youAsked)
        projector.flush("first")
        let first = projector.liveStateItemId
        store.noteDoing(.still, cause: .onItsOwn)
        projector.flush("second")

        XCTAssertEqual(channel.removed.first, first)
        XCTAssertEqual(channel.inserted.last?.id, projector.liveStateItemId)
    }

    // MARK: - What crosses the boundary

    /// Telemetry that changes nothing semantic must not reach Rocky. This is the whole answer to
    /// "I don't want speed=.47, speed=.48, speed=.46 in the model's context".
    func testAChangeWithNoSemanticContentIsNotProjected() {
        let (store, channel, projector) = make()
        store.heard()
        store.noteDoing(.rollingForward, cause: .onItsOwn)
        projector.flush("first")
        let countAfterFirst = channel.inserted.count

        store.noteDistance(cm: 41)
        store.noteDistance(cm: 39)
        store.noteDistance(cm: 42)
        projector.flush("again")

        XCTAssertEqual(channel.inserted.count, countAfterFirst, "nothing Rocky could say has changed")
    }

    func testEventsAreProjectedImmediatelyAndNeverDeleted() {
        // The projector has to stay named and alive: WorldStore holds it weakly, so binding it to
        // `_` would deallocate it and every change would quietly go nowhere.
        let (store, channel, projector) = make()
        store.record(.bumped, detail: "something touched me")

        XCTAssertTrue(channel.inserted.contains { $0.id.hasPrefix("rw_event_") })
        XCTAssertTrue(channel.removed.isEmpty)
        withExtendedLifetime(projector) {}
    }

    func testNothingIsProjectedWhenVoiceCannotBeReached() {
        let (store, channel, projector) = make()
        channel.canReachVoice = false
        store.heard()
        store.record(.bumped, detail: "something touched me")
        projector.flush("test")

        XCTAssertTrue(channel.inserted.isEmpty)
    }

    /// Ending a session throws away what voice was told, not what is true. The item ids belonged
    /// to a conversation that no longer exists; the body is exactly where it was.
    func testResetForgetsTheConversationButNotTheWorld() {
        let (store, _, projector) = make()
        store.heard()
        store.noteDoing(.spinning, cause: .youAsked)
        projector.flush("test")

        projector.reset()

        XCTAssertNil(projector.liveStateItemId)
        XCTAssertEqual(store.snapshot.doing, .spinning)
    }

    // MARK: - Rendering

    func testAStateSnapshotIsWholeAndOmitsWhatItDoesNotKnow() throws {
        var snapshot = WorldSnapshot()
        snapshot.seq = 192
        snapshot.body = .here
        snapshot.doing = .spinning
        snapshot.cause = .youAsked

        let rendered = WorldProjector.render(snapshot)
        XCTAssertTrue(rendered.hasPrefix("<robot-state seq=\"192\">"))
        let fields = try Self.fields(in: rendered)

        XCTAssertEqual(fields["doing"] as? String, "spinning")
        XCTAssertEqual(fields["moving"] as? Bool, true)
        XCTAssertEqual(fields["why"] as? String, "you asked")
        // Absent, not false: an omitted field means "not known", and a `nearest_cm: 0` would be a
        // measurement Rocky never took.
        XCTAssertNil(fields["nearest_cm"])
        XCTAssertNil(fields["blocked"])
    }

    /// The load-bearing field. `sure` is what separates "I'm turning" from "I think I'm turning",
    /// and it must be false whenever the body has confirmed nothing.
    func testAnAssumedActionSaysOutLoudThatItIsAssumed() throws {
        var action = RobotAction(id: "act_1", intent: .turn, expectedDuration: 2)
        action.status = .running
        action.evidence = .assumed
        var snapshot = WorldSnapshot()
        snapshot.body = .here
        snapshot.doing = .turning
        snapshot.cause = .youAsked
        snapshot.action = action

        let fields = try Self.fields(in: WorldProjector.render(snapshot))
        let described = try XCTUnwrap(fields["doing_because_you_asked"] as? [String: Any])

        XCTAssertEqual(described["sure"] as? Bool, false)
        XCTAssertEqual(described["how_it_is_going"] as? String, "running")
        XCTAssertEqual(described["trying_to"] as? String, "turn")
    }

    func testIntentAndObservationAreBothPresentWhenTheyDisagree() throws {
        var action = RobotAction(id: "act_1", intent: .driveForward, expectedDuration: 3)
        action.status = .running
        action.evidence = .assumed
        var snapshot = WorldSnapshot()
        snapshot.body = .here
        snapshot.doing = .still
        snapshot.blocked = true
        snapshot.blockedDetail = "something was in the way"
        snapshot.action = action

        let fields = try Self.fields(in: WorldProjector.render(snapshot))

        // "I'm trying to go forward, but something's in my way" needs all three of these at once.
        XCTAssertEqual(fields["moving"] as? Bool, false)
        XCTAssertEqual(fields["blocked"] as? Bool, true)
        XCTAssertEqual(
            (fields["doing_because_you_asked"] as? [String: Any])?["trying_to"] as? String,
            "go forward"
        )
    }

    func testAnEventCarriesItsIdAndWhatItInterrupted() throws {
        let event = WorldEvent(
            id: "evt_31", seq: 193, kind: .bumped, detail: "something touched me",
            at: Date(), during: "act_83", again: 1
        )
        let rendered = WorldProjector.render(event)

        XCTAssertTrue(rendered.contains("id=\"evt_31\""))
        XCTAssertTrue(rendered.contains("when=\"just now\""))
        let fields = try Self.fields(in: rendered)
        XCTAssertEqual(fields["what"] as? String, "bumped")
        XCTAssertEqual(fields["while_doing"] as? String, "act_83")
    }

    private static func fields(in rendered: String) throws -> [String: Any] {
        let start = try XCTUnwrap(rendered.firstIndex(of: "{"))
        let end = try XCTUnwrap(rendered.lastIndex(of: "}"))
        let json = String(rendered[start...end])
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }
}
