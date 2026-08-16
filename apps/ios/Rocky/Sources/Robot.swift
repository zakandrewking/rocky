import Foundation

/// The only thing app code should touch -- never RobotTCPTransport or the protocol types
/// directly -- because every command here is bounded (boundCommand) before it reaches the wire.
/// An actor, not a class-plus-DispatchQueue: serializes pending-request/heartbeat state without
/// the manual-sync deadlock risk a shared GCD queue would carry once callbacks start calling
/// back into it. Mirrors apps/robot/src/robot.ts.
actor Robot {
    private let transport: RobotTCPTransport
    private let heartbeatInterval: TimeInterval
    private let commandTimeout: TimeInterval

    private var nextId = 0
    private var pending: [String: CheckedContinuation<TelemetryMessage, Error>] = [:]
    private var heartbeatTask: Task<Void, Never>?

    var onStatus: (@Sendable (_ battery: Double, _ connected: Bool) -> Void)?
    var onDisconnect: (@Sendable (Error?) -> Void)?
    /// A drive or turn physically began (the board's `started` reply). Carries the command id.
    /// This is what turns an assumed action into a confirmed one -- see
    /// apps/ios/docs/embodiment.md.
    var onStarted: (@Sendable (_ id: String) -> Void)?
    /// Anything at all arrived from the board, including heartbeat replies. Positive evidence
    /// that the interpreter is alive, which an open socket is not on this hardware.
    var onTraffic: (@Sendable () -> Void)?

    /// Actor-isolated properties can't be assigned from outside, so callers install their
    /// handlers through this rather than through `robot.onStarted = ...`.
    func observe(
        started: (@Sendable (_ id: String) -> Void)? = nil,
        traffic: (@Sendable () -> Void)? = nil,
        disconnected: (@Sendable (Error?) -> Void)? = nil
    ) {
        if let started { onStarted = started }
        if let traffic { onTraffic = traffic }
        if let disconnected { onDisconnect = disconnected }
    }

    init(
        host: String,
        port: UInt16 = 8765,
        heartbeatInterval: TimeInterval = 0.5,
        commandTimeout: TimeInterval = 3.0
    ) {
        self.transport = RobotTCPTransport(host: host, port: port)
        self.heartbeatInterval = heartbeatInterval
        self.commandTimeout = commandTimeout
    }

    func connect() async throws {
        transport.onMessage = { [weak self] message in
            Task { await self?.handleTelemetry(message) }
        }
        transport.onDisconnect = { [weak self] error in
            Task { await self?.handleDisconnect(error) }
        }
        try await transport.connect()
        startHeartbeat()
    }

    func disconnect() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        for continuation in pending.values {
            continuation.resume(throwing: RobotError.disconnected)
        }
        pending.removeAll()
        transport.close()
    }

    /// `id` and `timeout` are explicit because a drive is only acked when it *finishes*, so the
    /// caller -- which knows the requested distance and speed -- is the only thing that can say
    /// how long finishing ought to take. A fixed timeout here used to report a perfectly healthy
    /// six-second drive as a failure three seconds in.
    @discardableResult
    func drive(
        id: String,
        distanceCm: Double,
        speed: Double = RobotLimits.defaultSpeed,
        timeout: TimeInterval? = nil
    ) async throws -> TelemetryMessage {
        try await send(.drive(id: id, distanceCm: distanceCm, speed: speed), timeout: timeout)
    }

    @discardableResult
    func turn(
        id: String,
        degrees: Double,
        speed: Double = RobotLimits.defaultSpeed,
        timeout: TimeInterval? = nil
    ) async throws -> TelemetryMessage {
        try await send(.turn(id: id, degrees: degrees, speed: speed), timeout: timeout)
    }

    /// The next wire id, so a caller can correlate `started`/`ack` replies with its own action
    /// before the command has even been sent.
    func nextCommandId() -> String { allocateId() }

    @discardableResult
    func stop() async throws -> TelemetryMessage {
        try await send(.stop(id: allocateId()))
    }

    func setFace(_ face: FaceState) async throws {
        _ = try await send(.setFace(id: allocateId(), face: face))
    }

    func setLights(r: Int, g: Int, b: Int) async throws {
        _ = try await send(.setLights(id: allocateId(), r: r, g: g, b: b))
    }

    func readDistance() async throws -> Double {
        let reply = try await send(.readDistance(id: allocateId()))
        guard case .distance(_, let cm) = reply else {
            throw RobotError.unexpectedReply("expected a distance reply, got \(reply)")
        }
        return cm
    }

    // MARK: - Private

    private func allocateId() -> String {
        nextId += 1
        return String(nextId)
    }

    private func send(_ command: CommandMessage, timeout: TimeInterval? = nil) async throws -> TelemetryMessage {
        let bounded = boundCommand(command)
        let deadline = timeout ?? commandTimeout
        return try await withCheckedThrowingContinuation { continuation in
            pending[bounded.id] = continuation
            transport.send(bounded)
            let id = bounded.id
            let type = bounded.type
            Task {
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                await self.failIfStillPending(id, type: type)
            }
        }
    }

    private func failIfStillPending(_ id: String, type: String) {
        if let continuation = pending.removeValue(forKey: id) {
            continuation.resume(throwing: RobotError.timedOut("\"\(type)\" (\(id))"))
        }
    }

    private func handleTelemetry(_ message: TelemetryMessage) {
        onTraffic?()
        if case .status(let battery, let connected) = message {
            onStatus?(battery, connected)
            return
        }
        // Neither of these ends the command they refer to. `started` says the maneuver began and
        // the ack is still to come; `pong` refers to a heartbeat that has no continuation waiting
        // on it at all. Resuming on either would finish a drive the instant it began.
        if case .started(let id) = message {
            onStarted?(id)
            return
        }
        if case .pong = message { return }
        guard let id = message.id, let continuation = pending.removeValue(forKey: id) else { return }
        if case .error(_, let errorMessage) = message {
            continuation.resume(throwing: RobotError.commandFailed(errorMessage))
        } else {
            continuation.resume(returning: message)
        }
    }

    private func handleDisconnect(_ error: Error?) {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        for continuation in pending.values {
            continuation.resume(throwing: error ?? RobotError.disconnected)
        }
        pending.removeAll()
        onDisconnect?(error)
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            await self?.runHeartbeatLoop()
        }
    }

    private func runHeartbeatLoop() async {
        while !Task.isCancelled {
            transport.send(.heartbeat(id: allocateId()))
            try? await Task.sleep(nanoseconds: UInt64(heartbeatInterval * 1_000_000_000))
        }
    }
}
