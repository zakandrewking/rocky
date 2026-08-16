import Foundation

/// What became of an action, or of the link carrying it. The only thing this layer says about the
/// world -- everything semantic (what "blocked" means, whether it is worth mentioning) happens in
/// MotionWorldSource, on the far side of this boundary.
enum ActionReport: Sendable {
    case started(actionId: String)
    case succeeded(actionId: String)
    case blocked(actionId: String, reason: String)
    case failed(actionId: String, reason: String)
    /// The deadline passed with no outcome. Deliberately not `failed`: nobody said it failed.
    case lost(actionId: String, reason: String)
    case distance(cm: Double)
    /// Traffic arrived, which on this hardware is the only real proof the board is running.
    case alive
    case gone(String)
}

/// Runs Rocky's movement instructions against the motion agent, and reports what became of them.
///
/// The important property is that **movement never blocks the caller**. `drive` and `turn` return
/// as soon as the command is on the wire; whether it started, finished, was refused or was never
/// heard of again arrives afterwards, through `onReport`, and lands in the world model.
///
/// It used to be the other way round -- the tool-call handler awaited physical completion, which
/// meant Rocky went silent for the length of every movement and, worse, that a drive lasting
/// longer than a flat three-second timeout was reported to her as a failure while the robot was
/// still happily driving. Both of those were the same mistake: treating a physical act as a
/// function call.
///
/// It no longer remembers anything either. WorldStore is the single authoritative memory now, so
/// having a second, quietly-diverging copy of "what the robot just did" living here would be one
/// answer too many to the same question.
actor RobotController {
    private let robot: Robot
    let host: String

    private var connected = false
    /// Wire command id → the action id Rocky knows it by. The board speaks in its own sequence
    /// numbers; nothing above this layer should ever have to.
    private var actionForCommand: [String: String] = [:]
    private var report: (@Sendable (ActionReport) -> Void)?

    init(host: String, port: UInt16 = 8765) {
        self.host = host
        self.robot = Robot(host: host, port: port)
    }

    func observe(_ report: @escaping @Sendable (ActionReport) -> Void) {
        self.report = report
    }

    func connect() async throws {
        await robot.observe(
            started: { [weak self] commandId in
                Task { await self?.noteStarted(commandId) }
            },
            traffic: { [weak self] in
                Task { await self?.emit(.alive) }
            },
            disconnected: { [weak self] error in
                Task { await self?.noteDisconnected(error) }
            }
        )
        try await robot.connect()
        connected = true
    }

    func disconnect() async {
        await robot.disconnect()
        connected = false
    }

    var isConnected: Bool { connected }

    // MARK: - Movement (fire and report)

    func drive(actionId: String, distanceCm: Double, speed: Double) async {
        let estimate = RobotLimits.estimatedDriveSeconds(distanceCm: distanceCm, speed: speed)
        await run(actionId: actionId, estimate: estimate) { commandId, deadline in
            try await self.robot.drive(
                id: commandId, distanceCm: distanceCm, speed: speed, timeout: deadline
            )
        }
    }

    func turn(actionId: String, degrees: Double, speed: Double) async {
        let estimate = RobotLimits.estimatedTurnSeconds(degrees: degrees, speed: speed)
        await run(actionId: actionId, estimate: estimate) { commandId, deadline in
            try await self.robot.turn(id: commandId, degrees: degrees, speed: speed, timeout: deadline)
        }
    }

    /// Stop is the one movement worth awaiting: it is short, it is the safety path, and the
    /// difference between "asked to stop" and "stopped" is one a person can hear.
    func stop(actionId: String) async {
        do {
            _ = try await robot.stop()
            emit(.succeeded(actionId: actionId))
        } catch {
            emit(Self.outcome(for: actionId, error: error))
        }
    }

    /// Sends, returns, and reports the outcome whenever it turns up.
    private func run(
        actionId: String,
        estimate: TimeInterval,
        _ body: @escaping @Sendable (String, TimeInterval) async throws -> TelemetryMessage
    ) async {
        let commandId = await robot.nextCommandId()
        actionForCommand[commandId] = actionId
        let deadline = RobotLimits.completionDeadline(estimate: estimate)
        Task { [weak self] in
            do {
                _ = try await body(commandId, deadline)
                await self?.finish(commandId, with: .succeeded(actionId: actionId))
            } catch {
                await self?.finish(commandId, with: Self.outcome(for: actionId, error: error))
            }
        }
    }

    private func finish(_ commandId: String, with report: ActionReport) {
        actionForCommand.removeValue(forKey: commandId)
        emit(report)
    }

    private func noteStarted(_ commandId: String) {
        guard let actionId = actionForCommand[commandId] else { return }
        emit(.started(actionId: actionId))
    }

    private func noteDisconnected(_ error: Error?) {
        connected = false
        actionForCommand.removeAll()
        emit(.gone(error.map { $0.localizedDescription } ?? "the connection to my body dropped"))
    }

    /// Turns a transport error into the honest report. The distinction that matters here is
    /// `blocked` and `lost` versus `failed`: something got in the way, versus we never found out,
    /// versus the body actually said no. Those are three different sentences.
    private static func outcome(for actionId: String, error: Error) -> ActionReport {
        switch error {
        case RobotError.commandFailed(let message) where message.contains("obstacle"):
            return .blocked(actionId: actionId, reason: "something was in the way")
        case RobotError.commandFailed(let message) where message.contains("busy"):
            return .failed(actionId: actionId, reason: "my body was already doing something")
        case RobotError.commandFailed(let message):
            return .failed(actionId: actionId, reason: message)
        case RobotError.timedOut:
            return .lost(actionId: actionId, reason: "I never felt it finish")
        case RobotError.disconnected:
            return .lost(actionId: actionId, reason: "I lost track of my body")
        default:
            return .failed(actionId: actionId, reason: error.localizedDescription)
        }
    }

    private func emit(_ report: ActionReport) {
        self.report?(report)
    }

    // MARK: - Queries and instant effects
    //
    // These stay awaited. A distance reading is a question whose answer is the whole point, and
    // a face or a light changes the instant the board reads the line -- there is no "in progress"
    // for either, so there is nothing for the action lifecycle to describe.

    func readDistanceCm() async throws -> Double {
        let cm = try await robot.readDistance()
        emit(.distance(cm: cm))
        return cm
    }

    func setFace(_ face: FaceState) async throws {
        try await robot.setFace(face)
    }

    func setLights(red: Int, green: Int, blue: Int) async throws {
        try await robot.setLights(r: red, g: green, b: blue)
    }
}
