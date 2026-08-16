import Foundation

/// The errors this app raises for itself: a bad address, something that never answered, something
/// that answered badly.
///
/// Was `RockyError`, and lived in RobotTransport.swift next to the TCP client for the commanded-
/// motion agent. That agent is deprecated (apps/robot/deprecated/motion_agent.py) and its client
/// is gone, but these cases were never really about the robot -- the CyberPi payload pusher, the
/// WebRTC client and the session minter all raise them too. Renamed rather than left as a misnomer
/// pointing at a type that no longer exists.
enum RockyError: Error, LocalizedError, Sendable {
    case invalidAddress(String)
    case disconnected
    case timedOut(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress(let reason): return "invalid address: \(reason)"
        case .disconnected: return "disconnected"
        case .timedOut(let what): return "\(what) timed out"
        case .commandFailed(let message): return message
        }
    }
}
