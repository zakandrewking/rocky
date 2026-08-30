import Foundation
import Network

/// One thing the robot did, as history rather than status. Kept for the on-screen debug list;
/// the world model gets the richer BehaviorMessage below.
struct BehaviorEvent: Sendable, Equatable {
    let mode: String
    let detail: String
    let at: Date

    var secondsAgo: Double { Date().timeIntervalSince(at) }
}

/// What the board just said, in the board's own vocabulary.
///
/// Deliberately untranslated. `rocky_agent.py` speaks in state-machine names ("dizzy",
/// "recovering") that came out of eleven versions of motion tuning and mean nothing to a person;
/// turning them into something Rocky could say is BehaviorWorldSource's job, and keeping the two
/// apart means the tuning record and the character can each change without the other.
enum BehaviorMessage: Sendable {
    case hello(mode: String, mood: String)
    case transition(mode: String, detail: String)
    case snapshot(mode: String, mood: String)
    case acknowledged(of: String, id: String?)
    case disconnected
}

/// Watches the robot's autonomous behaviour (apps/robot/device/rocky_agent.py) and passes the
/// voice character's intentions back to it.
///
/// The two loops run on incompatible clocks, and that shapes this whole class. The motion loop
/// decides at ~20Hz and its reactions last 0.3-4 seconds; the voice character cannot produce a
/// spoken word in under about two seconds. So "what are you doing right now" is a stale question
/// by the time anyone answers it, and this deliberately keeps *history* instead: by the time
/// Rocky says "something loud scared me and I ran", the running is over, and that sentence is
/// still true. Ages travel with every event so he can say it in the right tense.
///
/// The same asymmetry runs the other way: what goes back is Rocky's intentions, not a person's
/// commands. Once Rocky chooses a physical expression, the board honours it immediately.
@MainActor
final class BehaviorMonitor: ObservableObject {
    /// How much history to keep. Long enough to describe "the last little while", short enough
    /// that nothing stale gets narrated as news.
    private static let historyWindow: TimeInterval = 90
    private static let maxEvents = 40

    @Published private(set) var host: String?
    @Published private(set) var connected = false
    @Published private(set) var controlReady = false
    var controlsConnected: Bool { connected && controlReady }
    /// True once the sweep has finished, however it ended -- so nothing has to guess whether
    /// "no robot" means "none there" or "still looking".
    @Published private(set) var searchFinished = false
    @Published private(set) var mode = "unknown"
    @Published private(set) var mood = "still"
    @Published private(set) var events: [BehaviorEvent] = []
    /// Last positions the board itself acknowledged, useful when a mechanical report comes in.
    @Published private(set) var servoAngles = ["S3": 90, "S4": 90]

    /// Every line the board sends, verbatim in its own vocabulary. Deciding what any of it means
    /// -- and whether it is worth saying anything about -- happens downstream, in the world model.
    /// This used to be an `onNotableEvent` hook that went straight to "make Rocky talk about it",
    /// which conflated two questions that turn out to have different answers: should she know,
    /// and should she interrupt herself.
    var onBoardMessage: ((BehaviorMessage) -> Void)?

