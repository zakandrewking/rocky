import SwiftUI

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
/// The orb owns conversation only. Robot discovery starts with the app and has its own visible
/// connect/retry control, so driving and accessory controls never depend on whether Rocky is
/// currently talking.
struct ContentView: View {
    @StateObject private var voiceSession = RealtimeVoiceSession()
    /// The one robot integration: finds the board, watches what it does, and passes Rocky's
    /// intentions back. There is one payload (apps/robot/device/rocky_agent.py) and so one
    /// connection -- the older commanded-motion agent and its separate discovery are deprecated.
    @StateObject private var behavior = BehaviorMonitor()
    /// Runs for exactly the lifetime of a voice conversation -- started and stopped by the
    /// `voiceSession.state` observer below, never idling on while the app is merely open. See
    /// `PersonCamera`'s header for the reasoning.
    @StateObject private var personCamera = PersonCamera()
    @State private var log: [String] = []
    @State private var showBodyPanel = false
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

            if behavior.connected {
                HStack {
                    ServoSideControl(port: "S3") { angle, immediate in
                        behavior.setServo(port: "S3", angle: angle, immediately: immediate)
                    }
                    Spacer(minLength: 0)
                    ServoSideControl(port: "S4") { angle, immediate in
                        behavior.setServo(port: "S4", angle: angle, immediately: immediate)
                    }
                }
                .padding(.horizontal, 10)
            }

            if behavior.connected && !detailsOpen {
                VStack {
                    Spacer()
                    ManualDriveControls(connected: behavior.connected) {
                        throttle, steering, active in
                        behavior.setManualDrive(
                            throttle: throttle, steering: steering, active: active
                        )
                    }
                }
                .padding(.bottom, 18)
            }

            VStack {
                Spacer()
                HStack {
                    stateChip
                    Spacer(minLength: 0)
                }
            }
            .padding(14)

