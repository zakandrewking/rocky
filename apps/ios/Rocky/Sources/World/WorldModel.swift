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
///    why we believe it. The motion agent only acks on completion, so for its whole duration a
///    drive is genuinely `running` + `assumed` -- and Rocky needs to be able to say "I think I'm
///    going" rather than "I'm going". Inventing a confirmation we never received is exactly how a
///    voice ends up asserting embodied facts it does not have.

/// The world's own clock: a monotonic counter bumped on every mutation, so any two observations
/// can be ordered and any stale one can be recognised. Not the board's clock -- `utime.ticks_ms()`
/// wraps and has no relationship to wall time.
typealias WorldSeq = UInt64

// MARK: - Actions

/// How much of an action's status is actually *known*, as opposed to inferred.
///
/// The distinction is the whole reason Rocky can be honest. `assumed` means "we wrote the bytes,
/// the link is alive, and the expected duration has not elapsed" -- a reasonable belief, and not
/// the same thing as the body having said so.
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
enum ActionIntent: String, Sendable, Codable {
    case driveForward, driveBackward, turn, spin, wiggle, stop, settle, look

    /// The plain word for this, used in projections and in the debug view.
    var word: String {
        switch self {
        case .driveForward: return "go forward"
        case .driveBackward: return "back up"
        case .turn: return "turn"
        case .spin: return "spin"
        case .wiggle: return "wiggle"
        case .stop: return "stop"
        case .settle: return "settle"
        case .look: return "look"
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

/// The kinds of thing that happen to a body. Deliberately small to begin with, and every one of
/// them is something the board already reports -- nothing here is aspirational.
enum WorldEventKind: String, Sendable, Codable {
    case bumped, startled, blocked, finished, failed, bodyGone, bodyBack

    /// Whether this is worth considering an interruption for at all. Not the decision -- see
    /// SalienceJudge -- just the filter that keeps routine bookkeeping out of that machinery.
    var isNotable: Bool {
        switch self {
        case .bumped, .startled, .blocked, .bodyGone: return true
        case .finished, .failed, .bodyBack: return false
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
        case .still: return "still"
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

    var phrase: String {
        switch self {
        case .youAsked: return "you asked"
        case .onItsOwn: return "on its own"
        case .reflex: return "couldn't help it"
        case .unknown: return "not sure"
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
    var nearestCm: Double?
    var measuredAt: Date?

    /// Observed reality, not intent. Derived from `doing` alone so nothing an action *claims* can
    /// make this say the robot is moving.
    var moving: Bool { doing.isMoving }

    /// The fields that are worth waking the model up for. Two snapshots that agree here say the
    /// same thing about the world however much telemetry moved underneath them -- which is what
    /// keeps `speed=.47 → .48 → .46` from ever reaching the conversation.
    var semanticIdentity: String {
        [
            body.rawValue,
            doing.rawValue,
            cause.rawValue,
            blocked ? "blocked" : "clear",
            feeling ?? "-",
            action.map { "\($0.id):\($0.status.rawValue):\($0.evidence.rawValue):\($0.done)" } ?? "-",
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
