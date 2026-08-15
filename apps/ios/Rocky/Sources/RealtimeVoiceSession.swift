import Foundation

/// Owns one Realtime voice conversation: mints an ephemeral secret from services/device-api,
/// opens a direct WebRTC connection to OpenAI (RealtimeWebRTCClient), and dispatches tool calls
/// (drive_cm, rotate_degrees, stop_robot, read_distance, set_face -- defined server-side in
/// services/device-api/src/session.ts, kept in sync by name here) onto a connected
/// RobotController. Replaces the fixed five-word vocabulary (VoiceCommandRecognizer) entirely --
/// this is real conversation, not string matching.
@MainActor
final class RealtimeVoiceSession: ObservableObject {
    enum State: Equatable {
        case disconnected, connecting, connected, failed(String)
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var lastToolCall: String?

    private let client = RealtimeWebRTCClient()
    private var robot: RobotController?

    func connect(deviceAPIHost: String, deviceToken: String, robot: RobotController) async {
        guard state == .disconnected || isFailed else { return }
        self.robot = robot
        state = .connecting

        do {
            try AudioSessionManager.configureForVoice()
            let secret = try await DeviceAPIClient.mintEphemeralSecret(host: deviceAPIHost, deviceToken: deviceToken)
            RockyLog.write("realtime: minted ephemeral secret")

            client.onEvent = { [weak self] event in
                Task { @MainActor in
                    await self?.handle(event)
                }
            }
            client.onConnectionStateChange = { [weak self] connected in
                Task { @MainActor in
                    self?.handleConnectionChange(connected)
                }
            }

            try await client.connect(ephemeralSecret: secret)
            state = .connected
            RockyLog.write("realtime: connected")
        } catch {
            state = .failed(error.localizedDescription)
            RockyLog.write("realtime: connect failed: \(error.localizedDescription)")
        }
    }

    func disconnect() {
        client.close()
        state = .disconnected
        robot = nil
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func handleConnectionChange(_ connected: Bool) {
        guard !connected, state == .connected || state == .connecting else { return }
        state = .failed("voice connection lost")
        RockyLog.write("realtime: connection lost")
    }

    private func handle(_ event: RealtimeServerEvent) async {
        if event.type == "error" {
            RockyLog.write("realtime error: \(event.error?.message ?? "unknown")")
        }
        for call in event.toolCalls {
            guard let name = call.name, let callId = call.call_id else { continue }
            await performToolCall(name: name, argumentsJSON: call.arguments ?? "{}", callId: callId)
        }
    }

    private func performToolCall(name: String, argumentsJSON: String, callId: String) async {
        RockyLog.write("tool call: \(name) \(argumentsJSON)")
        lastToolCall = name
        let output: String
        do {
            output = try await execute(name: name, argumentsJSON: argumentsJSON)
        } catch {
            output = Self.encodeResult(["success": false, "error": error.localizedDescription])
        }
        client.send(FunctionCallOutputEvent(callId: callId, output: output))
        client.send(ResponseCreateEvent())
    }

    private func execute(name: String, argumentsJSON: String) async throws -> String {
        guard let robot else { throw RobotError.disconnected }
        let data = Data(argumentsJSON.utf8)

        switch name {
        case "drive_cm":
            let args = try JSONDecoder().decode(DriveArgs.self, from: data)
            try await robot.drive(distanceCm: args.distanceCm, speed: args.speed ?? RobotLimits.defaultSpeed)
            return Self.encodeResult(["success": true])

        case "rotate_degrees":
            let args = try JSONDecoder().decode(TurnArgs.self, from: data)
            try await robot.turn(degrees: args.degrees, speed: args.speed ?? RobotLimits.defaultSpeed)
            return Self.encodeResult(["success": true])

        case "stop_robot":
            try await robot.stop()
            return Self.encodeResult(["success": true])

        case "read_distance":
            let cm = try await robot.readDistanceCm()
            return Self.encodeResult(["success": true, "distanceCm": cm])

        case "set_face":
            let args = try JSONDecoder().decode(FaceArgs.self, from: data)
            guard let face = FaceState(rawValue: args.face) else {
                return Self.encodeResult(["success": false, "error": "unknown face \(args.face)"])
            }
            try await robot.setFace(face)
            return Self.encodeResult(["success": true])

        default:
            return Self.encodeResult(["success": false, "error": "unknown tool \(name)"])
        }
    }

    private struct DriveArgs: Decodable {
        let distanceCm: Double
        let speed: Double?
    }

    private struct TurnArgs: Decodable {
        let degrees: Double
        let speed: Double?
    }

    private struct FaceArgs: Decodable {
        let face: String
    }

    /// Encodes a small, flat JSON object for a function_call_output. Values are deliberately
    /// restricted to the handful of types tool results actually need -- this isn't a general
    /// JSON encoder, just enough to avoid hand-building JSON strings with string interpolation.
    private static func encodeResult(_ fields: [String: Any]) -> String {
        var parts: [String] = []
        for (key, value) in fields {
            let encodedValue: String
            switch value {
            case let bool as Bool:
                encodedValue = bool ? "true" : "false"
            case let number as Double:
                encodedValue = String(number)
            case let string as String:
                let escaped = string
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                encodedValue = "\"\(escaped)\""
            default:
                encodedValue = "null"
            }
            parts.append("\"\(key)\":\(encodedValue)")
        }
        return "{\(parts.joined(separator: ","))}"
    }
}
