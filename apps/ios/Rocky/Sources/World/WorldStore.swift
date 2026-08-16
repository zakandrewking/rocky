import Foundation

/// What just changed, handed to whoever is listening. Two cases, matching the two record types --
/// there is no third kind of thing that can happen to the world.
enum WorldChange: Sendable {
    case state(WorldSnapshot)
    case event(WorldEvent)
}

/// The authoritative picture of Rocky's body. **The conversation is not the database; this is.**
///
/// Everything that knows anything about the robot writes here -- the motion agent's acks, the
/// behaviour loop's transitions, the link watchdog, and Rocky's own tool calls -- and everything
/// downstream (the projection into voice, the salience policy, the debug view, `get_robot_state`)
/// reads from here and nowhere else. That is the whole point: one place holds the truth, and the
/// model gets a curated view of it rather than being handed the raw feed and asked to reconstruct
/// its own embodiment.
///
/// The store never talks to the Realtime API. It does not know voice exists. Deciding what is
/// worth telling her is `WorldProjector`'s job, and keeping those separate is what stops "the
/// robot did something" and "Rocky should say something" from becoming the same event.
@MainActor
final class WorldStore: ObservableObject {
    /// How long since we last heard anything before the body counts as quiet, then gone.
    private static let quietAfter: TimeInterval = 3
    private static let goneAfter: TimeInterval = 10
    /// Identical events closer together than this collapse into one with a repeat count.
    private static let repeatWindow: TimeInterval = 3

    @Published private(set) var snapshot = WorldSnapshot()
    @Published private(set) var events: [WorldEvent] = []
    /// Newest last. Bounded, because this is a live memory of the last few minutes, not an audit
    /// trail -- `world.jsonl` is the audit trail.
    @Published private(set) var actions: [RobotAction] = []

    /// Fired after every mutation, once the store is already consistent.
    var onChange: ((WorldChange) -> Void)?

    private(set) var seq: WorldSeq = 0
    private var nextActionNumber = 0
    private var nextEventNumber = 0
    private var lastHeardFrom: Date?
    private var linkUp = false
    /// Whether contact has ever been lost. First contact is not news -- announcing "my body is
    /// back" at the start of every session would be Rocky reacting to her own boot.
    private var hasBeenLost = false

    private static let maxEvents = 40
    private static let maxActions = 24

    private var log: WorldLog { WorldLog.shared }

    // MARK: - Reading

    var liveAction: RobotAction? {
        actions.last { !$0.status.isTerminal }
    }

    func action(id: String) -> RobotAction? {
        actions.last { $0.id == id }
    }

    var mostRecentEvent: WorldEvent? { events.last }

    // MARK: - The link

    /// Called whenever anything at all arrives from the body. Presence is derived from this and
    /// never asserted directly, so there is no path where the robot is described as present
    /// because some other flag was left set.
    func heard() {
        lastHeardFrom = Date()
        if !linkUp {
            linkUp = true
            log.write(.link, "body back", seq: seq + 1)
            commit { $0.body = .here }
            if hasBeenLost { record(.bodyBack, detail: "my body is back") }
        } else {
            refreshPresence()
        }
    }

    func linkLost(_ reason: String) {
        guard linkUp else { return }
        linkUp = false
        hasBeenLost = true
        lastHeardFrom = nil
        log.write(.link, "body gone: \(reason)", seq: seq + 1)
        // Anything in flight is now unknowable, not failed. Doing this before the state change so
        // the snapshot that goes out already carries the honest action status.
        if let live = liveAction {
            markAction(live.id, status: .lost, reason: "I lost track of my body")
        }
        commit {
            $0.body = .gone
            $0.doing = .unknown
            $0.cause = .unknown
        }
        record(.bodyGone, detail: reason)
    }

    /// Recomputes presence and ages out actions whose outcome will now never arrive. Driven by a
    /// timer rather than by incoming traffic, because the interesting case here is precisely the
    /// one where nothing is arriving.
    func tick() {
        refreshPresence()
        guard let live = liveAction else { return }
        // Nothing is ever assumed to have started. The board honours an intention at its own next
        // safe seam and reports the transition when it does, so an accepted gesture that has not
        // been reported is genuinely not happening yet -- and saying otherwise would be inventing
        // the one thing this whole design exists to avoid. (The deprecated motion agent was the
        // opposite: it began immediately and never said so, which is what `assumed` was for.)
        guard live.isOverdue else { return }
        markAction(live.id, status: .lost, reason: "I never felt it happen")
    }

    private func refreshPresence() {
        let presence: BodyPresence
        switch lastHeardFrom.map({ Date().timeIntervalSince($0) }) {
        case .some(let age) where age < Self.quietAfter: presence = .here
        case .some(let age) where age < Self.goneAfter: presence = .quiet
        case .some: presence = .gone
        case .none: presence = linkUp ? .here : .gone
        }
        guard presence != snapshot.body else { return }
        commit { $0.body = presence }
    }

    // MARK: - Conditions

