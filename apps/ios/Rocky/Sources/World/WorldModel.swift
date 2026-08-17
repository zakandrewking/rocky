import Foundation

/// The value types of Rocky's embodiment: what her body is doing, what happened to it, and what
/// she asked it to do. See apps/ios/docs/embodiment.md for the design these implement.
///
/// Two ideas do most of the work here and are worth stating before the types:
///
/// 1. **State is current conditions; events are durable facts.** A non-terminal action transition
///    is a condition (it lives in the snapshot and is superseded); a terminal one is a fact (it
///    becomes an event and is never superseded). That single rule removes every "which one does
///    this go in" judgement call.
/// 2. **Status and evidence are separate axes.** `running` says what we believe; `evidence` says
///    why we believe it. The board honours an intention at its own next safe seam, so between
///    "she asked" and "it started" there is a real gap in which nothing is happening yet and
///    nothing may ever happen -- and Rocky has to be able to say so. Inventing a confirmation we
///    never received is exactly how a voice ends up asserting embodied facts it does not have.

/// The world's own clock: a monotonic counter bumped on every mutation, so any two observations
/// can be ordered and any stale one can be recognised. Not the board's clock -- `utime.ticks_ms()`
/// wraps and has no relationship to wall time.
typealias WorldSeq = UInt64

// MARK: - Actions

/// How much of an action's status is actually *known*, as opposed to inferred.
///
/// The distinction is the whole reason Rocky can be honest. `confirmed` means the board said so.
/// `assumed` is a reasonable belief with nothing behind it -- the stop path, where the motors are
/// commanded off and there is no separate confirmation to wait for. Nothing is ever assumed to
/// have *started*: the board reports that itself.
enum ActionEvidence: String, Sendable, Codable {
    case confirmed, assumed, none
}

enum ActionStatus: String, Sendable, Codable {
    /// The model asked; nothing has left the phone yet.
    case requested
    /// Bounded and written to the socket. This is where a tool result stops.
    case accepted
    /// The body said it began.
    case started
    /// Believed to be happening now.
    case running
    /// The body said it finished.
    case succeeded
    /// The body refused or errored -- busy, unknown command, bad arguments.
    case failed
    /// It began, and something physical stopped it.
    case blocked
    /// A stop, from the person or from Rocky.
    case cancelled
    /// A newer action on the same channel replaced it.
    case superseded
    /// The deadline passed, or the link died, and the outcome was never learned.
    ///
    /// Deliberately not `failed`: failure is something the body told us, lost is something we
    /// never found out. They make different sentences true, and conflating them is how a model
    /// ends up reporting a failure that never happened.
    case lost

    var isTerminal: Bool {
        switch self {
        case .requested, .accepted, .started, .running: return false
        case .succeeded, .failed, .blocked, .cancelled, .superseded, .lost: return true
        }
    }

    /// True once the action is believed to be physically underway.
    var isLive: Bool {
        self == .started || self == .running
    }
}

/// What an action is *for*, in words that mean something out loud. `spin` rather than
/// "rotate 720 degrees at 70% of 150 RPM" -- the second is telemetry, and telemetry is what the
/// model should never have to reverse-engineer its own body from.
///
/// Three of them, because three is what the body answers to. Driving and turning left with the
/// deprecated motion agent (apps/robot/deprecated/motion_agent.py); this body chooses where it
/// goes itself.
enum ActionIntent: String, Sendable, Codable {
    case spin, wiggle, routine, stop

    /// The plain word for this, used in projections and in the debug view.
    var word: String {
        switch self {
        case .spin: return "spin"
        case .wiggle: return "wiggle"
        case .routine: return "move with the story"
        case .stop: return "stop"
        }
    }

    /// The same thing while it is happening. A repeated gesture is one act to a person -- "I am
    /// spinning" for the whole of a spin-three-times, not six alternating machine states.
    var continuous: String {
        switch self {
        case .spin: return "spinning"
        case .wiggle: return "wiggling"
        case .routine: return "moving with the story"
        case .stop: return "stopping"
        }
    }
}

