import Foundation

/// Thin actor wrapper around Robot, giving RealtimeVoiceSession's tool-call handler a general
/// passthrough instead of a fixed vocabulary -- the model picks its own distances/angles per
/// request, bounded the same way everything else is (protocol.ts's boundCommand equivalent,
/// enforced inside Robot itself, not here).
actor RobotController {
    private let robot: Robot

    init(host: String, port: UInt16 = 8765) {
        self.robot = Robot(host: host, port: port)
    }

    func connect() async throws {
        try await robot.connect()
    }

    func disconnect() async {
        await robot.disconnect()
    }

    @discardableResult
    func drive(distanceCm: Double, speed: Double) async throws -> TelemetryMessage {
        try await robot.drive(distanceCm: distanceCm, speed: speed)
    }

    @discardableResult
    func turn(degrees: Double, speed: Double) async throws -> TelemetryMessage {
        try await robot.turn(degrees: degrees, speed: speed)
    }

    func stop() async throws {
        try await robot.stop()
    }

    func readDistanceCm() async throws -> Double {
        try await robot.readDistance()
    }

    func setFace(_ face: FaceState) async throws {
        try await robot.setFace(face)
    }
}
