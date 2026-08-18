import SwiftUI
import UniformTypeIdentifiers

/// Discovery has a real intermediate state: the sweep can find an address before the TCP stream
/// is ready. Treating `searchFinished && !connected` as "not found" made that healthy gap become a
/// permanent lie in the debug log.
enum RobotSearchStatus {
    static func isSettled(connected: Bool, searchFinished: Bool, hasHost: Bool) -> Bool {
        connected || (searchFinished && !hasHost)
    }

    static func label(
        connected: Bool,
        searchFinished: Bool,
        hasHost: Bool,
        mode: String,
        mood: String
    ) -> String {
        if connected { return "robot: connected · \(mode)/\(mood)" }
        if hasHost { return "robot: found · connecting…" }
        if searchFinished { return "robot: not found · voice only" }
        return "robot: searching…"
    }
}

/// One screen, built to look and behave like apps/desktop: Rocky's stone orb on a dark starfield
/// (OrbView / RockyTheme, both ported from that app's styles.css) and a small monospaced state
/// chip pinned to the bottom corner that expands into details -- desktop's `.debug-state`.
///
/// The orb is the conversation control. The small personality pill only chooses who the next
/// conversation is with. The robot connection has no manual UI at all: it is discovered and
/// connected automatically (RobotDiscovery), the same way desktop's own plumbing is invisible.
struct ContentView: View {
    @StateObject private var voiceSession = RealtimeVoiceSession()
    @AppStorage(PersonalityCatalog.selectionKey) private var selectedCharacterID = PersonalityCatalog.defaultCharacterID
    /// The one robot integration: finds the board, watches what it does, and passes Rocky's
    /// intentions back. There is one payload (apps/robot/device/rocky_agent.py) and so one
    /// connection -- the older commanded-motion agent and its separate discovery are deprecated.
    @StateObject private var behavior = BehaviorMonitor()
    @State private var log: [String] = []
    @State private var showPayloadPicker = false
    @State private var showBodyPanel = false
    @State private var showPersonalitySelector = false
    @State private var detailsOpen = false
    /// Set the instant the stone is tapped, before any awaiting, purely so the UI can respond to
    /// the touch rather than to the network.
    @State private var starting = false
    /// When the conversation was last stopped by hand, so the very next tap doesn't race its
    /// teardown.
    @State private var lastStopAt: Date?

    var body: some View {
        ZStack {
            RockyTheme.background
            StarField()

            VStack {
                Spacer()
                orb
                Spacer()
            }

            VStack {
                HStack {
                    Spacer()
                    personalityButton
                }
                Spacer()
            }
            .padding(16)

            VStack {
                Spacer()
                HStack {
                    stateChip
                    Spacer(minLength: 0)
                }
            }
            .padding(14)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            selectedCharacterID = PersonalityCatalog.resolvedID(selectedCharacterID)
            behavior.start()
        }
        .onChange(of: behavior.connected) { _, found in
            voiceSession.bodyAvailabilityChanged(found)
        }
        .sheet(isPresented: $showPersonalitySelector) {
            PersonalitySelectorView(
                selection: $selectedCharacterID,
                canChange: canChangePersonality,
                onChange: personalityChanged
            )
        }
    }

    // MARK: - Conversation control

    private var hasBakedOpenAIKey: Bool {
        !((Bundle.main.object(forInfoDictionaryKey: "RockyOpenAIKey") as? String) ?? "").isEmpty
    }

    /// Voice state only. Finding the robot is background work the user should never watch, so it
    /// deliberately does not reach the orb -- a missing robot is not an error, just a Rocky with
    /// no body (exactly what apps/desktop is).
    ///
    /// `starting` is set on the tap itself, before any awaiting, so the stone reacts to being
    /// touched immediately; and loading continues until Rocky's first word is actually audible,
    /// not merely until a socket is ready, so the animation ends exactly when she starts talking.
    private var orbPhase: OrbPhase {
        if case .failed = voiceSession.state { return .error }
        if starting { return .connecting }
        switch voiceSession.state {
        case .connecting: return .connecting
        case .paused: return .paused
        case .connected:
            if voiceSession.speaking { return .speaking }
            return voiceSession.hasSpokenOnce ? .listening : .connecting
        default: return .idle
        }
    }

    private var orbTappable: Bool {
        hasBakedOpenAIKey && !starting && voiceSession.state != .connecting
    }

    private var orbLabel: String {
        switch voiceSession.state {
        case .connected: return "Pause conversation"
        case .paused: return "Resume conversation"
        default: return "Start conversation"
        }
    }

    private var orbSize: CGFloat {
        #if os(iOS)
        let width = UIScreen.main.bounds.width
        #else
        let width: CGFloat = 430
        #endif
        return max(230, min(340, width * 0.52))
    }