    func noteDoing(_ doing: Doing, cause: DoingCause) {
        guard snapshot.doing != doing || snapshot.cause != cause else { return }
        commit {
            $0.doing = doing
            $0.cause = cause
            // Clearing on any motion change rather than requiring an explicit unblock: "blocked"
            // describes an attempt that is over the moment the body does something else, and a
            // stale `blocked: true` is exactly the kind of thing Rocky would say out loud.
            if doing != .still { $0.blocked = false; $0.blockedDetail = nil }
        }
    }

    func noteBlocked(_ detail: String) {
        commit {
            $0.blocked = true
            $0.blockedDetail = detail
            $0.doing = .still
        }
    }

    func noteFeeling(_ feeling: String) {
        guard snapshot.feeling != feeling else { return }
        commit { $0.feeling = feeling }
    }

    // MARK: - Actions

    /// Registers an intent. Returns immediately -- nothing here waits on the body, which is the
    /// point: a tool call registers what Rocky *asked for*, and the outcome arrives later as its
    /// own truth.
    @discardableResult
    func beginAction(_ intent: ActionIntent, expectedDuration: TimeInterval, total: Int = 1) -> RobotAction {
        // A new instruction ends whatever was live. A stop *cancels* what was happening; anything
        // else replaces it. Two different words because they make different sentences true --
        // "you told me to stop" versus "never mind that, doing this instead".
        if let live = liveAction {
            markAction(live.id, status: intent == .stop ? .cancelled : .superseded, silent: true)
        }
        nextActionNumber += 1
        let action = RobotAction(
            id: "act_\(nextActionNumber)",
            intent: intent,
            expectedDuration: expectedDuration,
            total: total
        )
        actions.append(action)
        if actions.count > Self.maxActions { actions.removeFirst(actions.count - Self.maxActions) }
        log.write(.action, "\(action.id) \(intent.word) requested", seq: seq + 1, action: action.id)
        commit { $0.action = action }
        return action
    }

    func markAction(
        _ id: String,
        status: ActionStatus,
        evidence: ActionEvidence? = nil,
        reason: String? = nil,
        done: Int? = nil,
        silent: Bool = false
    ) {
        guard let index = actions.lastIndex(where: { $0.id == id }) else { return }
        var action = actions[index]
        guard action.status != status || evidence != nil || done != nil else { return }
        // Terminal is terminal. Late traffic about a finished action must not resurrect it --
        // an ack that arrives after we already gave up would otherwise flip `lost` back to
        // `succeeded` and make Rocky claim knowledge she reached by accident.
        guard !action.status.isTerminal else { return }

        action.status = status
        if let evidence { action.evidence = evidence }
        if let reason { action.reason = reason }
        if let done { action.done = done }
        if status.isLive, action.startedAt == nil { action.startedAt = Date() }
        if status.isTerminal { action.endedAt = Date() }
        actions[index] = action

        log.write(
            .action,
            "\(id) \(action.intent.word) → \(status.rawValue) (\(action.evidence.rawValue))"
                + (reason.map { ": \($0)" } ?? ""),
            seq: seq + 1,
            action: id
        )

        commit { snapshot in
            // Only the live action rides in the snapshot. A finished one is history, and history
            // belongs in events, where it cannot be superseded away.
            if status.isTerminal {
                if snapshot.action?.id == id { snapshot.action = nil }
            } else {
                snapshot.action = action
            }
        }

        guard !silent else { return }
        switch status {
        case .succeeded:
            record(.finished, detail: "\(action.intent.word) — done", during: id)
        case .blocked:
            record(.blocked, detail: reason ?? "something was in the way", during: id)
        case .failed, .lost:
            record(.failed, detail: reason ?? "it didn't work", during: id)
        default:
            break
        }
    }

    // MARK: - Events

    @discardableResult
    func record(_ kind: WorldEventKind, detail: String, during: String? = nil) -> WorldEvent {
        // A body being poked repeatedly is one thing happening several times, not several things.
        // Collapsing here rather than in the projector means the store's own history reads the
        // way Rocky would describe it, and `get_robot_state` inherits it for free.
        if var last = events.last,
            last.kind == kind, last.detail == detail, last.secondsAgo < Self.repeatWindow {
            last.again += 1
            events[events.count - 1] = last
            seq += 1
            log.write(.event, "\(kind.rawValue) ×\(last.again)", seq: seq, action: during, event: last.id)
            onChange?(.event(last))
            return last
        }

        nextEventNumber += 1
        seq += 1
        let event = WorldEvent(
            id: "evt_\(nextEventNumber)",
            seq: seq,
            kind: kind,
            detail: detail,
            at: Date(),
            during: during,
            again: 1
        )
        events.append(event)
        if events.count > Self.maxEvents { events.removeFirst(events.count - Self.maxEvents) }
        log.write(.event, "\(kind.rawValue): \(detail)", seq: seq, action: during, event: event.id)
        onChange?(.event(event))
        return event
    }

    // MARK: - Private

    /// The single write path. Every mutation bumps the sequence and republishes, so there is
    /// exactly one place where "the world moved on" is decided.
    private func commit(_ mutate: (inout WorldSnapshot) -> Void) {
        var next = snapshot
        mutate(&next)
        seq += 1
        next.seq = seq
        next.at = Date()
        snapshot = next
        onChange?(.state(next))
    }
}
