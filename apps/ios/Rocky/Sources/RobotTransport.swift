import Foundation
import Network

/// TCP client to apps/robot/device/rocky_agent.py, over plain Network.framework -- no WebSocket,
/// matching protocol.ts's reasoning (a raw socket is the least capable thing that still works,
/// and stock CyberOS's WS support was never confirmed). Not an actor: NWConnection is already
/// callback/queue-based, and Robot.swift (an actor) is what serializes state on top of this.
/// `@unchecked Sendable` because Robot is its only owner and every mutation of `buffer`/
/// `connection` happens either on `queue` (NWConnection's callbacks) or serialized through
/// Robot's own actor isolation -- not because it's safe to share arbitrarily.
final class RobotTCPTransport: @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "family.rocky.robot-transport")
    private var connection: NWConnection?
    private var buffer = Data()

    /// Both called on an arbitrary background queue, never the main thread -- callers that touch
    /// UI state must hop to @MainActor themselves (Robot.swift does this for its own callers).
    var onMessage: (@Sendable (TelemetryMessage) -> Void)?
    var onDisconnect: (@Sendable (Error?) -> Void)?

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    func connect() async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw RobotError.invalidAddress("port \(port) is out of range")
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        self.connection = connection

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // NWConnection delivers every stateUpdateHandler call serially on `queue` (set via
            // connection.start(queue:) below), so this is never actually mutated concurrently --
            // the compiler just can't see across NWConnection's own threading contract.
            nonisolated(unsafe) var settled = false
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard !settled else { return }
                    settled = true
                    continuation.resume()
                case .failed(let error):
                    guard !settled else { return }
                    settled = true
                    continuation.resume(throwing: error)
                case .cancelled:
                    guard !settled else { return }
                    settled = true
                    continuation.resume(throwing: RobotError.disconnected)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
        receiveNext()
    }

    func send(_ command: CommandMessage) {
        guard let connection, let data = try? RobotWireFormat.encode(command) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func close() {
        connection?.cancel()
        connection = nil
    }

    private func receiveNext() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.handleIncoming(data)
            }
            if isComplete || error != nil {
                self.onDisconnect?(error)
                return
            }
            self.receiveNext()
        }
    }

    private func handleIncoming(_ data: Data) {
        buffer.append(data)
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newlineIndex]
            defer { buffer.removeSubrange(buffer.startIndex...newlineIndex) }
            guard !line.isEmpty, let message = try? RobotWireFormat.decodeTelemetry(line) else {
                continue
            }
            onMessage?(message)
        }
    }
}

enum RobotError: Error, LocalizedError, Sendable {
    case invalidAddress(String)
    case disconnected
    case timedOut(String)
    case commandFailed(String)
    case unexpectedReply(String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress(let reason): return "invalid robot address: \(reason)"
        case .disconnected: return "disconnected from the robot"
        case .timedOut(let what): return "\(what) timed out"
        case .commandFailed(let message): return message
        case .unexpectedReply(let reason): return "unexpected reply: \(reason)"
        }
    }
}