    private var orb: some View {
        Button {
            Task { await toggleVoiceSession() }
        } label: {
            // Desktop's `width: min(52vw, 340px); min-width: 230px`, in points.
            OrbView(phase: orbPhase)
                .frame(width: orbSize, height: orbSize)
        }
        .buttonStyle(.plain)
        .disabled(!orbTappable)
        .accessibilityLabel(orbLabel)
    }

    // MARK: - Personality

    private var selectedPersonality: PersonalityProfile? {
        PersonalityCatalog.profile(for: selectedCharacterID)
    }

    private var canChangePersonality: Bool {
        guard !starting else { return false }
        switch voiceSession.state {
        case .connected, .connecting:
            return false
        case .disconnected, .paused, .failed:
            return true
        }
    }

    private var personalityButton: some View {
        Button {
            showPersonalitySelector = true
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                Text(selectedPersonality?.name ?? "Personality")
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(RockyTheme.mintBright.opacity(canChangePersonality ? 0.86 : 0.38))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background {
                Capsule()
                    .fill(RockyTheme.ink.opacity(0.58))
                    .overlay {
                        Capsule().stroke(RockyTheme.mint.opacity(0.16), lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
        .disabled(!canChangePersonality)
        .accessibilityLabel("Choose personality. Current personality: \(selectedPersonality?.name ?? "unknown")")
        .accessibilityHint(canChangePersonality ? "Opens the personality selector" : "Pause the conversation first")
    }

    private func personalityChanged(to characterID: String) {
        if voiceSession.state == .paused {
            voiceSession.disconnect()
            lastStopAt = Date()
            appendLog("voice: ended paused conversation to switch personality")
        }
        let name = PersonalityCatalog.profile(for: characterID)?.name ?? characterID
        appendLog("personality: \(name)")
    }

    // MARK: - State chip (desktop's `.debug-state`)

    private var phaseWord: String {
        if case .failed = voiceSession.state { return "error" }
        switch voiceSession.state {
        case .connecting: return "connecting"
        case .connected: return voiceSession.speaking ? "speaking" : "listening"
        case .paused: return "paused"
        default: return "idle"
        }
    }

    private var bodyDescription: String {
        behavior.connected
            ? "b:\(behavior.mode)/\(behavior.mood)"
            : (behavior.searchFinished ? "b:none" : "b:…")
    }

    private var robotStatus: String {
        RobotSearchStatus.label(
            connected: behavior.connected,
            searchFinished: behavior.searchFinished,
            hasHost: behavior.host != nil,
            mode: behavior.mode,
            mood: behavior.mood
        )
    }

    private var chipDetail: String {
        let voice: String = switch voiceSession.state {
        case .disconnected: "-"
        case .connecting: "…"
        case .connected: "on"
        case .paused: "paused"
        case .failed: "failed"
        }
        let personality = selectedPersonality?.id ?? "?"
        return "p:\(personality) \(bodyDescription) v:\(voice)\(hasBakedOpenAIKey ? "" : " k:missing")"
    }

    private var stateChip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(phaseWord).foregroundStyle(RockyTheme.amberBright.opacity(0.72))
                Text(chipDetail)
                    .foregroundStyle(RockyTheme.mint.opacity(0.46))
                    .lineLimit(1)
            }

            if detailsOpen {
                Divider().overlay(RockyTheme.mint.opacity(0.12))
                detailBody
            }
        }
        .font(.system(size: detailsOpen ? 11 : 10, design: .monospaced))
        .padding(detailsOpen ? 10 : 7)
        .frame(maxWidth: detailsOpen ? .infinity : nil, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(RockyTheme.ink.opacity(detailsOpen ? 0.86 : 0.38))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(RockyTheme.mint.opacity(0.1), lineWidth: 1)
                }
        }
        .contentShape(Rectangle())
        .onTapGesture { detailsOpen.toggle() }
        .accessibilityLabel("Rocky state")
    }

    private var detailBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tap the stone to talk. Rocky finds his body on the same Wi-Fi; voice still works when it is away.")
                .foregroundStyle(RockyTheme.mintBright.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)

            Text(robotStatus)
                .foregroundStyle(RockyTheme.mint.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)