            if voiceSession.state == .connected && personCamera.isRunning {
                VStack {
                    HStack {
                        Spacer(minLength: 0)
                        selfiePreview
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .transition(.scale(scale: 0.92, anchor: .topTrailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: personCamera.isRunning)
        .preferredColorScheme(.dark)
        .onAppear {
            behavior.start()
            voiceSession.useFreshLookRequester { [weak personCamera] moment in
                personCamera?.requestFreshLook(capturedAfter: moment)
            }
        }
        .onChange(of: behavior.connected) { _, found in
            voiceSession.bodyAvailabilityChanged(found)
        }
        .onChange(of: voiceSession.state) { _, state in
            handleVoiceStateChangeForCamera(state)
        }
        .onChange(of: personCamera.lastSample) { _, sample in
            if let sample { voiceSession.updateVision(sample) }
        }
        .onChange(of: personCamera.isRunning) { _, running in
            voiceSession.eyesAvailabilityChanged(running)
        }
    }

    /// A quiet confirmation that Rocky's eyes are open. It is deliberately just the live image:
    /// detection prose and controls stay in the debug sheet, while the everyday conversation view
    /// gets the familiar FaceTime-style picture-in-picture treatment.
    private var selfiePreview: some View {
        CameraPreview(session: personCamera.session)
            .frame(width: 108, height: 144)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.4), radius: 12, y: 5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Rocky's eyes follow her voice: on the instant a conversation connects (including a resume
    /// from pause), off the instant it stops being live. This is the camera's entire on/off story
    /// -- see `PersonCamera`'s header for why that's still a defensible privacy line even without
    /// a manual switch: it is never on for a mere-open app, only for a conversation the person
    /// themselves just started.
    private func handleVoiceStateChangeForCamera(_ state: RealtimeVoiceSession.State) {
        switch state {
        case .connecting, .connected:
            guard !personCamera.isRunning else { return }
            Task { await personCamera.start() }
        case .disconnected, .paused, .failed:
            guard personCamera.isRunning else { return }
            personCamera.stop()
        }
    }

    // MARK: - Conversation control

    private var hasBakedOpenAIKey: Bool {
        !((Bundle.main.object(forInfoDictionaryKey: "RockyOpenAIKey") as? String) ?? "").isEmpty
    }

    /// Voice state only. Robot connection has its own control and deliberately does not reach the
    /// orb -- a missing robot is not a voice error.
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
        return "\(bodyDescription) v:\(voice)\(hasBakedOpenAIKey ? "" : " k:missing")"
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
            Text(robotStatus)
                .foregroundStyle(RockyTheme.mint.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)

            if !behavior.connected {
                Button {
                    RockyLog.write("behavior: person requested a fresh robot connection")
                    behavior.reconnect()
                } label: {
                    Label(
                        behavior.searchFinished ? "connect robot…" : "connecting to robot…",
                        systemImage: "antenna.radiowaves.left.and.right"
                    )
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(RockyTheme.amberBright.opacity(0.82))
                .disabled(!behavior.searchFinished && behavior.host == nil)
                .accessibilityHint("Searches the local network again")
            }

            if behavior.connected {
                Text("Robot control is ready. The sliders temporarily take over; autonomy resumes shortly after the drive controls are released.")
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
        await voiceSession.connect(behavior: behavior)
        if case .failed(let message) = voiceSession.state {
            appendLog("voice: connect failed: \(message)")
        } else {
            appendLog("voice: connected")
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

/// Two spring-return controls with a device-side watchdog behind them. While either thumb is down,
/// a 10 Hz heartbeat owns the wheels; releasing the final thumb sends an immediate stop and starts
/// the board's short, stationary handoff back to its autonomous state machine.
private struct ManualDriveControls: View {
    let connected: Bool
    let send: (_ throttle: Double, _ steering: Double, _ active: Bool) -> Void

    @State private var throttle = 0.0
    @State private var steering = 0.0
    @State private var throttleHeld = false
    @State private var steeringHeld = false
    @State private var heartbeat: Task<Void, Never>?

    private var active: Bool { throttleHeld || steeringHeld }

    var body: some View {
        VStack(spacing: 8) {
            driveRow(
                title: "DRIVE", low: "BACK", high: "FWD",
                value: $throttle,
                editingChanged: { setEditing($0, axis: .throttle) }
            )
            driveRow(
                title: "STEER", low: "LEFT", high: "RIGHT",
                value: $steering,
                editingChanged: { setEditing($0, axis: .steering) }
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 220)
        .background {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(RockyTheme.ink.opacity(0.7))
                .overlay {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .stroke(RockyTheme.mint.opacity(connected ? 0.14 : 0.07), lineWidth: 1)
                }
        }
        .opacity(connected ? 1 : 0.55)
        .onChange(of: connected) { _, isConnected in
            if !isConnected { resetWithoutSending() }
        }
        .onDisappear { releaseAll() }
    }

    private enum Axis { case throttle, steering }

    private func driveRow(
        title: String,
        low: String,
        high: String,
        value: Binding<Double>,
        editingChanged: @escaping (Bool) -> Void
    ) -> some View {
        VStack(spacing: 1) {
            HStack {
                Text(low)
                Spacer()
                Text(title).foregroundStyle(RockyTheme.amberBright.opacity(0.82))
                Spacer()
                Text(high)
            }
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundStyle(RockyTheme.mint.opacity(0.58))

            Slider(value: value, in: -1...1, onEditingChanged: editingChanged)
                .tint(RockyTheme.amberBright)
                .disabled(!connected)
                .accessibilityLabel(title == "DRIVE" ? "Drive forward and backward" : "Steer left and right")
                .accessibilityValue("\(Int(value.wrappedValue * 100)) percent")
        }
    }

    private func setEditing(_ editing: Bool, axis: Axis) {
        guard connected else { return }
        switch axis {
        case .throttle:
            throttleHeld = editing
            if !editing { throttle = 0 }
        case .steering:
            steeringHeld = editing
            if !editing { steering = 0 }
        }

        if active {
            send(throttle, steering, true)
            startHeartbeatIfNeeded()
        } else {
            heartbeat?.cancel()
            heartbeat = nil
            send(0, 0, false)
        }
    }

    private func startHeartbeatIfNeeded() {
        guard heartbeat == nil else { return }
        heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
                guard connected, active else { return }
                send(throttle, steering, true)
            }
        }
    }

    private func releaseAll() {
        let shouldSend = connected && active
        resetWithoutSending()
        if shouldSend { send(0, 0, false) }
    }

    private func resetWithoutSending() {
        heartbeat?.cancel()
        heartbeat = nil
        throttleHeld = false
        steeringHeld = false
        throttle = 0
        steering = 0
    }
}

#Preview {
    ContentView()
}
