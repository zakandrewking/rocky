import Foundation
import Network

/// Listens for rocky_agent.py's periodic UDP broadcast beacon (`_beacon_discovery`, port 41900)
/// so the robot's IP doesn't have to be typed in by hand. A plain broadcast rather than real
/// Bonjour/mDNS -- receiving raw Bonjour would need the special multicast entitlement Apple has
/// to grant, and rocky_agent.py would need a hand-rolled DNS-SD responder; a broadcast needs
/// neither. Best-effort: if this never finds anything (network blocks broadcast, or the robot
/// isn't running rocky_agent.py), manual entry in ContentView still works exactly as before.
@MainActor
final class RobotDiscovery: ObservableObject {
    @Published private(set) var discoveredHost: String?

    private var listener: NWListener?
    private let port: NWEndpoint.Port

    private struct Beacon: Decodable {
        let service: String
    }

    init(port: UInt16 = 41900) {
        self.port = NWEndpoint.Port(rawValue: port) ?? 41900
    }

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params, on: port) else { return }
        listener.newConnectionHandler = { [weak self] connection in
            // NWListener's handler is a plain nonisolated closure even though it runs on
            // `.main` at runtime -- Swift's isolation checker can't see that, so hop explicitly
            // before touching `self` (a @MainActor type).
            Task { @MainActor in
                self?.handle(connection)
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            guard case .ready = state else { return }
            connection.receiveMessage { data, _, _, _ in
                if let data {
                    Task { @MainActor in
                        self?.process(data, endpoint: connection.endpoint)
                    }
                }
                connection.cancel()
            }
        }
        connection.start(queue: .main)
    }

    private func process(_ data: Data, endpoint: NWEndpoint) {
        guard let beacon = try? JSONDecoder().decode(Beacon.self, from: data),
            beacon.service == "rocky-robot"
        else { return }
        guard case let .hostPort(host, _) = endpoint, case let .ipv4(address) = host else {
            return
        }
        discoveredHost = "\(address)"
    }
}
