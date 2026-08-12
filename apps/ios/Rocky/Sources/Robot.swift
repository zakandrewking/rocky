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

    @discardableResult
    func drive(distanceCm: Double, speed: Double = RobotLimits.defaultSpeed) async throws -> TelemetryMessage {
        try await send(.drive(id: allocateId(), distanceCm: distanceCm, speed: speed))
    }

    @discardableResult
    func turn(degrees: Double, speed: Double = RobotLimits.defaultSpeed) async throws -> TelemetryMessage {
        try await send(.turn(id: allocateId(), degrees: degrees, speed: speed))
    }

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

    private func send(_ command: CommandMessage) async throws -> TelemetryMessage {
        let bounded = boundCommand(command)
        return try await withCheckedThrowingContinuation { continuation in
            pending[bounded.id] = continuation
            transport.send(bounded)
            let id = bounded.id
            let type = bounded.type
            Task {
                try? await Task.sleep(nanoseconds: UInt64(commandTimeout * 1_000_000_000))
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
        if case .status(let battery, let connected) = message {
            onStatus?(battery, connected)
            return
        }
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
