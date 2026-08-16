import Foundation

/// What should happen to Rocky's speech because of something that just happened to her body.
///
/// The two questions this design keeps apart -- *should this affect what she knows* and *should
/// this interrupt her right now* -- are both answered here, but only the second one is hard.
/// Everything reaches her; almost nothing stops her mid-sentence.
enum SalienceVerdict: String, Sendable {
    /// Not even worth putting in front of her.
    case ignore
    /// She should know. She should not say anything because of it.
    case context
    /// Worth reacting to, but not worth cutting a sentence in half.
    case afterUtterance
    /// What she is saying is now wrong. Stop her.
    case interrupt
    /// Safety. Stop her without asking anyone.
    case urgent

    var stopsSpeech: Bool { self == .interrupt || self == .urgent }
}

/// What voice is doing at the instant an event lands. Everything the judge needs and nothing it
/// doesn't -- in particular no reference to any server-side item, so a judgment can never be
/// invalidated by an item disappearing underneath it.
struct VoiceMoment: Sendable {
    let isGenerating: Bool
    let responseId: String?
    let utteranceSoFar: String
    let worldSeq: WorldSeq

    /// Whether the sentence in flight is making a claim about movement -- which is what decides
    /// whether a bump *contradicts* her or merely happens near her.
    var claimsMotion: Bool {
        let text = utteranceSoFar.lowercased()
        return Self.motionWords.contains { text.contains($0) }
    }

    private static let motionWords = [
        "i'm going", "im going", "heading", "on my way", "driving", "rolling",
        "spinning", "turning", "coming over", "moving", "i'll be right", "let me get",
    ]
}

/// One in-flight out-of-band judgment. Every field here exists to make a returning verdict
/// checkable against a world that has moved on since it was asked.
struct SalienceTicket: Sendable, Identifiable {
    let id: String
    let eventId: String
    let eventKind: WorldEventKind
    /// The response this was judged *against*. If that response is gone, so is the judgment.
    let forResponseId: String?
    let worldSeq: WorldSeq
    let issuedAt: Date
}

/// Decides, and keeps the deciding race-safe.
///
/// Two tiers, and they are not alternatives:
///
/// - **Deterministic**, per event, immediate. Safety and self-contradiction never wait on a model
///   round trip. An emergency stop that needed an LLM to agree with it is not an emergency stop.
/// - **Judged**, out of band, one superseding slot. For the ambiguous middle, ask the model
///   itself whether what just happened invalidates what it is already saying. That question has
///   exactly one current answer, so a newer event replaces the question rather than adding to it
///   -- which bounds cost and removes "two verdicts disagree" as a state that can exist.
@MainActor
final class SalienceJudge {
    /// At most one spoken interruption this often. A robot being bumped repeatedly must not turn
    /// into a commentator.
    private static let interruptionCooldown: TimeInterval = 8
    /// A judgment older than this is stale by definition -- the sentence it was about is over.
    private static let ticketLifetime: TimeInterval = 4

    /// Asks the model, out of band. Set by the session; the judge itself never touches WebRTC.
    var askOutOfBand: ((SalienceTicket, String) -> Void)?

    private(set) var pending: SalienceTicket?
    private var latestJudgedSeq: WorldSeq = 0
    private var resolvedEventIds: Set<String> = []
    private var lastInterruptionAt: Date?
    private var lastInterruptedKind: WorldEventKind?
    private var nextTicketNumber = 0

    private var log: WorldLog { WorldLog.shared }

    func reset() {
        pending = nil
        latestJudgedSeq = 0
        resolvedEventIds = []
        lastInterruptionAt = nil
        lastInterruptedKind = nil
    }

    // MARK: - Tier one: rules

    /// The immediate verdict, or nil when this one genuinely needs judgement. Returning nil is
    /// only ever possible while a response is in flight -- when she is silent there is nothing to
    /// interrupt, so there is nothing ambiguous to weigh.
    func rule(on event: WorldEvent, action: RobotAction?, moment: VoiceMoment) -> SalienceVerdict? {
        // Safety first, and without qualification. A body that stopped itself while its voice is
        // in the middle of saying it is on the way is the one case where being late is worse than
        // being wrong.
        if event.kind == .blocked && moment.claimsMotion {
            return note(.urgent, event, "stopped itself while she was saying she was moving")
        }
        if event.kind == .bodyGone && action?.status.isLive == true {
            return note(.urgent, event, "lost the body mid-action")
        }

        guard moment.isGenerating else {
            // Nothing to cut off. A notable event with no response running is simply a reason to
            // start one -- which is a different act from interrupting, and cheaper to get wrong.
            guard event.kind.isNotable else { return .context }
            guard allowInterruption(event.kind) else { return note(.context, event, "still cooling down") }
            return note(.interrupt, event, "she was quiet; this is worth saying")
        }

        guard event.kind.isNotable else { return .context }
        guard allowInterruption(event.kind) else { return note(.context, event, "still cooling down") }

        // Something happened to a body whose voice is describing that body's motion. That is the
        // clearest possible case for cutting in, and it does not need a second opinion.
        if moment.claimsMotion { return note(.interrupt, event, "contradicts what she is saying") }

        // Everything else while she is talking is genuinely a judgement call.
        return nil
    }

    // MARK: - Tier two: out of band

