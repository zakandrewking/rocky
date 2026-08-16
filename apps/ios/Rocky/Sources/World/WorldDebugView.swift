import SwiftUI

/// The Body panel: exactly what Rocky knew, and exactly what she was responding to.
///
/// Built around one question -- *what robot state did she have available when this response
/// began* -- because that is the question every "why did she say that" turns into, and it is
/// unanswerable from a flat text log. Answering it needs three things this view provides and
/// prose cannot: correlation identifiers you can pivot on, an explicit mark on state that has
/// been superseded, and a per-response record written at the moment the response started rather
/// than reconstructed afterwards.
///
/// One merged timeline rather than parallel swimlanes. Six synchronised columns is the right
/// picture on a wall monitor and unreadable on a phone; a single time-ordered stream, coloured by
/// lane and filterable by both lane and correlation id, carries the same information at this
/// width. The same records are in `Documents/world.jsonl` for anyone who wants the columns
/// (`apps/ios/scripts/pull-log.sh --world`).
struct WorldDebugView: View {
    @ObservedObject var log: WorldLog
    @ObservedObject var world: WorldStore

    private enum Tab: String, CaseIterable {
        case timeline = "timeline"
        case responses = "responses"
    }

    @State private var tab: Tab = .timeline
    @State private var hiddenLanes: Set<WorldLane> = []
    /// A correlation id to pivot on -- everything about act_83, or everything during resp_abc.
    @State private var focus: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                RockyTheme.ink.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 10) {
                    nowStrip
                    Picker("", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if let focus {
                        Button {
                            self.focus = nil
                        } label: {
                            Text("only \(focus) — tap to clear")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(RockyTheme.amberBright)
                        }
                    }

                    switch tab {
                    case .timeline:
                        laneFilter
                        timeline
                    case .responses:
                        responses
                    }
                }
                .padding(12)
            }
            .navigationTitle("body")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("done") { dismiss() }
                        .font(.system(size: 12, design: .monospaced))
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - What is true right now

    /// The live snapshot, in the same words the projection uses. Anything here that disagrees with
    /// what Rocky just said is the bug, stated plainly.
    private var nowStrip: some View {
        let snapshot = world.snapshot
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("seq \(snapshot.seq)").foregroundStyle(RockyTheme.amberBright)
                Text(snapshot.body.rawValue).foregroundStyle(colour(for: snapshot.body))
                Text(snapshot.doing.word).foregroundStyle(RockyTheme.mintBright)
                if snapshot.moving { Text("moving").foregroundStyle(RockyTheme.amber) }
                if snapshot.blocked { Text("blocked").foregroundStyle(RockyTheme.rust) }
            }
            if let action = snapshot.action {
                HStack(spacing: 6) {
                    idChip(action.id)
                    Text("\(action.intent.word) · \(action.status.rawValue) · \(action.evidence.rawValue)")
                        .foregroundStyle(
                            action.evidence == .confirmed ? RockyTheme.mintBright : RockyTheme.amber
                        )
                }
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(RockyTheme.deep))
    }

    private func colour(for presence: BodyPresence) -> Color {
        switch presence {
        case .here: return RockyTheme.mintBright
        case .quiet: return RockyTheme.amber
        case .gone: return RockyTheme.rust
        }
    }

    // MARK: - Timeline

    private var laneFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(WorldLane.allCases, id: \.self) { lane in
                    let on = !hiddenLanes.contains(lane)
                    Button {
                        if on { hiddenLanes.insert(lane) } else { hiddenLanes.remove(lane) }
                    } label: {
                        Text("\(lane.symbol) \(lane.rawValue)")
                            .font(.system(size: 10, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(on ? colour(for: lane).opacity(0.22) : .clear)
                            )
                            .foregroundStyle(on ? colour(for: lane) : RockyTheme.teal.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var visibleEntries: [WorldLogEntry] {
        log.entries.reversed().filter { entry in
            guard !hiddenLanes.contains(entry.lane) else { return false }
            guard let focus else { return true }
            return entry.actionId == focus || entry.eventId == focus || entry.responseId == focus
        }
    }

    private var timeline: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 5) {
                ForEach(visibleEntries) { entry in
                    row(entry)
                }
            }
        }
    }

    private func row(_ entry: WorldLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Self.clock.string(from: entry.at))
                    .foregroundStyle(RockyTheme.teal.opacity(0.65))
                Text(entry.lane.symbol).foregroundStyle(colour(for: entry.lane))
                Text(entry.note)
                    .foregroundStyle(
                        entry.superseded ? RockyTheme.teal.opacity(0.45) : RockyTheme.mintBright.opacity(0.85)
                    )
                    // Superseded state is not merely old: it has been *deleted* from the
                    // conversation, so Rocky genuinely cannot read it any more. Struck through
                    // rather than dimmed alone, because "she no longer believes this" is the one
                    // thing about a state row worth seeing without reading it.
                    .strikethrough(entry.superseded, color: RockyTheme.teal.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            let chips = [entry.actionId, entry.eventId, entry.responseId].compactMap { $0 }
            if !chips.isEmpty || !entry.detail.isEmpty {
                HStack(spacing: 5) {
                    Text("seq \(entry.seq)").foregroundStyle(RockyTheme.teal.opacity(0.5))
                    ForEach(chips, id: \.self) { idChip($0) }
                    if !entry.detail.isEmpty {
                        Text(entry.detail.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }
                            .joined(separator: " "))
                            .foregroundStyle(RockyTheme.teal.opacity(0.6))
                            .lineLimit(2)
                    }
                }
                .padding(.leading, 46)
            }
        }
        .font(.system(size: 10, design: .monospaced))
    }

    /// Tapping any correlation id pivots the whole view onto it. This is the affordance that turns
    /// a log into an investigation: "show me everything that ever happened to act_83".
    private func idChip(_ id: String) -> some View {
        Button {
            focus = (focus == id) ? nil : id
        } label: {
            Text(id)
                .font(.system(size: 9, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(RockyTheme.amber.opacity(0.16)))
                .foregroundStyle(RockyTheme.amberBright.opacity(0.9))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Responses

    /// One card per response, answering the question this whole panel exists for. Written when the
    /// response began, so no amount of subsequent churn can make it lie about what was true then.
    private var responses: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(log.ledgers.reversed()) { ledger in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            idChip(ledger.id)
                            Text(Self.clock.string(from: ledger.at))
                                .foregroundStyle(RockyTheme.teal.opacity(0.65))
                            Spacer(minLength: 0)
                            Text(ledger.outcome ?? "in flight")
                                .foregroundStyle(
                                    ledger.interruptedBy != nil ? RockyTheme.rust : RockyTheme.mint
                                )
                        }
                        line("began at", "world seq \(ledger.worldSeq)")
                        line("doing", ledger.activeAction ?? "nothing")
                        line("last thing", ledger.mostRecentEvent ?? "nothing")
                        line("state it could see", ledger.liveStateItem ?? "none")
                        if !ledger.supersededStateItems.isEmpty {
                            line("no longer readable", ledger.supersededStateItems.joined(separator: " "))
                        }
                        if let interruptedBy = ledger.interruptedBy {
                            HStack(spacing: 5) {
                                Text("cut off by").foregroundStyle(RockyTheme.rust.opacity(0.8))
                                idChip(interruptedBy)
                            }
                        }
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(RockyTheme.deep))
                }
            }
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).foregroundStyle(RockyTheme.teal.opacity(0.7)).frame(width: 118, alignment: .leading)
            Text(value).foregroundStyle(RockyTheme.mintBright.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func colour(for lane: WorldLane) -> Color {
        switch lane {
        case .state: return RockyTheme.mintBright
        case .event: return RockyTheme.rust
        case .action: return RockyTheme.amberBright
        case .projection: return RockyTheme.teal
        case .salience: return Color(hex: 0x9C7BD8)
        case .response: return RockyTheme.amber
        case .tool: return RockyTheme.mint
        case .link: return Color(hex: 0x5FA8B8)
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
