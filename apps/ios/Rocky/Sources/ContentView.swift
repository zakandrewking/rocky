import SwiftUI
import UniformTypeIdentifiers

/// One screen, built to look and behave like apps/desktop: Rocky's stone orb on a dark starfield
/// (OrbView / RockyTheme, both ported from that app's styles.css) and a small monospaced state
/// chip pinned to the bottom corner that expands into details -- desktop's `.debug-state`.
///
/// The orb is the only control. The robot connection has no manual UI at all: it is discovered
/// and connected automatically (RobotDiscovery), the same way desktop's own plumbing is invisible.
struct ContentView: View {
    @StateObject private var voiceSession = RealtimeVoiceSession()
    @StateObject private var discovery = RobotDiscovery()
    @State private var controller: RobotController?
    @State private var host = UserDefaults.standard.string(forKey: "robotHost") ?? ""
    @State private var connectionState = ConnectionState.disconnected
    @State private var log: [String] = []
    @State private var showPayloadPicker = false
    @State private var detailsOpen = false
    @State private var robotSearchReported = false

    enum ConnectionState: Equatable {
        case disconnected, connecting, connected, failed(String)
    }

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
            discovery.start()
            // The one path that used to be a manual "Connect" button tap, now automatic: retry
            // with whatever host we last connected to successfully.
            if !host.isEmpty, connectionState == .disconnected {
                Task { await connectRobotIfNeeded() }
            }
        }
        .onChange(of: discovery.discoveredHost) { _, newHost in
            // No manual fallback left, so this has to actually finish the job: connect whenever
            // discovery finds a *different* address than whatever we're using, as long as nothing
            // is already connected/connecting -- covers both "never connected yet" and "the
            // on-appear retry above hit a stale IP."
            guard let newHost, newHost != host, connectionState != .connected, connectionState != .connecting else { return }
            host = newHost
            Task { await connectRobotIfNeeded() }
        }
    }

    // MARK: - The one control

    private var hasBakedOpenAIKey: Bool {
        !((Bundle.main.object(forInfoDictionaryKey: "RockyOpenAIKey") as? String) ?? "").isEmpty
    }

    /// Voice state only. Finding the robot is background work the user should never watch, so it
    /// deliberately does not reach the orb -- a missing robot is not an error, just a Rocky with
    /// no body (exactly what apps/desktop is).
    private var orbPhase: OrbPhase {
        if case .failed = voiceSession.state { return .error }
        switch voiceSession.state {
        case .connecting: return .connecting
        case .connected: return .listening
        default: return .idle
        }
    }

    private var orbTappable: Bool {
        hasBakedOpenAIKey && voiceSession.state != .connecting
    }

    private var orbLabel: String {
        voiceSession.state == .connected ? "End conversation" : "Start conversation"
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

    // MARK: - State chip (desktop's `.debug-state`)

    private var phaseWord: String {
        if case .failed = voiceSession.state { return "error" }
        switch voiceSession.state {
        case .connecting: return "connecting"
        case .connected: return "listening"
        default: return "idle"
        }
    }

    private var chipDetail: String {
        let robot: String = switch connectionState {
        case .disconnected: "-"
        case .connecting: "…"
        case .connected: host
        case .failed: "failed"
        }
        let voice: String = switch voiceSession.state {
        case .disconnected: "-"
        case .connecting: "…"
        case .connected: "on"
        case .failed: "failed"
        }
        return "r:\(robot) v:\(voice)\(hasBakedOpenAIKey ? "" : " k:missing")"
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
            Text("Tap the stone to talk. If the robot is on the same Wi-Fi it connects itself, and Rocky can drive; if not, she is still here to talk.")
                .foregroundStyle(RockyTheme.mintBright.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)

            if case .failed(let message) = connectionState {
                // Informational, not an error state: voice works fine without a body.
                Text("no robot: \(message)").foregroundStyle(RockyTheme.mint.opacity(0.6))
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

            Button("push payload to cyberpi…") { showPayloadPicker = true }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(RockyTheme.amberBright.opacity(0.76))
                .disabled(host.isEmpty)
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

    // MARK: - Behaviour (unchanged)

    /// The only path into a robot connection -- called on launch (last-known host) and whenever
    /// RobotDiscovery finds a new address. No user-facing trigger, no cancel, and deliberately
    /// only ever one line in the log: finding the body is plumbing, not something to watch.
    private func connectRobotIfNeeded() async {
        guard !host.isEmpty, connectionState != .connected, connectionState != .connecting else { return }
        UserDefaults.standard.set(host, forKey: "robotHost")
        connectionState = .connecting
        let newController = RobotController(host: host)
        do {
            try await newController.connect()
            controller = newController
            connectionState = .connected
            reportRobotSearchOnce("robot found at \(host)")
        } catch {
            connectionState = .failed(error.localizedDescription)
            // Not surfaced as a failure to the user: no robot just means voice-only Rocky. The
            // detail panel still carries the reason for anyone who opens it.
            RockyLog.write("robot connect failed: \(error.localizedDescription)")
        }
    }

    /// Exactly one robot line ever reaches the visible log, whichever way the search ends.
    private func reportRobotSearchOnce(_ message: String) {
        guard !robotSearchReported else { return }
        robotSearchReported = true
        appendLog(message)
    }

    /// Gives an in-flight robot search a moment to land before starting a session, so tapping the
    /// orb the instant the app opens doesn't silently get a body-less Rocky while discovery was
    /// still a second away. Capped, and skipped entirely once the search has resolved.
    private func awaitRobotSearch() async {
        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            if connectionState == .connected || robotSearchReported { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        reportRobotSearchOnce("no robot found — voice only")
    }

    private func toggleVoiceSession() async {
        if voiceSession.state == .connected {
            voiceSession.disconnect()
            appendLog("voice: disconnected")
            return
        }
        await awaitRobotSearch()
        appendLog("voice: connecting…")
        // A nil controller is fine and expected when no robot answered -- Rocky is then exactly
        // the desktop app: a full conversation, just without a body to drive.
        await voiceSession.connect(robot: controller)
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
