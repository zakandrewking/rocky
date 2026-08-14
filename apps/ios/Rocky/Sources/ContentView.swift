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

    enum ConnectionState: Equatable {
        case disconnected, connecting, connected, failed(String)
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Rocky").font(.largeTitle.bold())

            statusBadge

            HStack {
                TextField("robot IP address", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.decimalPad)
                    #endif
                Button(connectionState == .connected ? "Disconnect" : "Connect") {
                    Task { await toggleConnection() }
                }
                .disabled(host.isEmpty || connectionState == .connecting)
            }

            if let discovered = discovery.discoveredHost, discovered != host {
                Button("Found robot at \(discovered) — use it") { host = discovered }
                    .font(.caption)
            }

            Button(recognizer.isListening ? "Stop Listening" : "Start Listening") {
                Task { await toggleListening() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(connectionState != .connected)

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
            if let newHost, host.isEmpty {
                host = newHost
            }
        }
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
    }
}

#Preview {
    ContentView()
}
