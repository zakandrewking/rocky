import Foundation

/// Finds services/device-api on the local network by scanning the phone's own /24 for something
/// that answers GET /v1/health with {"ok":true} on the given port -- no beacon here, unlike
/// RobotDiscovery: device-api runs on a laptop (real os.networkInterfaces(), no self-IP platform
/// restriction the way rocky_agent.py has), so it *could* broadcast one, but the active scan
/// already works and needs nothing new on the server side. Checking the actual health payload,
/// not just "is the TCP port open," avoids matching some other unrelated service on the same port.
@MainActor
final class DeviceAPIDiscovery: ObservableObject {
    @Published private(set) var discoveredHost: String?
    @Published private(set) var isScanning = false

    private let port: Int
    private var scanTask: Task<Void, Never>?

    private struct HealthResponse: Decodable {
        let ok: Bool
        let service: String?
    }

    init(port: Int = 8787) {
        self.port = port
    }

    func start() {
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            await self?.scanSubnet()
        }
    }

    func stop() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    private func scanSubnet() async {
        guard let prefix = NetworkUtilities.localSubnetPrefix() else { return }
        isScanning = true
        defer { isScanning = false }

        RockyLog.write("device-api discovery: scanning \(prefix)0/24 port \(port)")

        let batchSize = 32
        var candidates = Array(1...254)
        // Try the last known-good host first -- overwhelmingly the same laptop again.
        if let saved = UserDefaults.standard.string(forKey: "deviceAPIHost"),
            let savedIP = saved.split(separator: ":").first,
            saved.hasPrefix(prefix),
            let lastOctet = Int(savedIP.split(separator: ".").last.map(String.init) ?? ""),
            let index = candidates.firstIndex(of: lastOctet) {
            candidates.remove(at: index)
            candidates.insert(lastOctet, at: 0)
        }

        for batchStart in stride(from: 0, to: candidates.count, by: batchSize) {
            guard !Task.isCancelled, discoveredHost == nil else { return }
            let batch = candidates[batchStart..<min(batchStart + batchSize, candidates.count)]
            let hit = await probeBatch(hosts: batch.map { "\(prefix)\($0)" })
            if let hit {
                RockyLog.write("device-api discovery: found \(hit)")
                discoveredHost = hit
                return
            }
        }
        RockyLog.write("device-api discovery: scan finished, nothing found")
    }

    private func probeBatch(hosts: [String]) async -> String? {
        let port = self.port
        return await withTaskGroup(of: String?.self) { group in
            for host in hosts {
                group.addTask {
                    await Self.probeHealth(host: host, port: port)
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

    /// GET http://host:port/v1/health, 1s timeout. Returns "host:port" (matching the format the
    /// deviceAPIHost field already uses) only if the response genuinely looks like device-api.
    private static func probeHealth(host: String, port: Int) async -> String? {
        guard let url = URL(string: "http://\(host):\(port)/v1/health") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.0
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            let health = try? JSONDecoder().decode(HealthResponse.self, from: data), health.ok
        else { return nil }
        return "\(host):\(port)"
    }
}
