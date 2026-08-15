import Foundation
import Network

/// One thing the robot did, as history rather than status.
struct BehaviorEvent: Sendable, Equatable {
    let mode: String
    let detail: String
    let at: Date

    var secondsAgo: Double { Date().timeIntervalSince(at) }
}

/// Watches the robot's autonomous behaviour (apps/robot/device/rocky_behavior.py) and passes the
/// voice character's intentions back to it.
///
/// The two loops run on incompatible clocks, and that shapes this whole class. The motion loop
/// decides at ~20Hz and its reactions last 0.3-4 seconds; the voice character cannot produce a
/// spoken word in under about two seconds. So "what are you doing right now" is a stale question
/// by the time anyone answers it, and this deliberately keeps *history* instead: by the time
/// Rocky says "something loud scared me and I ran", the running is over, and that sentence is
/// still true. Ages travel with every event so he can say it in the right tense.
///
/// The same asymmetry runs the other way: what goes back is intentions, not commands. The board
/// decides when to honour them.
@MainActor
final class BehaviorMonitor: ObservableObject {
    /// How much history to keep. Long enough to describe "the last little while", short enough
    /// that nothing stale gets narrated as news.
    private static let historyWindow: TimeInterval = 90
    private static let maxEvents = 40

    @Published private(set) var host: String?
    @Published private(set) var connected = false
    /// Set when the board is running the *motion* agent instead, so the one sweep finds either
    /// kind of robot. Only one payload runs at a time, so these are alternatives, never both.
    @Published private(set) var motionHost: String?
    /// True once the sweep has finished, however it ended -- so nothing has to guess whether
    /// "no robot" means "none there" or "still looking".
    @Published private(set) var searchFinished = false
    @Published private(set) var mode = "unknown"
    @Published private(set) var mood = "normal"
    @Published private(set) var events: [BehaviorEvent] = []

    /// Fired for the reactions worth interrupting a conversation over -- being startled or
    /// bumped, not every routine drive.
    var onNotableEvent: ((BehaviorEvent) -> Void)?

    private let beaconPort: NWEndpoint.Port
    private let eventPort: NWEndpoint.Port
    private let motionPort: NWEndpoint.Port
    private var listener: NWListener?
    private var connection: NWConnection?
    private var scanTask: Task<Void, Never>?
    private var buffer = ""

    init(beaconPort: UInt16 = 41900, eventPort: UInt16 = 8768, motionPort: UInt16 = 8765) {
        self.beaconPort = NWEndpoint.Port(rawValue: beaconPort) ?? 41900
        self.eventPort = NWEndpoint.Port(rawValue: eventPort) ?? 8768
        self.motionPort = NWEndpoint.Port(rawValue: motionPort) ?? 8765
    }

