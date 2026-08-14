import SwiftUI
import UniformTypeIdentifiers

/// Deliberately bare: one screen, an address field, a listen toggle, and a log. This is the
/// "super minimal, installable" milestone -- prove the whole chain (mic -> command -> Wi-Fi ->
/// robot) works before any personality/UI investment. See apps/ios/README.md.
struct ContentView: View {
    @StateObject private var recognizer = VoiceCommandRecognizer()
    @StateObject private var discovery = RobotDiscovery()
    @State private var controller: RobotController?
    @State private var host = UserDefaults.standard.string(forKey: "robotHost") ?? ""
    @State private var connectionState = ConnectionState.disconnected
    @State private var log: [String] = []
    @State private var showPayloadPicker = false
    @State private var connectTask: Task<Void, Never>?
    @State private var pendingController: RobotController?

    enum ConnectionState: Equatable {
        case disconnected, connecting, connected, failed(String)
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Rocky").font(.largeTitle.bold())

            instructions

            statusBadge

            HStack {
                TextField("robot IP address", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.decimalPad)
                    #endif
                if connectionState == .connecting {
                    Button("Cancel") { cancelConnecting() }
                } else {
                    Button(connectionState == .connected ? "Disconnect" : "Connect") {
                        Task { await toggleConnection() }
                    }
                    .disabled(host.isEmpty)
                }
            }

            if let discovered = discovery.discoveredHost, discovered != host {
                Button("Found robot at \(discovered) — use it") { host = discovered }
                    .font(.caption)
            } else if discovery.isScanning {
                // The beacon (fast, passive) gets a few seconds before this active TCP scan
                // kicks in as a fallback -- worth surfacing, since a network scan taking a
                // couple of seconds shouldn't look like nothing is happening.
                Text("Scanning network for robot…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(recognizer.isListening ? "Stop Listening" : "Start Listening") {
                Task { await toggleListening() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(connectionState != .connected)

            if recognizer.isListening {
                // The whole interaction model in one line: what to say, and that there's no
                // separate "confirm" step -- just say a word and stop talking for a moment.
                Text("Say: forward · back · left · right · stop")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !recognizer.lastRecognizedText.isEmpty {
                Text("heard: \(recognizer.lastRecognizedText)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button("Push Payload to CyberPi…") { showPayloadPicker = true }
                .disabled(host.isEmpty)
                .fileImporter(isPresented: $showPayloadPicker, allowedContentTypes: [.item]) { result in
                    Task { await handlePayloadPicked(result) }
                }

            List(log.reversed(), id: \.self) { line in
                Text(line).font(.caption.monospaced())
            }
            .listStyle(.plain)
        }
        .padding()
        .onAppear {
            recognizer.onCommand = { command in
                Task { await send(command) }
            }
            discovery.start()
        }
        .onChange(of: discovery.discoveredHost) { _, newHost in
            // Auto-connect, not just auto-fill: the point of discovery is not having to do
            // anything by hand. Only when the host field was genuinely empty (no manually-typed
            // address to respect) and nothing's already connecting/connected -- a fresh beacon
            // arriving mid-session shouldn't yank an existing session out from under the user.
            guard let newHost, host.isEmpty, connectionState == .disconnected else { return }
            host = newHost
            Task { await toggleConnection() }
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("1. Connect below (auto-fills if the robot's found on Wi-Fi)")
            Text("2. Tap Start Listening")
            Text("3. Say one word: forward, back, left, right, or stop")
            Text("No need to pause before speaking -- it's always listening. A brief pause after helps it settle on the word.")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusBadge: some View {
        let (text, color): (String, Color) = switch connectionState {
        case .disconnected: ("not connected", .gray)
        case .connecting: ("connecting…", .yellow)
        case .connected: ("connected", .green)
        case .failed(let message): ("failed: \(message)", .red)
        }
        return Text(text).font(.caption).foregroundStyle(color)
    }

    private func toggleConnection() async {
        if connectionState == .connected {
            await controller?.disconnect()
            controller = nil
            connectionState = .disconnected
            recognizer.stop()
            return
        }

        UserDefaults.standard.set(host, forKey: "robotHost")
        connectionState = .connecting
        let newController = RobotController(host: host)
        pendingController = newController

        // A plain `try await` here is exactly what got stuck on a real device: RobotTCPTransport
        // now times out on its own (see connect(timeout:)), but wrapping the attempt in a
        // cancellable Task also lets the Cancel button above abort immediately instead of
        // waiting out that timeout.
        let task = Task {
            do {
                try await newController.connect()
                guard !Task.isCancelled else {
                    await newController.disconnect()
                    return
                }
                controller = newController
                pendingController = nil
                connectionState = .connected
                appendLog("connected to \(host)")
            } catch {
                guard !Task.isCancelled else { return }
                pendingController = nil
                connectionState = .failed(error.localizedDescription)
                appendLog("connect failed: \(error.localizedDescription)")
            }
        }
        connectTask = task
        await task.value
    }

    private func cancelConnecting() {
        connectTask?.cancel()
        connectTask = nil
        Task { await pendingController?.disconnect() }
        pendingController = nil
        connectionState = .disconnected
        appendLog("connect cancelled")
    }

    private func toggleListening() async {
        if recognizer.isListening {
            recognizer.stop()
            return
        }
        guard await recognizer.requestAuthorization() else {
            appendLog("speech/microphone permission denied")
            return
        }
        recognizer.start()
    }

    private func send(_ command: RobotVoiceCommand) async {
        guard let controller else { return }
        appendLog("command: \(command)")
        do {
            try await controller.perform(command)
        } catch {
            appendLog("command failed: \(error.localizedDescription)")
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
