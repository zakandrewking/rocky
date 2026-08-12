import Foundation

/// Maps a fixed voice-command vocabulary onto bounded Robot calls. Kept separate from
/// VoiceCommandRecognizer (which only knows about speech) and Robot (which only knows the wire
/// protocol) so a later swap to full Realtime tool-calling only has to replace this file.
actor RobotController {
    private let robot: Robot

    /// One command word = one short, deliberately small move -- this is a "nudge robot, watch
    /// what happens" milestone, not autonomous navigation. Phase 4 (LLM tool calls) picks its own
    /// distances per-request instead of these fixed nudges.
    private static let driveDistanceCm = 30.0
    private static let turnDegrees = 30.0
    private static let speed = 40.0

    init(host: String, port: UInt16 = 8765) {
        self.robot = Robot(host: host, port: port)
    }

    func connect() async throws {
        try await robot.connect()
    }

    func disconnect() async {
        await robot.disconnect()
    }

    func perform(_ command: RobotVoiceCommand) async throws {
        switch command {
        case .forward:
            try await robot.drive(distanceCm: Self.driveDistanceCm, speed: Self.speed)
        case .backward:
            try await robot.drive(distanceCm: -Self.driveDistanceCm, speed: Self.speed)
        case .left:
            try await robot.turn(degrees: -Self.turnDegrees, speed: Self.speed)
        case .right:
            try await robot.turn(degrees: Self.turnDegrees, speed: Self.speed)
        case .stop:
            try await robot.stop()
        }
    }
}