/// One thing Rocky asked her body to do, from the tool call to whatever became of it.
struct RobotAction: Sendable, Identifiable, Equatable {
    let id: String
    let intent: ActionIntent
    var status: ActionStatus
    var evidence: ActionEvidence
    let requestedAt: Date
    var startedAt: Date?
    var endedAt: Date?
    /// Why it ended the way it did, in plain words -- "something was in the way", never "ENOENT".
    var reason: String?
    /// For repeated gestures: how many of how many are done.
    var done: Int
    var total: Int
    /// How long this is expected to take, which is what makes `lost` decidable at all.
    var expectedDuration: TimeInterval

    init(
        id: String,
        intent: ActionIntent,
        expectedDuration: TimeInterval,
        total: Int = 1,
        at: Date = Date()
    ) {
        self.id = id
        self.intent = intent
        self.status = .requested
        self.evidence = .none
        self.requestedAt = at
        self.done = 0
        self.total = total
        self.expectedDuration = expectedDuration
    }

    var age: TimeInterval { Date().timeIntervalSince(startedAt ?? requestedAt) }

    /// Whether the *deadline* for hearing an outcome has passed. Generous on purpose: the cost of
    /// declaring an action lost early is Rocky saying she doesn't know when she does.
    var isOverdue: Bool {
        guard !status.isTerminal else { return false }
        return age > expectedDuration * 2 + 2
    }
}

// MARK: - Events

/// How much a thing that happened deserves to cut somebody off.
///
/// Not every notable event is equally notable, and treating them as one class had a concrete cost.
/// In the first live session the robot was in a cluttered room: ten `blocked` events (routine
/// obstacle avoidance) against three `startled` ones -- and because a single shared cooldown was
/// spent first-come-first-served, the furniture crowded out every startle but the first. Being
/// frightened is the most dramatic thing that happens to this robot, and Rocky was silent for two
/// of the three.
enum EventUrgency: Int, Sendable, Comparable {
    /// Bookkeeping. She should know; she should never stop talking for it.
    case none = 0
    /// Ordinary life. Worth knowing, worth mentioning only if it contradicts her.
    case routine = 1
    /// Something happened *to* her. This is what interruption is for.
    case startling = 2

    static func < (lhs: EventUrgency, rhs: EventUrgency) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The kinds of thing that happen to a body. Deliberately small to begin with, and every one of
/// them is something the board already reports -- nothing here is aspirational.
enum WorldEventKind: String, Sendable, Codable {
    case bumped, startled, blocked, finished, failed, bodyGone, bodyBack

    var urgency: EventUrgency {
        switch self {
        // Startle and flee is the big one: a loud noise, a jump, a fast retreat, wide eyes. If any
        // event should stop a sentence dead, it is this. Being physically bumped, and going numb,
        // are the same order of thing.
        case .startled, .bumped, .bodyGone: return .startling
        // Turning away from an obstacle is how this robot gets around a room. In a cluttered one it
        // is near-constant, and narrating it would make her a sports commentator.
        case .blocked: return .routine
        case .finished, .failed, .bodyBack: return .none
        }
    }
}

/// Something that happened. Immutable, stably identified, never superseded -- "act_83 failed"
/// stays true forever, unlike "moving forward", which stops being true almost immediately.
struct WorldEvent: Sendable, Identifiable, Equatable {
    let id: String
    let seq: WorldSeq
    let kind: WorldEventKind
    /// Plain words for what happened: "something touched me", not "quad_rgb deviation 34".
    let detail: String
    let at: Date
    /// Which action was live when this happened, if any. This is what makes "I tried, but I
    /// bumped into something" one thought instead of two facts the model has to join up.
    let during: String?
    /// How many identical events collapsed into this one (see the projector's coalescing).
    var again: Int

    var secondsAgo: TimeInterval { Date().timeIntervalSince(at) }
}

// MARK: - State

/// How fresh contact with the body is. What makes "I've lost track of my body" sayable, and
/// what stops Rocky describing motion she has had no word about for half a minute.
enum BodyPresence: String, Sendable, Codable {
    case here, quiet, gone
}

/// What the body is doing, semantically. This is the vocabulary Rocky thinks in; wheel speeds
/// and loudness readings stay on this side of the boundary and never reach her.
enum Doing: String, Sendable, Codable {
    case still, rollingForward, rollingBack, turning, spinning, backingAway, lookingAround, unknown