            if behavior.connected {
                Text("Rocky is present in his own body. Movement is autonomous body language; mode and mood above are what he currently feels.")
                    .foregroundStyle(RockyTheme.mint.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .failed(let message) = voiceSession.state {
                Text("voice: \(message)").foregroundStyle(RockyTheme.rust.opacity(0.9))
            }
            if !hasBakedOpenAIKey {
                Text("No OpenAI key baked in — run apps/ios/scripts/generate.sh with OPENAI_API_KEY set, then rebuild.")
                    .foregroundStyle(RockyTheme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let toolCall = voiceSession.lastToolCall {
                Text("last action: \(toolCall)").foregroundStyle(RockyTheme.mint.opacity(0.7))
            }

            // What Rocky knew, and what she was responding to. Kept one tap from the state chip
            // rather than behind a build flag: the questions it answers ("why did she say she was
            // moving") only come up while a session is running, on the phone, in the room.
            Button("body: what rocky knows…") { showBodyPanel = true }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(RockyTheme.amberBright.opacity(0.76))
                .sheet(isPresented: $showBodyPanel) {
                    WorldDebugView(log: WorldLog.shared, world: voiceSession.world)
                }

            Button("push payload to cyberpi…") { showPayloadPicker = true }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(RockyTheme.amberBright.opacity(0.76))
                .disabled(behavior.host == nil)
                .fileImporter(isPresented: $showPayloadPicker, allowedContentTypes: [.item]) { result in
                    Task { await handlePayloadPicked(result) }
                }

            if !log.isEmpty {
                Divider().overlay(RockyTheme.mint.opacity(0.12))

                // A ScrollView takes every point it is offered, which left a tall empty box
                // before any log lines existed -- so give it just the height its rows need, up
                // to a cap, and let it scroll only past that.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(log.reversed(), id: \.self) { line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(RockyTheme.mintBright.opacity(0.6))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(height: min(220, CGFloat(log.count) * 15 + 4))
            }
        }
    }
    /// Gives an in-flight robot search a moment to land before starting a session, so tapping the
    /// orb the instant the app opens doesn't silently get a body-less Rocky while discovery was
    /// still a second away. Capped, and skipped entirely once the search has resolved.
    private func awaitRobotSearch() async {
        let start = Date()
        let deadline = start.addingTimeInterval(2.5)
        while Date() < deadline {
            if RobotSearchStatus.isSettled(
                connected: behavior.connected,
                searchFinished: behavior.searchFinished,
                hasHost: behavior.host != nil
            ) {
                RockyLog.write("voice: robot search settled in \(Int(Date().timeIntervalSince(start) * 1000))ms")
                return
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        RockyLog.write(
            "voice: waited \(Int(Date().timeIntervalSince(start) * 1000))ms for robot discovery; \(robotStatus)"
        )
    }

    private func toggleVoiceSession() async {
        // Re-entrancy guard. A tap that fails in a millisecond flips the button from disabled
        // back to enabled while the finger is still down, and SwiftUI delivers the touch again --
        // which, with an audio session that could not yet be reactivated, became an unbounded
        // retry loop that locked the interface up.
        guard !starting else { return }

        if voiceSession.state == .connected {
            // Pause, not disconnect: the conversation lives in the Realtime session, so ending it
            // would bring Rocky back with no memory of anything said.
            voiceSession.pause()
            starting = false
            appendLog("voice: paused")
            return
        }
        if voiceSession.state == .paused {
            behavior.reconnect()
            voiceSession.resume()
            appendLog("voice: resumed")
            return
        }

        // A fresh start after a real teardown races that teardown if it lands immediately.
        if let lastStopAt, Date().timeIntervalSince(lastStopAt) < 0.75 {
            RockyLog.write("voice: ignoring a start \(Int(Date().timeIntervalSince(lastStopAt) * 1000))ms after stopping")
            return
        }

        // Before anything that awaits, so the stone starts its loading animation on the touch
        // rather than after the robot search and the network have had their turn.
        starting = true
        voiceSession.markStarting()
        defer { starting = false }
        await awaitRobotSearch()
        appendLog("voice: connecting…")
        // No robot is fine and expected -- Rocky is then exactly the desktop app: a full
        // conversation, just without a body.
        await voiceSession.connect(behavior: behavior, characterID: selectedCharacterID)
        if case .failed(let message) = voiceSession.state {
            appendLog("voice: connect failed: \(message)")
        } else {
            appendLog("voice: connected")
        }
    }

    /// Pushes a picked payload straight to the CyberPi's bootstrap.py OTA listener (port 8766,
    /// separate from the motion agent's port 8765 used above) -- same host, no laptop involved.
    private func handlePayloadPicked(_ result: Result<URL, Error>) async {
        switch result {
        case .failure(let error):
            appendLog("payload pick failed: \(error.localizedDescription)")
        case .success(let url):
            guard let host = behavior.host else {
                appendLog("no robot found to push to")
                return
            }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let reply = try await CyberPiPusher.push(fileAt: url, to: host)
                appendLog("pushed \(url.lastPathComponent): \(reply)")
            } catch {
                appendLog("push failed: \(error.localizedDescription)")
            }
        }
    }

    private func appendLog(_ line: String) {
        log.append(line)
        if log.count > 50 {
            log.removeFirst(log.count - 50)
        }
        // In-memory `log` above is only visible while the app is open and foreground -- not
        // remotely readable and lost on backgrounding. RockyLog persists everything appendLog
        // ever sees to a file, pulled off the device after a test session the same way crash
        // reports are (see RockyLog.swift's header for the exact command).
        RockyLog.write(line)
    }
}

#Preview {
    ContentView()
}
