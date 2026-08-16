import Foundation

/// Swift port of apps/robot/src/protocol.ts. Same wire format, same bounds -- this and the
/// TypeScript version are two implementations of one spec, not two designs; keep them in sync.
/// Newline-delimited JSON over a plain TCP socket, matching apps/robot/device/rocky_agent.py.

enum RobotLimits {
    static let speedMin = 0.0
    static let speedMax = 100.0
    static let defaultSpeed = 50.0
    static let driveDistanceMaxCm = 300.0
    static let turnDegreesMax = 360.0

    // The board's own working figures (rocky_agent.py's CM_PER_SECOND_AT_MAX_RPM and
    // DEGREES_PER_SECOND_AT_MAX_RPM). Still uncalibrated on real hardware -- STEPS.md step 9 is
    // open -- so treat these as "roughly how long this ought to take", which is all they are used
    // for: sizing the completion deadline, and deciding when an action with no outcome should be
    // called lost rather than waited on forever.
    static let centimetresPerSecondAtFullSpeed = 30.0
    static let degreesPerSecondAtFullSpeed = 90.0

    static func estimatedDriveSeconds(distanceCm: Double, speed: Double) -> TimeInterval {
        let rate = max(centimetresPerSecondAtFullSpeed * (speed / 100), 1)
        return abs(distanceCm) / rate
    }

    static func estimatedTurnSeconds(degrees: Double, speed: Double) -> TimeInterval {
        let rate = max(degreesPerSecondAtFullSpeed * (speed / 100), 1)
        return abs(degrees) / rate
    }

    /// How long to wait for a movement to report back before deciding the outcome will never
    /// arrive. Generous on purpose, and generous in one place only, so the transport's timeout and
    /// the world model's "is this overdue" question can never disagree -- the earlier version of
    /// this had a flat 3s in the transport and nothing at all in the model, which is how a healthy
    /// six-second drive got reported as a failure.
    static func completionDeadline(estimate: TimeInterval) -> TimeInterval {
        estimate * 2 + 2
    }
}

enum FaceState: String, Codable, Sendable {
    case idle, listening, thinking, speaking, happy, error
}

enum CommandMessage: Sendable {
    case drive(id: String, distanceCm: Double, speed: Double)
    case turn(id: String, degrees: Double, speed: Double)
    case stop(id: String)
    case setFace(id: String, face: FaceState)
    case setLights(id: String, r: Int, g: Int, b: Int)
    case readDistance(id: String)
    case readLineSensors(id: String)
    case heartbeat(id: String)

    var id: String {
        switch self {
        case .drive(let id, _, _), .turn(let id, _, _), .stop(let id), .setFace(let id, _),
            .setLights(let id, _, _, _), .readDistance(let id), .readLineSensors(let id),
            .heartbeat(let id):
            return id
        }
    }

    /// Matches the JSON "type" field -- used in error/timeout messages, not sent over the wire
    /// directly (encode(to:) below writes "type" itself).
    var type: String {
        switch self {
        case .drive: return "drive"
        case .turn: return "turn"
        case .stop: return "stop"
        case .setFace: return "setFace"
        case .setLights: return "setLights"
        case .readDistance: return "readDistance"
        case .readLineSensors: return "readLineSensors"
        case .heartbeat: return "heartbeat"
        }
    }
}

extension CommandMessage: Encodable {
    private enum CodingKeys: String, CodingKey {
        case id, type, distanceCm, speed, degrees, face, r, g, b
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        switch self {
        case .drive(_, let distanceCm, let speed):
            try container.encode(distanceCm, forKey: .distanceCm)
            try container.encode(speed, forKey: .speed)
        case .turn(_, let degrees, let speed):
            try container.encode(degrees, forKey: .degrees)
            try container.encode(speed, forKey: .speed)
        case .setFace(_, let face):
            try container.encode(face, forKey: .face)
        case .setLights(_, let r, let g, let b):
            try container.encode(r, forKey: .r)
            try container.encode(g, forKey: .g)
            try container.encode(b, forKey: .b)
        case .stop, .readDistance, .readLineSensors, .heartbeat:
            break
        }
    }
}