    /// Issues a judgment request, superseding any in flight. Returns the ticket so the caller can
    /// log the correlation; the request itself goes out through `askOutOfBand`.
    @discardableResult
    func ask(about event: WorldEvent, snapshot: WorldSnapshot, moment: VoiceMoment) -> SalienceTicket {
        if let superseded = pending {
            log.write(
                .salience,
                "\(superseded.id) superseded by a newer world change",
                seq: moment.worldSeq,
                event: superseded.eventId
            )
        }
        nextTicketNumber += 1
        let ticket = SalienceTicket(
            id: "sal_\(nextTicketNumber)",
            eventId: event.id,
            eventKind: event.kind,
            forResponseId: moment.responseId,
            worldSeq: moment.worldSeq,
            issuedAt: Date()
        )
        pending = ticket
        log.write(
            .salience,
            "\(ticket.id) asking about \(event.kind.rawValue)",
            seq: moment.worldSeq,
            event: event.id,
            response: moment.responseId
        )
        askOutOfBand?(ticket, Self.prompt(event: event, snapshot: snapshot, moment: moment))
        return ticket
    }

    /// Validates a returning verdict against a world that has moved on, and returns nil if it no
    /// longer refers to anything real.
    ///
    /// This is the scenario from the brief, handled by construction: R17 speaking, event A judged,
    /// event B cancels R17, R18 begins, A finally returns -- `forResponseId` is R17, R17 is not
    /// current, dropped, no effect.
    func resolve(ticketId: String, decision: String, reason: String, moment: VoiceMoment) -> SalienceVerdict? {
        guard let ticket = pending, ticket.id == ticketId else {
            log.write(.salience, "\(ticketId) dropped: superseded", seq: moment.worldSeq)
            return nil
        }
        pending = nil

        if ticket.forResponseId != moment.responseId {
            log.write(
                .salience,
                "\(ticketId) dropped: judged \(ticket.forResponseId ?? "-"), now \(moment.responseId ?? "-")",
                seq: moment.worldSeq, event: ticket.eventId
            )
            return nil
        }
        if resolvedEventIds.contains(ticket.eventId) {
            log.write(.salience, "\(ticketId) dropped: already settled by rule", seq: moment.worldSeq, event: ticket.eventId)
            return nil
        }
        if ticket.worldSeq < latestJudgedSeq {
            log.write(.salience, "\(ticketId) dropped: world moved on", seq: moment.worldSeq, event: ticket.eventId)
            return nil
        }
        if Date().timeIntervalSince(ticket.issuedAt) > Self.ticketLifetime {
            log.write(.salience, "\(ticketId) dropped: too late to matter", seq: moment.worldSeq, event: ticket.eventId)
            return nil
        }

        let verdict: SalienceVerdict
        switch decision {
        case "interrupt_speech": verdict = .interrupt
        case "finish_first": verdict = .afterUtterance
        case "just_know": verdict = .context
        default: verdict = .ignore
        }
        if verdict.stopsSpeech && !allowInterruption(ticket.eventKind) {
            log.write(.salience, "\(ticketId) downgraded: still cooling down", seq: moment.worldSeq, event: ticket.eventId)
            return .context
        }

        latestJudgedSeq = ticket.worldSeq
        resolvedEventIds.insert(ticket.eventId)
        if verdict.stopsSpeech { stampInterruption(ticket.eventKind) }
        // The reason is kept verbatim even though nothing at runtime reads it. When this decides
        // wrongly, the enum says what happened and only the reason says why.
        log.write(
            .salience,
            "\(ticketId) → \(verdict.rawValue): \(reason)",
            seq: ticket.worldSeq,
            event: ticket.eventId,
            response: ticket.forResponseId
        )
        return verdict
    }

    // MARK: - Rate limiting

    private func allowInterruption(_ kind: WorldEventKind) -> Bool {
        guard let last = lastInterruptionAt else { return true }
        if Date().timeIntervalSince(last) >= Self.interruptionCooldown { return true }
        // Inside the cooldown, a *different* kind of thing is still allowed through once: being
        // bumped twice is repetition, but being bumped and then losing the body is two things.
        return lastInterruptedKind != kind && Date().timeIntervalSince(last) >= Self.interruptionCooldown / 2
    }

    private func stampInterruption(_ kind: WorldEventKind) {
        lastInterruptionAt = Date()
        lastInterruptedKind = kind
    }

    private func note(_ verdict: SalienceVerdict, _ event: WorldEvent, _ reason: String) -> SalienceVerdict {
        resolvedEventIds.insert(event.id)
        latestJudgedSeq = max(latestJudgedSeq, event.seq)
        if verdict.stopsSpeech { stampInterruption(event.kind) }
        log.write(.salience, "rule → \(verdict.rawValue): \(reason)", seq: event.seq, event: event.id)
        return verdict
    }

    // MARK: - The question

    /// Deliberately short. This runs while she is mid-sentence, so a verdict that arrives after
    /// the sentence ends is worth nothing however good it is.
    static func prompt(event: WorldEvent, snapshot: WorldSnapshot, moment: VoiceMoment) -> String {
        """
        You are the reflex that decides whether a robot should stop mid-sentence.

        It is saying right now: "\(moment.utteranceSoFar.suffix(240))"
        What just happened to its body: \(event.kind.rawValue) — \(event.detail)
        Its body right now: \(snapshot.doing.word), \(snapshot.moving ? "moving" : "not moving")\
        \(snapshot.blocked ? ", something in the way" : "")

        Reply with JSON only, no prose:
        {"decision":"interrupt_speech"|"finish_first"|"just_know"|"ignore","reason":"under 20 words"}

        interrupt_speech — what it is saying is now wrong, or ignoring this would sound strange
        finish_first — worth reacting to, but not worth cutting a sentence in half
        just_know — worth knowing, not worth saying
        ignore — neither
        """
    }
}
