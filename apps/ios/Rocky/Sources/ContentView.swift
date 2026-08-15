import SwiftUI
import UniformTypeIdentifiers

/// One screen, matching apps/desktop's minimalism: a single circular control that starts/stops
/// talking to Rocky, plus a tappable detail row that expands into status, warnings, and the log --
/// mirroring desktop's orb button + debug chip. The robot connection itself has no manual control
/// at all anymore (no IP field, no Connect/Cancel/Disconnect) -- it's purely automatic, driven by
/// RobotDiscovery's beacon/scan, exactly like device-api's connection is invisible on desktop.
struct ContentView: View {
    @StateObject private var voiceSession = RealtimeVoiceSession()
    @StateObject private var discovery = RobotDiscovery()
    @State private var controller: RobotController?
    @State private var host = UserDefaults.standard.string(forKey: "robotHost") ?? ""
    @State private var connectionState = ConnectionState.disconnected
    @State private var log: [String] = []
    @State private var showPayloadPicker = false
    @State private var detailsOpen = false

    enum ConnectionState: Equatable {
        case disconnected, connecting, connected, failed(String)
    }

    private enum OrbPhase {
        case findingRobot, robotFailed, ready, connectingVoice, talking, voiceFailed
    }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            orb
            Spacer()
            detailArea
        }
        .padding()
        .onAppear {
            discovery.start()
            // The one path that used to be a manual "Connect" button tap, now automatic: retry
            // with whatever host we last connected to successfully, same address the field used
            // to be pre-filled with.
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

    private var hasBakedOpenAIKey: Bool {
        !((Bundle.main.object(forInfoDictionaryKey: "RockyOpenAIKey") as? String) ?? "").isEmpty
    }

    private var orbPhase: OrbPhase {
        if case .failed = voiceSession.state { return .voiceFailed }
        if voiceSession.state == .connecting { return .connectingVoice }
        if voiceSession.state == .connected { return .talking }
        if case .failed = connectionState { return .robotFailed }
        if connectionState != .connected { return .findingRobot }
        return .ready
    }

    private var orbLabel: String {
        switch orbPhase {
        case .findingRobot: return "Finding\nRobot…"
        case .robotFailed: return "Robot Not\nFound"
        case .ready: return "Talk to\nRocky"
        case .connectingVoice: return "Connecting…"
        case .talking: return "Listening…"
        case .voiceFailed: return "Voice Failed\nTap to Retry"
        }
    }

    private var orbColor: Color {
        switch orbPhase {
        case .findingRobot: return .gray
        case .robotFailed, .voiceFailed: return .red
        case .ready: return .blue
        case .connectingVoice: return .yellow
        case .talking: return .green
        }
    }

    private var orbTappable: Bool {
        switch orbPhase {
        case .ready, .talking, .voiceFailed: return hasBakedOpenAIKey
        case .findingRobot, .robotFailed, .connectingVoice: return false
        }
    }

    private var orb: some View {
        Button {
            Task { await toggleVoiceSession() }
        } label: {
            Circle()
                .fill(orbColor.opacity(0.85))
                .frame(width: 190, height: 190)
                .overlay {
                    Text(orbLabel)
                        .multilineTextAlignment(.center)
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                }
        }
        .buttonStyle(.plain)
        .disabled(!orbTappable)
        .opacity(orbTappable || orbPhase == .connectingVoice ? 1 : 0.5)
    }

    private var detailSummary: String {
        var parts: [String] = []
        switch connectionState {
        case .disconnected: parts.append(discovery.isScanning ? "scanning for robot" : "robot: not connected")
        case .connecting: parts.append("robot: connecting")
        case .connected: parts.append("robot: \(host)")
        case .failed(let message): parts.append("robot failed: \(message)")
        }
        if !hasBakedOpenAIKey { parts.append("no OpenAI key baked in") }
        return parts.joined(separator: " · ")
    }

    private var detailArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(detailSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Image(systemName: detailsOpen ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { detailsOpen.toggle() }

            if detailsOpen {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connects to the robot on Wi-Fi automatically. Tap the circle to talk — ask Rocky to look around, drive, or stop.")
                        .font(.caption)

                    if !hasBakedOpenAIKey {
                        Text("Run apps/ios/scripts/generate.sh with OPENAI_API_KEY set, then rebuild.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if let toolCall = voiceSession.lastToolCall {
                        Text("last action: \(toolCall)").font(.caption).foregroundStyle(.secondary)
                    }

                    Button("Push Payload to CyberPi…") { showPayloadPicker = true }
                        .font(.caption)
                        .disabled(host.isEmpty)
                        .fileImporter(isPresented: $showPayloadPicker, allowedContentTypes: [.item]) { result in
                            Task { await handlePayloadPicked(result) }
                        }

                    Divider()

                    List(log.reversed(), id: \.self) { line in
                        Text(line).font(.caption2.monospaced())
                    }
                    .listStyle(.plain)
                    .frame(minHeight: 160)
                }
            }
        }
    }

    /// The only path into a robot connection now -- called on launch (last-known host) and
    /// whenever RobotDiscovery finds a new address. No user-facing trigger or cancel.
    private func connectRobotIfNeeded() async {
        guard !host.isEmpty, connectionState != .connected, connectionState != .connecting else { return }
        UserDefaults.standard.set(host, forKey: "robotHost")
        connectionState = .connecting
        let newController = RobotController(host: host)
        do {
            try await newController.connect()
            controller = newController
            connectionState = .connected
            appendLog("connected to \(host)")
        } catch {
            connectionState = .failed(error.localizedDescription)
            appendLog("connect failed: \(error.localizedDescription)")
        }
    }

    private func toggleVoiceSession() async {
        if voiceSession.state == .connected {
            voiceSession.disconnect()
            appendLog("voice: disconnected")
            return
        }
        guard let controller else { return }
        appendLog("voice: connecting…")
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