    // MARK: - Finding the robot

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params, on: beaconPort) else { return }
        listener.newConnectionHandler = { [weak self] incoming in
            Task { @MainActor in self?.readBeacon(incoming) }
        }
        listener.start(queue: .main)
        self.listener = listener
        RockyLog.write("behavior: listening for the robot's beacon")

        // The beacon is only a fast path, and on this hardware it has never actually arrived --
        // every session's log shows the motion agent's beacon timing out and the robot being
        // found by sweeping instead. So the sweep is the real mechanism here, not the fallback.
        scanTask = Task { [weak self] in await self?.scanForRobot() }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        scanTask?.cancel()
        scanTask = nil
        connection?.cancel()
        connection = nil
        connected = false
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

    /// Sweeps this phone's own /24 once, looking for either kind of robot.
    ///
    /// One sweep, not two. Only one payload runs on the board at a time, so the motion agent and
    /// the behaviour loop are alternatives -- searching for them independently meant two /24
    /// sweeps per launch that contradicted each other in the log, one of them always reporting
    /// failure for a robot that was sitting right there working.
    private func scanForRobot() async {
        guard let prefix = NetworkUtilities.localSubnetPrefix() else {
            searchFinished = true
            return
        }
        RockyLog.write("robot: sweeping \(prefix)0/24 for a body (behaviour :\(eventPort.rawValue) or motion :\(motionPort.rawValue))")

        var candidates = Array(1...254)
        if let saved = UserDefaults.standard.string(forKey: "behaviorHost"),
            saved.hasPrefix(prefix), let last = Int(saved.split(separator: ".").last.map(String.init) ?? ""),
            let index = candidates.firstIndex(of: last) {
            candidates.remove(at: index)
            candidates.insert(last, at: 0)
        }

        let behaviourPort = eventPort
        let motion = motionPort
        for batchStart in stride(from: 0, to: candidates.count, by: 32) {
            if Task.isCancelled || connection != nil { return }
            let batch = candidates[batchStart..<min(batchStart + 32, candidates.count)]
            let hit = await withTaskGroup(of: (String, Bool)?.self) { group in
                for octet in batch {
                    let address = "\(prefix)\(octet)"
                    group.addTask {
                        if await Self.probe(host: address, port: behaviourPort) != nil { return (address, true) }
                        if await Self.probe(host: address, port: motion) != nil { return (address, false) }
                        return nil
                    }
                }
                var winner: (String, Bool)?
                for await result in group where result != nil {
                    if winner == nil { winner = result; group.cancelAll() }
                }
                return winner
            }
            if let (address, isBehaviour) = hit {
                UserDefaults.standard.set(address, forKey: "behaviorHost")
                host = address
                searchFinished = true
                if isBehaviour {
                    RockyLog.write("robot: found at \(address), running its own behaviour")
                    connect(to: address, port: Int(behaviourPort.rawValue))
                } else {
                    RockyLog.write("robot: found at \(address), running the motion agent")
                    motionHost = address
                }
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
                switch state {
                case .ready:
                    self?.connected = true
                    RockyLog.write("behavior: watching the robot at \(host):\(port)")
                    self?.receive()
                case .failed, .cancelled:
                    if self?.connected == true { RockyLog.write("robot: lost the behaviour connection") }
                    self?.connected = false
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
                    self.connected = false
                    self.connection?.cancel()
                    self.connection = nil
                    return
                }
                self.receive()
            }
        }
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
        case "snapshot":
            mode = message["mode"] as? String ?? mode
            mood = message["mood"] as? String ?? mood
        case "hello":
            mode = message["mode"] as? String ?? mode
            mood = message["mood"] as? String ?? mood
            RockyLog.write("behavior: robot says hello (mode \(mode), mood \(mood))")
        default:
            break
        }
    }

    private func append(_ event: BehaviorEvent) {
        events.append(event)
        events.removeAll { $0.secondsAgo > Self.historyWindow }
        if events.count > Self.maxEvents { events.removeFirst(events.count - Self.maxEvents) }
        RockyLog.write("behavior: \(event.mode)\(event.detail.isEmpty ? "" : " (\(event.detail))")")
        // Only reactions worth interrupting a conversation over. Narrating every routine drive
        // would make Rocky a sports commentator.
        if event.mode == "startled" || event.mode == "dizzy" {
            onNotableEvent?(event)
        }
    }

    // MARK: - What the character would like

    private func send(_ message: [String: Any]) {
        guard connected, let connection,
            let data = try? JSONSerialization.data(withJSONObject: message)
        else { return }
        connection.send(content: data + Data("\n".utf8), completion: .idempotent)
    }

    /// Immediate, unlike everything else here: a person saying "stop" means now.
    func stopMoving() {
        send(["type": "stop"])
        RockyLog.write("behavior: asked the robot to stop")
    }

    func setMood(_ mood: String) {
        send(["type": "mood", "mood": mood])
        RockyLog.write("behavior: asked for mood \(mood)")
    }

    func requestGesture(_ gesture: String) {
        send(["type": "gesture", "gesture": gesture])
        RockyLog.write("behavior: asked for gesture \(gesture)")
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
