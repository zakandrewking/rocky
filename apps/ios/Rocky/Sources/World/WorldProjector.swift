import Foundation

/// The narrow way robot facts reach the Realtime conversation. Implemented by
/// RealtimeVoiceSession; kept as a protocol so the projector can be tested with no WebRTC, no
/// network and no OpenAI account.
@MainActor
protocol VoiceChannel: AnyObject {
    var canReachVoice: Bool { get }
    func insertWorldItem(id: String, text: String)
}

/// Decides what Rocky gets to know, and puts it there.
///
/// This is the boundary the whole design turns on. Everything upstream is telemetry and
/// bookkeeping; everything downstream is a conversation. Three rules do the work:
///
/// - **Full snapshots, never patches.** Every `<robot-state>` is complete. An absent field means
///   "not known", never "unchanged", so there is no accumulation for the model to perform and no
///   way for it to be reading half of one picture and half of another.
/// - **The newest `<robot-state>` is the only one that counts**, carried by its `seq`. Nothing is
///   ever deleted from the conversation. Deleting a superseded snapshot was tried and dropped:
///   prompt caching is exact-prefix, so removing an item that conversation has piled on top of
///   invalidates the cache from its old position and re-charges full price for every audio token
///   since -- minutes of them, to remove eighty. Since every snapshot is whole, "highest seq wins"
///   is a *max* and not a merge, so leaving the old ones in place costs the model no work: they
///   are outranked, and the system prompt says so.
/// - **Semantic transitions only.** Two snapshots that agree on `semanticIdentity` say the same
///   thing about the world, however much telemetry moved underneath them. `speed=.47 → .48` never
///   crosses this line at all.
@MainActor
final class WorldProjector {
    /// State changes closer together than this collapse into one projection. This is also what
    /// makes machine transients invisible: the 180ms motor ring-down between two real states
    /// never gets a projection of its own, because it is gone before the window closes.
    private static let coalesceWindow: Duration = .milliseconds(700)
    /// A snapshot older than this has stale numbers in it -- "going for 2s" about something that
    /// has now been going for a minute -- so the next time a response is about to begin, it gets
    /// restated even though nothing semantic changed.
    private static let goesStaleAfter: TimeInterval = 20

    private weak var channel: VoiceChannel?
    private let store: WorldStore
    private var log: WorldLog { WorldLog.shared }

    private var lastProjectedIdentity: String?
    private var lastProjectedAt: Date?
    private(set) var liveStateItemId: String?
    private(set) var lastProjectedSeq: WorldSeq = 0
    /// Snapshots still sitting in the conversation but outranked by a newer seq. Kept for the
    /// debug view: "when this response began there were three outdated pictures above the current
    /// one" is worth being able to see.
    private(set) var supersededStateItemIds: [String] = []
    private var pendingProjection: Task<Void, Never>?

    init(store: WorldStore, channel: VoiceChannel?) {
        self.store = store
        self.channel = channel
    }

    func attach(_ channel: VoiceChannel) {
        self.channel = channel
    }

    /// Forgets what voice has been told, without touching what is true. Called when a session
    /// ends: the conversation is gone, so every item id in it is gone with it, but the body is
    /// still exactly where it was.
    func reset() {
        pendingProjection?.cancel()
        pendingProjection = nil
        lastProjectedIdentity = nil
        lastProjectedAt = nil
        liveStateItemId = nil
        supersededStateItemIds = []
    }

    // MARK: - Taking changes

    func handle(_ change: WorldChange) {
        switch change {
        case .state:
            scheduleStateProjection()
        case .event(let event):
            // Immediate, unlike state: an event is rare, durable and usually the reason anyone
            // would want to say anything. Delaying one to coalesce it would be saving nothing and
            // costing the moment.
            project(event)
            // Something happening is also the strongest reason to re-state the conditions around
            // it, so the two arrive together and read as one situation.
            scheduleStateProjection()
        }
    }

    /// Puts the current picture in front of voice right now, bypassing coalescing. Used at the
    /// moments where the next thing that happens is a response: the person started speaking, or we
    /// are about to ask for a reply ourselves.
    ///
    /// Restates an *unchanged* world too, if the live snapshot has gone stale. Nothing else covers
    /// that case: a robot that has been driving forward for a minute produces no semantic change
    /// to project, so the newest picture would still be the one saying "going for 2s". Tied to a
    /// response rather than to a timer, because a snapshot nobody is about to read is not worth
    /// the tokens.
    func flush(_ reason: String) {
        pendingProjection?.cancel()
        pendingProjection = nil
        projectState(reason: reason, force: isStale)
    }

    private var isStale: Bool {
        guard store.snapshot.moving || store.liveAction != nil else { return false }
        guard let last = lastProjectedAt else { return false }
        return Date().timeIntervalSince(last) >= Self.goesStaleAfter
    }

    // MARK: - State

    private func scheduleStateProjection() {
        guard pendingProjection == nil else { return }
        pendingProjection = Task { [weak self] in
            try? await Task.sleep(for: Self.coalesceWindow)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.pendingProjection = nil
            self.projectState(reason: "changed", force: false)
        }
    }