    private let beaconPort: NWEndpoint.Port
    private let eventPort: NWEndpoint.Port
    private let controlPort: NWEndpoint.Port = 8769
    private var listener: NWListener?
    private var connection: NWConnection?
    private var controlConnection: NWConnection?
    private var scanTask: Task<Void, Never>?
    private var buffer = ""
    /// Lifecycle mood commands can cross on the wire when pause is tapped twice quickly. Keep the
    /// newest request separate from confirmed telemetry so resume can reverse an in-flight still
    /// without pretending the board has already applied either command.
    private var requestedMood: String?
    /// Slider drags can produce a value every display frame, so coalesce each servo independently
    /// before publishing a complete newest-state datagram. Applied reports are diagnostic evidence,
    /// never flow control.
    private struct ServoTarget: Equatable {
        let angle: Int
    }
    private var pendingServoTargets: [String: ServoTarget] = [:]
    private var servoSendTasks: [String: Task<Void, Never>] = [:]
    private var servoSentAt: [String: Date] = [:]
    private var servoSentTargets: [String: ServoTarget] = [:]
    private var servoLastAcceptedSentAt: [String: Date] = [:]
    private var servoPhysicalTargets: [String: (angle: Int, sentAt: Date)] = [:]
    private var latestServoID: [String: String] = [:]
    private var servoAckTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var manualDriveSentAt: [String: Date] = [:]
    private var lastManualDriveLogAt = Date.distantPast
    private let controlEpoch = Int64(Date().timeIntervalSince1970 * 1_000)
    private var controlSequence = 0
    private var controlServoTargets: [String: Int] = [:]
    private var controlThrottle = 0.0
    private var controlSteering = 0.0
    private var controlDriveActive = false
    private var controlSentAt: [Int: (at: Date, reason: String)] = [:]
    private var controlStopRepeatTask: Task<Void, Never>?

    init(beaconPort: UInt16 = 41900, eventPort: UInt16 = 8768) {
        self.beaconPort = NWEndpoint.Port(rawValue: beaconPort) ?? 41900
        self.eventPort = NWEndpoint.Port(rawValue: eventPort) ?? 8768
    }

    // MARK: - Finding the robot

    func start() {
        if listener == nil {
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            if let listener = try? NWListener(using: params, on: beaconPort) {
                listener.newConnectionHandler = { [weak self] incoming in
                    Task { @MainActor in self?.readBeacon(incoming) }
                }
                listener.start(queue: .main)
                self.listener = listener
                RockyLog.write("behavior: listening for the robot's beacon")
            }
        }
        reconnect()
    }

