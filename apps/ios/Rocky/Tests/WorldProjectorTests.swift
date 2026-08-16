import XCTest

@testable import Rocky

/// A stand-in for the Realtime data channel. The projector is the only thing allowed to put robot
/// facts into the conversation, so recording exactly what it inserts and deletes is enough to
/// test the whole boundary with no WebRTC, no network and no OpenAI account.
@MainActor
final class RecordingVoiceChannel: VoiceChannel {
    var canReachVoice = true
    private(set) var inserted: [(id: String, text: String)] = []

    var stateItems: [String] {
        inserted.map(\.id).filter { $0.hasPrefix("rw_state_") }
    }

    func insertWorldItem(id: String, text: String) {
        inserted.append((id, text))
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

    /// Every projection is a plain append -- nothing is ever removed from the conversation. The
    /// invariant that replaces "exactly one live snapshot" is this one: the newest carries the
    /// highest seq and every survivor is strictly older, so "highest wins" is a max, never a merge.
    func testTheNewestSnapshotOutranksTheOnesBeforeIt() throws {
        let (store, channel, projector) = make()
        store.heard()
        store.noteDoing(.spinning, cause: .youAsked)
        projector.flush("test")
        store.noteDoing(.still, cause: .onItsOwn)
        projector.flush("test")
        store.noteBlocked("something was in the way")
        projector.flush("test")

        XCTAssertEqual(channel.stateItems.count, 3)
        XCTAssertEqual(channel.stateItems.last, projector.liveStateItemId)

        let live = try XCTUnwrap(projector.liveStateItemId)
        for older in channel.stateItems where older != live {
            XCTAssertLessThan(Self.seq(of: older), Self.seq(of: live))
        }
        XCTAssertEqual(
            projector.supersededStateItemIds.count, 2,
            "still in the conversation, and known to be outdated"
        )
    }

    /// Nothing is deleted, ever. Deleting a superseded snapshot would rewrite the cached prefix
    /// behind everything said since -- minutes of audio tokens at full price to remove eighty --
    /// so supersession travels by seq number, which costs nothing.
    func testNothingIsEverRemovedFromTheConversation() {
        let (store, channel, projector) = make()
        store.heard()
        for doing in [Doing.rollingForward, .still, .turning, .still, .spinning, .still] {
            store.noteDoing(doing, cause: .onItsOwn)
            projector.flush("test")
        }
        store.record(.bumped, detail: "something touched me")

        // That there is no way to delete is enforced by the VoiceChannel protocol itself, which
        // has no removal method at all -- so this checks the other half: every snapshot ever
        // projected is still there, under its own id, none reused and none replaced in place.
        XCTAssertEqual(channel.stateItems.count, 6)
        XCTAssertEqual(Set(channel.inserted.map(\.id)).count, channel.inserted.count)
    }

    /// A robot driving for a minute produces no semantic change to project, so the newest snapshot
    /// would still be the one saying "going for 2s". A fresh one is not, though -- and a snapshot
    /// nobody is about to read is not worth the tokens.
    func testAFreshUnchangedSnapshotIsNotRestated() {
        let (store, channel, projector) = make()
        store.heard()
        store.noteDoing(.rollingForward, cause: .onItsOwn)
        projector.flush("first")
        let countAfterFirst = channel.inserted.count

        projector.flush("second")

        XCTAssertEqual(channel.inserted.count, countAfterFirst)
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

        // A repeat of the same semantic picture, arriving three times.
        store.noteDoing(.rollingForward, cause: .onItsOwn)
        store.noteDoing(.rollingForward, cause: .onItsOwn)
        projector.flush("again")

        XCTAssertEqual(channel.inserted.count, countAfterFirst, "nothing Rocky could say has changed")
    }

    func testEventsAreProjectedImmediately() {
        // The projector has to stay named and alive: WorldStore holds it weakly, so binding it to
        // `_` would deallocate it and every change would quietly go nowhere.
        let (store, channel, projector) = make()
        store.record(.bumped, detail: "something touched me")

        XCTAssertTrue(channel.inserted.contains { $0.id.hasPrefix("rw_event_") })
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

    func testASnapshotIsFirstPersonAndOmitsWhatItDoesNotKnow() throws {
        var snapshot = WorldSnapshot()
        snapshot.seq = 192
        snapshot.body = .here
        snapshot.doing = .spinning
        snapshot.cause = .youAsked

        let rendered = WorldProjector.render(snapshot)
        XCTAssertTrue(rendered.hasPrefix("<i-feel seq=\"192\">"))
        let fields = try Self.fields(in: rendered)

        XCTAssertEqual(fields["i_am"] as? String, "spinning")
        XCTAssertEqual(fields["because"] as? String, "you asked me to")
        // Absent, not false: an omitted field means "not known", so a `blocked: false` would be a
        // claim rather than a silence.
        XCTAssertNil(fields["something_in_my_way"])
        XCTAssertNil(fields["feeling"])
        // Naming the body when nothing is wrong with it is what handed her the noun. She refers to
        // herself in the third person the moment a field called `body` is in front of her.
        XCTAssertNil(fields["out_of_touch"])
        XCTAssertFalse(rendered.lowercased().contains("body"))
    }

    /// The exact failure from the first live session: a pending gesture beside a different current
    /// motion read as a work queue, and she said "spinning may start when rolling is done". A
    /// decision is not a queue position, and must not look like one.
    func testADecisionIsNotShownAsAQueuedJob() throws {
        var action = RobotAction(id: "act_7", intent: .spin, expectedDuration: 8)
        action.status = .accepted
        var snapshot = WorldSnapshot()
        snapshot.body = .here
        snapshot.doing = .rollingForward
        snapshot.cause = .onItsOwn
        snapshot.action = action

        let fields = try Self.fields(in: WorldProjector.render(snapshot))

        XCTAssertEqual(fields["i_am"] as? String, "rolling forward")
        XCTAssertEqual(fields["about_to"] as? String, "spin")
        XCTAssertNil(fields["how_it_is_going"], "no status word to narrate")
        XCTAssertNil(fields["sure"])
    }

    /// A spin-three-times really does alternate turning/settling six times in nine seconds. To a
    /// person it is one act, and showing every flip was most of why she sounded like she was
    /// reading a dial: by the time she could speak, the picture was two transitions old.
    func testARepeatedGestureReadsAsOneActWhileItRuns() {
        let (store, channel, projector) = make()
        store.heard()
        let spin = store.beginAction(.spin, expectedDuration: 9, total: 3)
        store.markAction(spin.id, status: .running, evidence: .confirmed)

        for mode in [Doing.turning, .still, .spinning, .turning, .still, .spinning] {
            store.noteDoing(mode, cause: .youAsked)
            projector.flush("test")
        }

        XCTAssertEqual(channel.stateItems.count, 1, "one act, one picture")
        XCTAssertEqual(store.snapshot.visibleDoing, "spinning")
    }

    /// The disagreement case, in the new vocabulary: she has decided to spin, she is not moving,
    /// and something is in the way. All three have to be present and none of them may be a status
    /// word she could read aloud.
    func testWhatSheWantsAndWhatIsHappeningAreBothPresentWhenTheyDisagree() throws {
        var action = RobotAction(id: "act_1", intent: .spin, expectedDuration: 3)
        action.status = .accepted
        var snapshot = WorldSnapshot()
        snapshot.body = .here
        snapshot.doing = .still
        snapshot.blocked = true
        snapshot.action = action

        let fields = try Self.fields(in: WorldProjector.render(snapshot))

        XCTAssertEqual(fields["i_am"] as? String, "sitting still")
        XCTAssertEqual(fields["something_in_my_way"] as? Bool, true)
        XCTAssertEqual(fields["about_to"] as? String, "spin")
    }

    /// An event is a complete first-person sentence, because that is how it will be read. The
    /// action id it happened during stays in the log, where it is a correlation key -- in front of
    /// Rocky "act_83" is a noise she cannot use and might repeat.
    func testAnEventIsAWholeSentenceSheCouldSay() throws {
        let event = WorldEvent(
            id: "evt_31", seq: 193, kind: .bumped, detail: "something bumped into me",
            at: Date(), during: "act_83", again: 1
        )
        let rendered = WorldProjector.render(event)

        XCTAssertTrue(rendered.hasPrefix("<just-happened id=\"evt_31\""))
        XCTAssertTrue(rendered.contains("when=\"just now\""))
        XCTAssertFalse(rendered.contains("act_83"))
        XCTAssertEqual(try Self.fields(in: rendered)["what"] as? String, "something bumped into me")
    }

    private static func seq(of itemId: String) -> Int {
        Int(itemId.replacingOccurrences(of: "rw_state_", with: "")) ?? 0
    }

    private static func fields(in rendered: String) throws -> [String: Any] {
        let start = try XCTUnwrap(rendered.firstIndex(of: "{"))
        let end = try XCTUnwrap(rendered.lastIndex(of: "}"))
        let json = String(rendered[start...end])
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }
}