enum TelemetryMessage: Sendable {
    case ack(id: String)
    /// A drive or turn has physically begun. `ack` only ever arrives on *completion*, so without
    /// this a client spends the whole of a multi-second movement with nothing to go on but its own
    /// assumption -- see apps/ios/docs/embodiment.md on why an assumed action and a confirmed one
    /// have to be tellable apart.
    case started(id: String)
    /// A reply to `heartbeat`, proving the board's interpreter is actually running its loop. An
    /// open socket does not prove that on this hardware (see protocol.ts).
    case pong(id: String)
    case error(id: String, message: String)
    case distance(id: String, cm: Double)
    case lineSensors(id: String, values: [Double])
    case status(battery: Double, connected: Bool)

    /// nil for `status`, which is an unprompted beacon with no request to correlate against.
    var id: String? {
        switch self {
        case .ack(let id), .started(let id), .pong(let id), .error(let id, _), .distance(let id, _),
            .lineSensors(let id, _):
            return id
        case .status:
            return nil
        }
    }
}

extension TelemetryMessage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, id, message, cm, values, battery, connected
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "ack":
            self = .ack(id: try container.decode(String.self, forKey: .id))
        case "started":
            self = .started(id: try container.decode(String.self, forKey: .id))
        case "pong":
            self = .pong(id: try container.decode(String.self, forKey: .id))
        case "error":
            self = .error(
                id: try container.decode(String.self, forKey: .id),
                message: try container.decode(String.self, forKey: .message)
            )
        case "distance":
            self = .distance(
                id: try container.decode(String.self, forKey: .id),
                cm: try container.decode(Double.self, forKey: .cm)
            )
        case "lineSensors":
            self = .lineSensors(
                id: try container.decode(String.self, forKey: .id),
                values: try container.decode([Double].self, forKey: .values)
            )
        case "status":
            self = .status(
                battery: try container.decode(Double.self, forKey: .battery),
                connected: try container.decode(Bool.self, forKey: .connected)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "unknown telemetry type \(type)"
            )
        }
    }
}

/// Bounds every outgoing command to a safe range before it ever reaches the wire. Rocky never
/// gets direct low-level motor access: a voice command or a future LLM tool call can request a
/// distance or speed, but never one large enough to be unsafe indoors, and never a raw wheel
/// voltage. Mirrors protocol.ts's boundCommand exactly.
func boundCommand(_ command: CommandMessage) -> CommandMessage {
    func clamp(_ value: Double, _ minValue: Double, _ maxValue: Double) -> Double {
        min(maxValue, max(minValue, value))
    }
    switch command {
    case .drive(let id, let distanceCm, let speed):
        return .drive(
            id: id,
            distanceCm: clamp(distanceCm, -RobotLimits.driveDistanceMaxCm, RobotLimits.driveDistanceMaxCm),
            speed: clamp(speed, RobotLimits.speedMin, RobotLimits.speedMax)
        )
    case .turn(let id, let degrees, let speed):
        return .turn(
            id: id,
            degrees: clamp(degrees, -RobotLimits.turnDegreesMax, RobotLimits.turnDegreesMax),
            speed: clamp(speed, RobotLimits.speedMin, RobotLimits.speedMax)
        )
    case .setLights(let id, let r, let g, let b):
        return .setLights(
            id: id,
            r: Int(clamp(Double(r), 0, 255)),
            g: Int(clamp(Double(g), 0, 255)),
            b: Int(clamp(Double(b), 0, 255))
        )
    case .stop, .setFace, .readDistance, .readLineSensors, .heartbeat:
        return command
    }
}

enum RobotWireFormat {
    static func encode(_ command: CommandMessage) throws -> Data {
        var data = try JSONEncoder().encode(command)
        data.append(0x0A) // "\n"
        return data
    }

    static func decodeTelemetry(_ line: some DataProtocol) throws -> TelemetryMessage {
        try JSONDecoder().decode(TelemetryMessage.self, from: Data(line))
    }
}