    /// Starts a fresh discovery pass when the app appears or voice comes back from pause.
    /// A failed connection and completed task used to remain installed, suppressing later scans.
    func reconnect(force: Bool = false) {
        if force {
            RockyLog.write("behavior: foregrounded; replacing the possibly stale robot connection")
            scanTask?.cancel()
            scanTask = nil
            connection?.cancel()
            connection = nil
            connected = false
            requestedMood = nil
            cancelServoSends()
        }
        guard !connected, scanTask == nil else { return }
        connection?.cancel()
        connection = nil
        controlConnection?.cancel()
        controlConnection = nil
        controlReady = false
        buffer = ""
        searchFinished = false
        RockyLog.write("behavior: trying to reconnect to the robot")

        // The beacon is only a fast path, and on this hardware the sweep is the reliable path.
        // Keep listening for beacons, but make each reconnect request launch a fresh bounded scan.
        scanTask = Task { [weak self] in
            await self?.scanForRobot()
            guard !Task.isCancelled else { return }
            self?.scanTask = nil
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        scanTask?.cancel()
        scanTask = nil
        connection?.cancel()
        connection = nil
        controlConnection?.cancel()
        controlConnection = nil
        controlReady = false
        connected = false
        requestedMood = nil
        cancelServoSends()
    }

    private struct Beacon: Decodable {
        let service: String
        let tcpPort: Int
    }

    private func readBeacon(_ incoming: NWConnection) {
        incoming.stateUpdateHandler = { [weak self] state in
            guard case .ready = state else { return }
            incoming.receiveMessage { data, _, _, _ in
                if let data {
                    Task { @MainActor in self?.handleBeacon(data, from: incoming.endpoint) }
                }
                incoming.cancel()
            }
        }
        incoming.start(queue: .main)
    }

    private func handleBeacon(_ data: Data, from endpoint: NWEndpoint) {
        // A different service name from the motion agent's, so the app's existing robot discovery
        // ignores this board rather than trying to drive a motion server that isn't running.
        guard let beacon = try? JSONDecoder().decode(Beacon.self, from: data),
            beacon.service == "rocky-behavior",
            case let .hostPort(sender, _) = endpoint, case let .ipv4(address) = sender
        else { return }
        let found = "\(address)"
        guard found != host || connection == nil else { return }
        host = found
        connect(to: found, port: beacon.tcpPort)
    }

    /// Sweeps this phone's own /24 once, looking for the robot.
    private func scanForRobot() async {
        guard let prefix = NetworkUtilities.localSubnetPrefix() else {
            searchFinished = true
            return
        }
        RockyLog.write("robot: sweeping \(prefix)0/24 for a body on :\(eventPort.rawValue)")

        var candidates = Array(1...254)
        if let saved = UserDefaults.standard.string(forKey: "behaviorHost"),
            saved.hasPrefix(prefix), let last = Int(saved.split(separator: ".").last.map(String.init) ?? ""),
            let index = candidates.firstIndex(of: last) {
            candidates.remove(at: index)
            candidates.insert(last, at: 0)
        }

        let port = eventPort
        for batchStart in stride(from: 0, to: candidates.count, by: 32) {
            if Task.isCancelled || connection != nil { return }
            let batch = candidates[batchStart..<min(batchStart + 32, candidates.count)]
            let hit = await withTaskGroup(of: String?.self) { group in
                for octet in batch {
                    let address = "\(prefix)\(octet)"
                    group.addTask { await Self.probe(host: address, port: port) }
                }
                var winner: String?
                for await result in group where result != nil {
                    if winner == nil { winner = result; group.cancelAll() }
                }
                return winner
            }
            if let address = hit {
                UserDefaults.standard.set(address, forKey: "behaviorHost")
                host = address
                searchFinished = true
                RockyLog.write("robot: found at \(address)")
                connect(to: address, port: Int(port.rawValue))
                return
            }
        }
        searchFinished = true
        RockyLog.write("robot: sweep finished, nothing out there — voice only")
    }

    private static func probe(host: String, port: NWEndpoint.Port) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let probe = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            nonisolated(unsafe) var settled = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard !settled else { return }
                settled = true
                probe.cancel()
                continuation.resume(returning: nil)
            }
            probe.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard !settled else { return }
                    settled = true
                    probe.cancel()
                    continuation.resume(returning: host)
                case .failed, .cancelled:
                    guard !settled else { return }
                    settled = true
                    continuation.resume(returning: nil)
                default:
                    break
                }
            }
            probe.start(queue: .main)
        }
    }

    private func connect(to host: String, port: Int) {
        connection?.cancel()
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                switch state {
                case .ready:
                    self.connected = true
                    RockyLog.write("behavior: watching the robot at \(host):\(port)")
                    self.startControlChannel(host: host)
                    self.receive()
                case .failed, .cancelled:
                    if self.connected {
                        RockyLog.write("robot: lost the behaviour connection")
                        self.onBoardMessage?(.disconnected)
                    }
                    self.connected = false
                    self.controlConnection?.cancel()
                    self.controlConnection = nil
                    self.controlReady = false
                    self.requestedMood = nil
                    self.cancelServoSends()
                    self.connection = nil
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty { self.ingest(data) }
                if isComplete || error != nil {
                    if self.connected { self.onBoardMessage?(.disconnected) }
                    self.connected = false
                    self.requestedMood = nil
                    self.cancelServoSends()
                    self.controlConnection?.cancel()
                    self.controlConnection = nil
                    self.controlReady = false
                    self.connection?.cancel()
                    self.connection = nil
                    return
                }
                self.receive()
            }
        }
    }

    private func startControlChannel(host: String) {
        controlConnection?.cancel()
        controlReady = false
        let control = NWConnection(
            host: NWEndpoint.Host(host), port: controlPort, using: .udp
        )
        controlConnection = control
        control.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.controlConnection === control else { return }
                switch state {
                case .ready:
                    self.controlReady = true
                    RockyLog.write(
                        "control: newest-state UDP ready at \(host):\(self.controlPort.rawValue)"
                    )
                case .failed(let error):
                    self.controlReady = false
                    RockyLog.write("control: UDP channel failed: \(error.localizedDescription)")
                    self.controlConnection = nil
                default:
                    break
                }
            }
        }
        control.start(queue: .main)
    }

    // MARK: - What the robot says

    private func ingest(_ data: Data) {
        buffer += String(decoding: data, as: UTF8.self)
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<newline])
            buffer = String(buffer[buffer.index(after: newline)...])
            guard let payload = line.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
            else { continue }
            handle(object)
        }
    }

    private func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "event":
            let event = BehaviorEvent(
                mode: message["mode"] as? String ?? "?",
                detail: message["detail"] as? String ?? "",
                at: Date()
            )
            mode = event.mode
            append(event)
            onBoardMessage?(.transition(mode: event.mode, detail: event.detail))
        case "snapshot":
            mode = message["mode"] as? String ?? mode
            mood = message["mood"] as? String ?? mood
            if requestedMood == mood { requestedMood = nil }
            onBoardMessage?(.snapshot(mode: mode, mood: mood))
        case "hello":
            mode = message["mode"] as? String ?? mode
            mood = message["mood"] as? String ?? mood
            if requestedMood == mood { requestedMood = nil }
            RockyLog.write("behavior: robot says hello (mode \(mode), mood \(mood))")
            onBoardMessage?(.hello(mode: mode, mood: mood))
        case "servo_position":
            let port = message["port"] as? String ?? "?"
            let angle = message["angle"] as? Int ?? -1
            if servoAngles[port] != nil { servoAngles[port] = angle }
            let elapsed = servoPhysicalTargets[port].flatMap { target in
                target.angle == angle
                    ? " in \(Int(Date().timeIntervalSince(target.sentAt) * 1_000))ms"
                    : nil
            } ?? ""
            if servoPhysicalTargets[port]?.angle == angle {
                servoPhysicalTargets.removeValue(forKey: port)
            }
            RockyLog.write("servo: board reached \(port) \(angle)°\(elapsed)")
        case "control_applied":
            handleControlApplied(message)
        case "ack":
            if message["of"] as? String == "servo" {
                handleServoAcknowledgement(message)
                return
            }
            if message["of"] as? String == "manual_drive" {
                handleManualDriveAcknowledgement(message)
                return
            }
            if message["of"] as? String == "mood", let confirmed = message["mood"] as? String {
                mood = confirmed
                if requestedMood == confirmed { requestedMood = nil }
            }
            onBoardMessage?(
                .acknowledged(of: message["of"] as? String ?? "", id: (message["id"] as? String).flatMap { $0.isEmpty ? nil : $0 })
            )
        default:
            break
        }
    }

    private func append(_ event: BehaviorEvent) {
        events.append(event)
        events.removeAll { $0.secondsAgo > Self.historyWindow }
        if events.count > Self.maxEvents { events.removeFirst(events.count - Self.maxEvents) }
        RockyLog.write("behavior: \(event.mode)\(event.detail.isEmpty ? "" : " (\(event.detail))")")
    }

    // MARK: - What the character would like

    private func send(_ message: [String: Any]) {
        guard connected, let connection,
            let data = try? JSONSerialization.data(withJSONObject: message)
        else { return }
        connection.send(content: data + Data("\n".utf8), completion: .idempotent)
    }

    private func cancelServoSends() {
        servoSendTasks.values.forEach { $0.cancel() }
        servoAckTimeoutTasks.values.forEach { $0.cancel() }
        servoSendTasks.removeAll()
        servoAckTimeoutTasks.removeAll()
        pendingServoTargets.removeAll()
        servoSentAt.removeAll()
        servoSentTargets.removeAll()
        servoLastAcceptedSentAt.removeAll()
        servoPhysicalTargets.removeAll()
        latestServoID.removeAll()
        manualDriveSentAt.removeAll()
        controlStopRepeatTask?.cancel()
        controlStopRepeatTask = nil
        controlSentAt.removeAll()
        controlServoTargets.removeAll()
        controlThrottle = 0
        controlSteering = 0
        controlDriveActive = false
    }

    private func handleControlApplied(_ message: [String: Any]) {
        let sequence = (message["seq"] as? NSNumber)?.intValue ?? -1
        let trace = controlSentAt.removeValue(forKey: sequence)
        let elapsed = trace.map { " in \(Int(Date().timeIntervalSince($0.at) * 1_000))ms" } ?? ""
        let active = message["active"] as? Bool == true
        let left = message["left_rpm"] as? Int ?? 0
        let right = message["right_rpm"] as? Int ?? 0
        var details: [String] = []
        if let s3 = message["s3"] as? Int { details.append("S3=\(s3)°") }
        if let s4 = message["s4"] as? Int { details.append("S4=\(s4)°") }
        RockyLog.write(
            "control: board applied seq=\(sequence)\(elapsed) reason=\(trace?.reason ?? "untracked") "
                + (active ? "wheels=\(left)/\(right)RPM" : "wheels=stopped")
                + (details.isEmpty ? "" : " " + details.joined(separator: " "))
        )
    }

    private func handleServoAcknowledgement(_ message: [String: Any]) {
        let port = message["port"] as? String ?? "?"
        let angle = message["angle"] as? Int ?? -1
        let id = message["id"] as? String ?? ""
        let target = servoSentTargets.removeValue(forKey: id)
        let angleDescription = target.map { "\($0.angle)°" } ?? "\(angle)°"
        let sentAt = servoSentAt.removeValue(forKey: id)
        let elapsed = sentAt.map {
            " in \(Int(Date().timeIntervalSince($0) * 1_000))ms"
        } ?? ""
        if latestServoID[port] == id {
            latestServoID.removeValue(forKey: port)
            servoAckTimeoutTasks.removeValue(forKey: port)?.cancel()
        }
        if message["ok"] as? Bool == false {
            let error = message["error"] as? String ?? "unknown board error"
            RockyLog.write("servo: \(port) \(angleDescription) failed\(elapsed): \(error)")
            return
        }
        let superseded = sentAt.map { $0 < (servoLastAcceptedSentAt[port] ?? .distantPast) } ?? true
        let moving = message["moving"] as? Bool == true
        if !superseded, let sentAt {
            servoLastAcceptedSentAt[port] = sentAt
            if servoAngles[port] != nil { servoAngles[port] = angle }
            if moving {
                servoPhysicalTargets[port] = (angle, sentAt)
            } else {
                servoPhysicalTargets.removeValue(forKey: port)
            }
        }
        RockyLog.write(
            "servo: board accepted \(port) \(angleDescription)\(elapsed)"
                + (moving ? " (slewing)" : " (at target)")
                + (superseded ? " (superseded ACK; state unchanged)" : "")
        )
    }

    private func handleManualDriveAcknowledgement(_ message: [String: Any]) {
        let id = message["id"] as? String ?? ""
        let elapsed = manualDriveSentAt.removeValue(forKey: id).map {
            " in \(Int(Date().timeIntervalSince($0) * 1_000))ms"
        } ?? ""
        if message["ok"] as? Bool == false {
            RockyLog.write(
                "manual drive: board failed\(elapsed): "
                    + (message["error"] as? String ?? "unknown board error")
            )
            return
        }
        let active = message["active"] as? Bool ?? false
        let left = message["left_rpm"] as? Int ?? 0
        let right = message["right_rpm"] as? Int ?? 0
        let blocked = message["blocked"] as? Bool == true
        let obstacle = (message["obstacle_cm"] as? NSNumber)?.doubleValue
        let now = Date()
        if blocked {
            RockyLog.write(
                "manual drive: forward command blocked by obstacle"
                    + (obstacle.map { " at \(Int($0))cm" } ?? "") + elapsed
            )
            lastManualDriveLogAt = now
        } else if !active || now.timeIntervalSince(lastManualDriveLogAt) >= 1 {
            let handoff = message["handoff_ms"] as? Int
            RockyLog.write(
                active
                    ? "manual drive: board accepted left=\(left) right=\(right) RPM\(elapsed)"
                    : "manual drive: stopped; autonomy resumes in \(handoff ?? 0)ms\(elapsed)"
            )
            lastManualDriveLogAt = now
        }
    }

    /// Immediate, unlike everything else here: a person saying "stop" means now.
    func stopMoving() {
        send(["type": "stop"])
        RockyLog.write("behavior: asked the robot to stop")
    }

    func setMood(_ mood: String, id: String) {
        requestedMood = mood
        send(["type": "mood", "mood": mood, "id": id])
        RockyLog.write("behavior: asked for mood \(mood)")
    }

    /// The board deliberately boots in the hard `still` interlock. Voice lifecycle, not the
    /// language model, owns crossing that boundary: otherwise one missed tool call leaves every
    /// later gesture accepted and immediately cancelled by the board.
    static func wakeMoodIfNeeded(
        connected: Bool, currentMood: String, requestedMood: String? = nil
    ) -> String? {
        connected && (requestedMood ?? currentMood) == "still" ? "exploring" : nil
    }

    static func pauseMoodIfConnected(_ connected: Bool) -> String? {
        connected ? "still" : nil
    }

    @discardableResult
    func wakeFromStill(id: String) -> Bool {
        guard let wakeMood = Self.wakeMoodIfNeeded(
            connected: connected, currentMood: mood, requestedMood: requestedMood
        ) else {
            return false
        }
        setMood(wakeMood, id: id)
        RockyLog.write("behavior: voice lifecycle woke the robot from still")
        return true
    }

    @discardableResult
    func stillForVoicePause(id: String) -> Bool {
        guard let pauseMood = Self.pauseMoodIfConnected(connected) else { return false }
        setMood(pauseMood, id: id)
        RockyLog.write("behavior: voice pause put the robot in still")
        return true
    }

    /// `id` is Rocky's own action id, echoed back by the board in its ack -- which is what makes
    /// a gesture's fate correlatable rather than inferred from timing. The board now lets a chosen
    /// gesture preempt autonomous motion immediately, but the ack still means "heard", not
    /// "wheels moved"; the correlated transition is the physical-start evidence.
    func requestGesture(_ gesture: String, times: Int = 1, id: String) {
        let repeats = max(1, min(10, times))
        send(["type": "gesture", "gesture": gesture, "times": repeats, "id": id])
        RockyLog.write("behavior: gesture \(gesture)\(repeats > 1 ? " x\(repeats)" : "") (\(id))")
    }

    /// One correlated sequence begins its first beat immediately, then preserves later beats
    /// without each one becoming a separate model response or overwriting the one before it.
    func requestRoutine(_ moves: [String], id: String) {
        let bounded = Array(moves.prefix(8))
        guard bounded.count >= 2 else { return }
        send(["type": "routine", "moves": bounded, "id": id])
        RockyLog.write("behavior: routine \(bounded.joined(separator: "+")) (\(id))")
    }

    /// A temporary expressive colour overlays automatic body-state lighting, then the board
    /// restores whichever state colour is current when the expression expires.
    func setLight(_ color: String, durationMs: Int, id: String) {
        let bounded = max(200, min(10_000, durationMs))
        send(["type": "light", "color": color, "duration_ms": bounded, "id": id])
        RockyLog.write("behavior: light \(color) for \(bounded)ms (\(id))")
    }

    func restoreAutomaticLight(id: String) {
        send(["type": "light", "color": "auto", "duration_ms": 0, "id": id])
        RockyLog.write("behavior: light returned to automatic (\(id))")
    }

    /// Coalesces 60fps touch input before publishing one complete newest-state UDP frame.
    func setServo(port: String, angle: Int, immediately: Bool = false) {
        let port = port.uppercased()
        guard port == "S3" || port == "S4" else {
            RockyLog.write("servo: rejected unsupported port \(port)")
            return
        }
        let bounded = max(0, min(180, angle))
        let target = ServoTarget(angle: bounded)
        guard connected else {
            RockyLog.write(
                "servo: ignored \(port) \(bounded)° while robot disconnected"
            )
            return
        }
        pendingServoTargets[port] = target

        if immediately {
            servoSendTasks.removeValue(forKey: port)?.cancel()
            flushServo(port)
            return
        }
        guard servoSendTasks[port] == nil else { return }
        servoSendTasks[port] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.flushServo(port)
        }
    }

    private func flushServo(_ port: String) {
        servoSendTasks.removeValue(forKey: port)
        guard let target = pendingServoTargets.removeValue(forKey: port) else { return }
        controlServoTargets[port] = target.angle
        sendControlState(report: true, reason: "\(port)=\(target.angle)°")
    }

    /// Quiet UDP heartbeats renew the board watchdog without adding work to the ordered TCP
    /// stream. Touch transitions request a correlated applied-state report over TCP.
    func setManualDrive(
        throttle: Double, steering: Double, active: Bool, correlated: Bool = true
    ) {
        let boundedThrottle = max(-1, min(1, throttle))
        let boundedSteering = max(-1, min(1, steering))
        guard connected else {
            if active { RockyLog.write("manual drive: ignored while robot disconnected") }
            return
        }
        controlThrottle = boundedThrottle
        controlSteering = boundedSteering
        controlDriveActive = active
        if active { controlStopRepeatTask?.cancel() }
        sendControlState(
            report: correlated,
            reason: active ? "drive engaged" : "drive released"
        )
        if active, Date().timeIntervalSince(lastManualDriveLogAt) >= 1 {
            RockyLog.write(
                "manual drive: sent throttle=\(Int(boundedThrottle * 100))% "
                    + "steering=\(Int(boundedSteering * 100))%"
                    + (correlated ? " (reported state)" : " (heartbeat)")
            )
            lastManualDriveLogAt = Date()
        } else if !active {
            RockyLog.write("manual drive: released; repeating newest-state stop")
            scheduleRepeatedStopFrames()
        }
    }

    private func sendControlState(report: Bool, reason: String) {
        guard connected, let controlConnection else { return }
        controlSequence += 1
        let sequence = controlSequence
        var payload: [String: Any] = [
            "type": "control", "epoch": controlEpoch, "seq": sequence,
            "active": controlDriveActive, "throttle": controlThrottle,
            "steering": controlSteering,
        ]
        if let angle = controlServoTargets["S3"] { payload["s3"] = angle }
        if let angle = controlServoTargets["S4"] { payload["s4"] = angle }
        if report {
            payload["report"] = true
            controlSentAt[sequence] = (Date(), reason)
            if controlSentAt.count > 40 {
                let newest = controlSentAt.sorted { $0.key > $1.key }.prefix(24)
                controlSentAt = Dictionary(
                    uniqueKeysWithValues: newest.map { ($0.key, $0.value) }
                )
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        controlConnection.send(content: data, completion: .idempotent)
        if report {
            RockyLog.write("control: sent seq=\(sequence) reason=\(reason)")
        }
    }

    private func scheduleRepeatedStopFrames() {
        controlStopRepeatTask?.cancel()
        controlStopRepeatTask = Task { @MainActor [weak self] in
            for _ in 0..<2 {
                do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
                guard let self, !self.controlDriveActive else { return }
                self.sendControlState(report: false, reason: "repeated stop")
            }
        }
    }

    /// Called before iOS suspends the app. It is intentionally independent of SwiftUI view
    /// disappearance, which is not guaranteed for an app switch.
    func releaseManualDriveForBackground() {
        guard connected else { return }
        setManualDrive(throttle: 0, steering: 0, active: false)
        RockyLog.write("manual drive: app left foreground; controls released")
    }

    /// Recent history, newest first, as the model should read it: what happened and how long ago.
    func recentHistory(limit: Int = 8) -> [[String: Any]] {
        events.suffix(limit).reversed().map { event in
            var entry: [String: Any] = ["what": event.mode, "secondsAgo": event.secondsAgo.rounded()]
            if !event.detail.isEmpty { entry["detail"] = event.detail }
            return entry
        }
    }
}