    var word: String {
        switch self {
        case .still: return "sitting still"
        case .rollingForward: return "rolling forward"
        case .rollingBack: return "rolling backward"
        case .turning: return "turning"
        case .spinning: return "spinning"
        case .backingAway: return "backing away"
        case .lookingAround: return "looking around"
        case .unknown: return "not sure"
        }
    }

    /// Whether the body is translating or rotating. Observed reality, kept separate from
    /// `RobotAction.status` on purpose -- the two are allowed to disagree, and that disagreement
    /// is what lets Rocky say "I'm trying to move, but I don't think I'm going anywhere."
    var isMoving: Bool { self != .still && self != .unknown }
}

/// Why the body is doing it. Separating this from *what* is what keeps Rocky from taking credit
/// for a reflex, or apologising for something she chose.
enum DoingCause: String, Sendable, Codable {
    case youAsked, onItsOwn, reflex, unknown

    /// First person, and a complete thought. "on its own" invites Rocky to talk about her body as
    /// a separate thing that has its own reasons; "I felt like it" is the same fact said as
    /// herself, which is the only way she ever gets to say it out loud.
    var phrase: String? {
        switch self {
        case .youAsked: return "you asked me to"
        case .onItsOwn: return "I felt like it"
        case .reflex: return "I couldn't help it"
        case .unknown: return nil
        }
    }
}

/// The complete current picture of the body. Always a full snapshot -- there are no patches
/// anywhere in this system, so an absent field always means "not known", never "unchanged".
struct WorldSnapshot: Sendable, Equatable {
    var seq: WorldSeq = 0
    var at: Date = Date()
    var body: BodyPresence = .gone
    var doing: Doing = .unknown
    var cause: DoingCause = .unknown
    var blocked: Bool = false
    var blockedDetail: String?
    var feeling: String?
    var action: RobotAction?

    /// Observed reality, not intent. Derived from `doing` alone so nothing an action *claims* can
    /// make this say the robot is moving.
    var moving: Bool { doing.isMoving }

    /// What Rocky would say she is doing, in one first-person verb.
    ///
    /// While something she asked for is underway this is *that* act, not whatever the board's
    /// state machine is flapping between underneath it. A spin-three-times really does alternate
    /// turning/settling/turning six times in nine seconds, and showing her each flip was most of
    /// why she sounded like she was reading a status board: by the time she could speak, the
    /// picture she was speaking from was two transitions old.
    var visibleDoing: String {
        if let action, action.status.isLive, action.intent != .stop {
            return action.intent.continuous
        }
        return doing.word
    }

    /// The fields that are worth waking the model up for. Two snapshots that agree here say the
    /// same thing about the world however much telemetry moved underneath them -- which is what
    /// keeps `speed=.47 → .48 → .46` from ever reaching the conversation.
    ///
    /// `action.done` is deliberately absent: the repeat count is worth *showing* whenever a
    /// projection happens anyway, and is not worth causing one. Counting "two of three" out loud
    /// is the sound of a machine, not of somebody enjoying a spin.
    var semanticIdentity: String {
        [
            body.rawValue,
            visibleDoing,
            cause.rawValue,
            blocked ? "blocked" : "clear",
            feeling ?? "-",
            action.map { "\($0.id):\($0.status.isLive ? "going" : $0.status.rawValue)" } ?? "-",
        ].joined(separator: "|")
    }
}

// MARK: - Words

enum WorldWords {
    /// Relative age, rounded the way a person would say it. Absolute timestamps mean nothing to a
    /// model with no clock, and a false precision ("3.418 seconds ago") reads as machinery.
    static func ago(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<1.5: return "just now"
        case ..<45: return "\(Int(seconds.rounded()))s ago"
        case ..<90: return "about a minute ago"
        case ..<600: return "\(Int((seconds / 60).rounded()))m ago"
        default: return "a while ago"
        }
    }

    /// Duration so far, for "I've been spinning for 2s".
    static func lasting(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "a moment" : "\(Int(seconds.rounded()))s"
    }
}
