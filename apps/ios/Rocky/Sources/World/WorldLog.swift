import Foundation

/// Which stream a log entry belongs to. The debug view colours by this, and a filter on it is how
/// "show me only the salience decisions" works.
enum WorldLane: String, Sendable, CaseIterable {
    case state, event, action, projection, salience, response, tool, link

    var symbol: String {
        switch self {
        case .state: return "◈"
        case .event: return "✷"
        case .action: return "▸"
        case .projection: return "→"
        case .salience: return "?"
        case .response: return "●"
        case .tool: return "ƒ"
        case .link: return "~"
        }
    }
}

/// One line of the record. Correlation identifiers are first-class fields rather than being
/// buried in prose, because the questions worth asking of this log are all joins: "everything
/// about act_83", "what happened during resp_abc", "which event caused this interruption".
struct WorldLogEntry: Sendable, Identifiable {
    let id: UInt64
    let at: Date
    let lane: WorldLane
    let seq: WorldSeq
    let note: String
    var actionId: String?
    var eventId: String?
    var responseId: String?
    var itemId: String?
    var detail: [String: String] = [:]
    /// Set later, when a projection is deleted from the conversation. The whole point of the
    /// debug view is that "voice no longer believes this" is visible at a glance.
    var superseded = false
}

/// What the model actually had available when a response began.
///
/// This exists to answer one specific question the hard way rather than by reconstruction: it is
/// written at `response.created`, from the store as it stood at that instant, so no amount of
/// later churn can make it lie about what was true then.
struct ResponseLedger: Sendable, Identifiable {
    let id: String
    let at: Date
    let worldSeq: WorldSeq
    let activeAction: String?
    let mostRecentEvent: String?
    let liveStateItem: String?
    let supersededStateItems: [String]
    var outcome: String?
    /// The event that cut this response off, when one did.
    var interruptedBy: String?
    /// What the response cost, and how much of it the cache covered. Here rather than in a
    /// separate metrics view because the thing worth spotting is a *correlation*: a response whose
    /// cached share collapsed, sitting right below the projection that rewrote history.
    var inputTokens: Int?
    var cachedTokens: Int?
}

/// The structured record of everything the world model did, and everything voice was told.
///
/// Two consumers, one source: the in-app Body panel reads `entries`/`ledgers` live, and
/// `Documents/world.jsonl` is pulled off the phone with the same `devicectl` route as
/// `session.log` (see apps/ios/scripts/pull-log.sh) so the coding agent reads exactly what the
/// person holding the phone saw.
@MainActor
final class WorldLog: ObservableObject {
    static let shared = WorldLog()

    /// Enough to cover a long test session without the view or the device paying for it.
    private static let maxEntries = 600
    private static let maxLedgers = 60

    @Published private(set) var entries: [WorldLogEntry] = []
    @Published private(set) var ledgers: [ResponseLedger] = []

    private var nextId: UInt64 = 0
    private let url: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("world.jsonl")
    }()

    @discardableResult
    func write(
        _ lane: WorldLane,
        _ note: String,
        seq: WorldSeq = 0,
        action: String? = nil,
        event: String? = nil,
        response: String? = nil,
        item: String? = nil,
        detail: [String: String] = [:]
    ) -> UInt64 {
        nextId += 1
        let entry = WorldLogEntry(
            id: nextId,
            at: Date(),
            lane: lane,
            seq: seq,
            note: note,
            actionId: action,
            eventId: event,
            responseId: response,
            itemId: item,
            detail: detail
        )
        entries.append(entry)
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
        append(entry)
        // Mirrored into the plain session log too. That file is what anyone already knows how to
        // pull, and a world model whose story is only readable through a second, newer tool is a
        // world model nobody reads the story of.
        RockyLog.write("world \(lane.symbol) \(note)")
        return entry.id
    }

    /// Flags a projection the conversation no longer contains. Called by the projector at the
    /// moment it deletes the item, not inferred afterwards from ordering.
    func markSuperseded(item: String) {
        for index in entries.indices where entries[index].itemId == item && !entries[index].superseded {
            entries[index].superseded = true
        }
    }

    func record(_ ledger: ResponseLedger) {
        ledgers.append(ledger)
        if ledgers.count > Self.maxLedgers { ledgers.removeFirst(ledgers.count - Self.maxLedgers) }
        write(
            .response,
            "R \(ledger.id.suffix(6)) began at seq \(ledger.worldSeq)",
            seq: ledger.worldSeq,
            response: ledger.id,
            detail: [
                "action": ledger.activeAction ?? "-",
                "event": ledger.mostRecentEvent ?? "-",
                "state": ledger.liveStateItem ?? "-",
            ]
        )
    }

    func closeLedger(_ responseId: String, outcome: String, interruptedBy: String? = nil) {
        guard let index = ledgers.lastIndex(where: { $0.id == responseId }) else { return }
        ledgers[index].outcome = outcome
        if let interruptedBy { ledgers[index].interruptedBy = interruptedBy }
    }

    func recordCost(_ responseId: String, inputTokens: Int, cachedTokens: Int, cachedPercent: Int) {
        if let index = ledgers.lastIndex(where: { $0.id == responseId }) {
            ledgers[index].inputTokens = inputTokens
            ledgers[index].cachedTokens = cachedTokens
        }
        write(
            .response,
            "R \(responseId.suffix(6)) input \(inputTokens) tokens, \(cachedPercent)% cached",
            response: responseId,
            detail: ["input": "\(inputTokens)", "cached": "\(cachedTokens)"]
        )
    }

    func ledger(for responseId: String) -> ResponseLedger? {
        ledgers.last { $0.id == responseId }
    }

    // MARK: - The file

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private func append(_ entry: WorldLogEntry) {
        var object: [String: Any] = [
            "t": Self.formatter.string(from: entry.at),
            "lane": entry.lane.rawValue,
            "seq": entry.seq,
            "note": entry.note,
        ]
        if let value = entry.actionId { object["action_id"] = value }
        if let value = entry.eventId { object["event_id"] = value }
        if let value = entry.responseId { object["response_id"] = value }
        if let value = entry.itemId { object["item_id"] = value }
        if !entry.detail.isEmpty { object["detail"] = entry.detail }

        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: url)
        }
    }
}
