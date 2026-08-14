import Foundation
import Network

/// Finds the robot on the local network, two layers deep:
///
/// 1. **Passive beacon** -- listens for rocky_agent.py's periodic UDP broadcast (`_beacon_discovery`,
///    port 41900) and reads the robot's address off the packet's *sender endpoint*, never its
///    payload: the board cannot know its own IP (settled by source research, see rocky_agent.py's
///    block comment above `_boot()`), but the IP layer stamps the true source address on every
///    packet regardless. A plain broadcast rather than Bonjour/mDNS -- receiving raw Bonjour would
///    need the special multicast entitlement Apple has to grant, and rocky_agent.py would need a
///    hand-rolled DNS-SD responder; a broadcast needs neither.
/// 2. **Active TCP scan fallback** -- if no beacon arrives within a few seconds (this firmware's
///    broadcast sends are unverified, and consumer routers sometimes refuse to relay wireless
///    broadcast between clients), scan the phone's own /24 for the motion port directly. This is
///    the guaranteed floor: it is exactly how the robot has been found from the laptop all along,
///    and it needs nothing from the robot beyond the TCP listener it must have anyway. A probe
///    that connects is cancelled immediately -- rocky_agent.py sees a clean EOF and drops back to
///    "waiting for client" with no error state.
///
/// Both layers feed the same `discoveredHost`; ContentView auto-connects off it either way.
/// Best-effort throughout: if neither finds anything, manual entry still works exactly as before.
@MainActor
final class RobotDiscovery: ObservableObject {
    @Published private(set) var discoveredHost: String?
    @Published private(set) var isScanning = false

    private var listener: NWListener?
    private let beaconPort: NWEndpoint.Port
    private let motionPort: NWEndpoint.Port
    private var scanTask: Task<Void, Never>?

    /// How long to give the passive beacon before starting the active scan.
    private let beaconGracePeriod: TimeInterval = 3

    private struct Beacon: Decodable {
        let service: String
    }

    init(beaconPort: UInt16 = 41900, motionPort: UInt16 = 8765) {
        self.beaconPort = NWEndpoint.Port(rawValue: beaconPort) ?? 41900
        self.motionPort = NWEndpoint.Port(rawValue: motionPort) ?? 8765
    }

    func start() {
        startBeaconListener()
        scheduleScanFallback()
    }

    func stop() {
        listener?.cancel()
        listener = nil
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    // MARK: - Layer 1: passive beacon

    private func startBeaconListener() {
        guard listener == nil else { return }
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params, on: beaconPort) else { return }
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
        found("\(address)")
    }

    // MARK: - Layer 2: active TCP scan

    private func scheduleScanFallback() {
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.beaconGracePeriod * 1_000_000_000))
            guard !Task.isCancelled, self.discoveredHost == nil else { return }
            await self.scanSubnet()
        }
    }

    private func scanSubnet() async {
        guard let prefix = Self.localSubnetPrefix() else { return }
        isScanning = true
        defer { isScanning = false }

        RockyLog.write("discovery: no beacon after \(Int(beaconGracePeriod))s, scanning \(prefix)0/24")

        // Batches keep the socket burst reasonable; per-probe timeout keeps a batch of silent
        // hosts from stalling the sweep. First hit wins and cancels the rest.
        let batchSize = 32
        var candidates = Array(1...254)
        // Try the last known-good address first -- overwhelmingly the robot again on a home
        // network with stable DHCP leases.
        if let saved = UserDefaults.standard.string(forKey: "robotHost"),
            saved.hasPrefix(prefix), let lastOctet = Int(saved.split(separator: ".").last.map(String.init) ?? ""),
            let index = candidates.firstIndex(of: lastOctet) {
            candidates.remove(at: index)
            candidates.insert(lastOctet, at: 0)
        }

        for batchStart in stride(from: 0, to: candidates.count, by: batchSize) {
            guard !Task.isCancelled, discoveredHost == nil else { return }
            let batch = candidates[batchStart..<min(batchStart + batchSize, candidates.count)]
            let hit = await probeBatch(hosts: batch.map { "\(prefix)\($0)" })
            if let hit {
                RockyLog.write("discovery: scan found \(hit)")
                found(hit)
                return
            }
        }
        RockyLog.write("discovery: scan finished, nothing found")
    }

    private func probeBatch(hosts: [String]) async -> String? {
        let port = motionPort  // hoisted so the task group closures don't need to capture `self`
        return await withTaskGroup(of: String?.self) { group in
            for host in hosts {
                group.addTask {
                    await Self.probe(host: host, port: port)
                }
            }
            var winner: String?
            for await result in group {
                if let result, winner == nil {
                    winner = result
                    group.cancelAll()
                }
            }
            return winner
        }
    }

    /// One TCP connect attempt: .ready means something is listening -> that's our robot candidate.
    /// Cancelling immediately after gives rocky_agent.py a clean EOF, not an error state.
    private static func probe(host: String, port: NWEndpoint.Port) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            // Serial-by-construction on the .main queue (same reasoning as RobotTCPTransport's
            // connect timeout): every path through here runs on the queue passed to start().
            nonisolated(unsafe) var settled = false

            // A plain closure, not DispatchWorkItem (not Sendable, can't be captured into the
            // @Sendable stateUpdateHandler below). No explicit cancel needed either: `settled`
            // already makes both this and stateUpdateHandler's branches a no-op once the other
            // one has already resolved the continuation.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard !settled else { return }
                settled = true
                connection.cancel()
                continuation.resume(returning: nil)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard !settled else { return }
                    settled = true
                    connection.cancel()
                    continuation.resume(returning: host)
                case .failed, .cancelled:
                    guard !settled else { return }
                    settled = true
                    continuation.resume(returning: nil)
                default:
                    break
                }
            }
            connection.start(queue: .main)
        }
    }

    private func found(_ host: String) {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        discoveredHost = host
    }

    // MARK: - Own-address lookup

    /// The phone's IPv4 on Wi-Fi (en0), as "a.b.c." -- the /24 to sweep. getifaddrs is plain
    /// POSIX, no entitlement needed. nil on cellular-only or no Wi-Fi, which just means no scan.
    private static func localSubnetPrefix() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let sa = current.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                String(cString: current.pointee.ifa_name) == "en0"
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let ip = String(cString: host)
            let octets = ip.split(separator: ".")
            guard octets.count == 4 else { continue }
            return "\(octets[0]).\(octets[1]).\(octets[2])."
        }
        return nil
    }
}