    private func projectState(reason: String, force: Bool) {
        guard let channel, channel.canReachVoice else { return }
        let snapshot = store.snapshot
        let identity = snapshot.semanticIdentity
        guard force || identity != lastProjectedIdentity else { return }

        let itemId = "rw_state_\(snapshot.seq)"
        if let previous = liveStateItemId {
            // Outranked, not removed. The new snapshot carries a higher seq and is whole, so the
            // old one is inert -- and every projection is a plain append, which is the shape
            // prompt caching rewards.
            supersededStateItemIds.append(previous)
            if supersededStateItemIds.count > 12 { supersededStateItemIds.removeFirst() }
            log.markSuperseded(item: previous)
        }
        channel.insertWorldItem(id: itemId, text: Self.render(snapshot))

        liveStateItemId = itemId
        lastProjectedIdentity = identity
        lastProjectedSeq = snapshot.seq
        lastProjectedAt = Date()
        log.write(
            .projection,
            "state seq \(snapshot.seq): \(snapshot.doing.word) (\(reason))",
            seq: snapshot.seq,
            action: snapshot.action?.id,
            item: itemId
        )
    }

    private func project(_ event: WorldEvent) {
        guard let channel, channel.canReachVoice else { return }
        let itemId = "rw_event_\(event.id)"
        channel.insertWorldItem(id: itemId, text: Self.render(event))
        log.write(.projection, "event \(event.id) \(event.kind.rawValue)", seq: event.seq, event: event.id, item: itemId)
    }

    // MARK: - Rendering
    //
    // First person, always. This is Rocky's own sensation, not a report about a machine, and the
    // wording is load-bearing rather than cosmetic: the first live session had her saying things
    // like "spinning may start when rolling is done" and describing what "the body" was doing,
    // and both came straight out of what she was being handed. A field literally named `body`
    // gives her the noun; a field named `doing_because_you_asked` holding something that is *not*
    // happening gives her a queue to narrate. She was reading the picture correctly -- the picture
    // was wrong.
    //
    // Tagged, so the boundary between "something Rocky senses" and "something a person said" is
    // unmistakable. The tags are first-person too, because `<robot-state>` contains a word she is
    // forbidden to say and putting it in front of her hundreds of times was asking for trouble.

    static func render(_ snapshot: WorldSnapshot) -> String {
        var fields: [String: Any] = ["i_am": snapshot.visibleDoing]

        if snapshot.doing != .still, let because = snapshot.cause.phrase {
            fields["because"] = because
        }
        if snapshot.blocked { fields["something_in_my_way"] = true }
        if let feeling = snapshot.feeling { fields["feeling"] = feeling }
        // Named only when it is a problem. Saying "here" every time is what gave her the noun.
        switch snapshot.body {
        case .here: break
        case .quiet: fields["out_of_touch"] = "for a moment"
        case .gone: fields["out_of_touch"] = "completely — I cannot feel myself"
        }

        if let action = snapshot.action {
            if action.status.isLive {
                if action.total > 1 { fields["how_many_so_far"] = "\(action.done) of \(action.total)" }
                if let started = action.startedAt {
                    fields["going_for"] = WorldWords.lasting(Date().timeIntervalSince(started))
                }
            } else {
                // Decided, not queued. The difference is the whole complaint: "about to spin" is
                // something a creature says; a status of `accepted` sitting beside a *different*
                // current motion is a work queue, and she narrated it as one.
                fields["about_to"] = action.intent.word
                fields["decided"] = WorldWords.ago(Date().timeIntervalSince(action.requestedAt))
            }
        }
        return "<i-feel seq=\"\(snapshot.seq)\">\n\(json(fields))\n</i-feel>"
    }

    static func render(_ event: WorldEvent) -> String {
        var fields: [String: Any] = ["what": event.detail]
        if event.again > 1 { fields["again"] = event.again }
        let when = WorldWords.ago(event.secondsAgo)
        return "<just-happened id=\"\(event.id)\" seq=\"\(event.seq)\" when=\"\(when)\">\n\(json(fields))\n</just-happened>"
    }

    /// The action, for `get_robot_state` and the debug view -- somewhere a fuller picture is
    /// wanted than the live snapshot carries.
    static func describe(_ action: RobotAction) -> [String: Any] {
        var fields: [String: Any] = ["id": action.id, "what": action.intent.word]
        fields["how_it_went"] = action.status.isLive ? "happening now" : action.status.rawValue
        if action.total > 1 { fields["how_many"] = "\(action.done) of \(action.total)" }
        if let started = action.startedAt {
            fields["going_for"] = WorldWords.lasting(Date().timeIntervalSince(started))
        } else {
            fields["decided"] = WorldWords.ago(Date().timeIntervalSince(action.requestedAt))
        }
        if let reason = action.reason { fields["because"] = reason }
        return fields
    }

    private static func json(_ fields: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
}
