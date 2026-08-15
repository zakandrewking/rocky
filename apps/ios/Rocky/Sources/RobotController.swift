import Foundation

/// What the robot is and has just done, as a snapshot the model can ask for.
///
/// Every field is something the phone already knows from having issued the commands itself --
/// nothing here needs the board to report anything new. That matters: the CyberPi's published API
/// documents no battery or IMU readout (apps/cyberpi/docs/cyberos-api-surface.md), so inventing
/// device-side state would mean guessing at firmware rather than reading it.
struct RobotState: Sendable {
    var connected: Bool
    var address: String
    var busy: Bool
    var face: FaceState?
    var lastAction: String?
    var lastActionResult: String?
    var secondsSinceLastAction: Double?
    var lastDistanceCm: Double?
    var secondsSinceDistanceReading: Double?
}

/// Thin actor wrapper around Robot, giving RealtimeVoiceSession's tool-call handler a general
/// passthrough instead of a fixed vocabulary -- the model picks its own distances/angles per
/// request, bounded the same way everything else is (protocol.ts's boundCommand equivalent,
/// enforced inside Robot itself, not here).
///
/// It also remembers what just happened. Without that the model is amnesiac between tool calls:
/// it drives, reads a distance, and by the next turn has no idea it moved or what it saw.
actor RobotController {
    private let robot: Robot
    private let host: String

    private var connected = false
    private var busy = false
    private var face: FaceState?
    private var lastAction: String?
    private var lastActionResult: String?
    private var lastActionAt: Date?
    private var lastDistanceCm: Double?
    private var lastDistanceAt: Date?

    init(host: String, port: UInt16 = 8765) {
        self.host = host
        self.robot = Robot(host: host, port: port)
    }

    func connect() async throws {
        try await robot.connect()
        connected = true
    }

    func disconnect() async {
        await robot.disconnect()
        connected = false
    }

    func state() -> RobotState {
        RobotState(
            connected: connected,
            address: host,
            busy: busy,
            face: face,
            lastAction: lastAction,
            lastActionResult: lastActionResult,
            secondsSinceLastAction: lastActionAt.map { Date().timeIntervalSince($0) },
            lastDistanceCm: lastDistanceCm,
            secondsSinceDistanceReading: lastDistanceAt.map { Date().timeIntervalSince($0) }
        )
    }

    /// Runs one robot action, recording what it was and how it went either way. A failure is part
    /// of the state the model should be able to see -- "I tried to drive and it failed" is more
    /// useful to it than silence.
    private func record<T>(_ action: String, _ body: () async throws -> T) async throws -> T {
        busy = true
        lastAction = action
        lastActionAt = Date()
        defer { busy = false }
        do {
            let result = try await body()
            lastActionResult = "ok"
            return result
        } catch {
            lastActionResult = "failed: \(error.localizedDescription)"
            throw error
        }
    }

    @discardableResult
    func drive(distanceCm: Double, speed: Double) async throws -> TelemetryMessage {
        try await record("drive \(Int(distanceCm))cm") { try await robot.drive(distanceCm: distanceCm, speed: speed) }
    }

    @discardableResult
    func turn(degrees: Double, speed: Double) async throws -> TelemetryMessage {
        try await record("turn \(Int(degrees))°") { try await robot.turn(degrees: degrees, speed: speed) }
    }

    func stop() async throws {
        try await record("stop") { try await robot.stop() }
    }

    func readDistanceCm() async throws -> Double {
        let cm = try await record("read distance") { try await robot.readDistance() }
        lastDistanceCm = cm
        lastDistanceAt = Date()
        return cm
    }

    func setFace(_ face: FaceState) async throws {
        try await record("set face \(face.rawValue)") { try await robot.setFace(face) }
        self.face = face
    }

    func setLights(red: Int, green: Int, blue: Int) async throws {
        try await record("set lights") { try await robot.setLights(r: red, g: green, b: blue) }
    }
}
