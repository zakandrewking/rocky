import Foundation

/// Talks to services/device-api's POST /v1/device/session -- the one call this app makes to the
/// laptop. Everything else (voice audio, tool calls) goes straight from the phone to OpenAI over
/// WebRTC once this hands back an ephemeral secret; the real API key never leaves the laptop.
enum DeviceAPIClient {
    private struct SessionResponse: Decodable {
        let ok: Bool
        let session: Session

        struct Session: Decodable {
            let value: String
        }
    }

    /// `host` is "ip:port", e.g. "192.168.1.138:8787" -- the laptop running
    /// `pnpm device-api`, not the robot's own address.
    static func mintEphemeralSecret(host: String, deviceToken: String) async throws -> String {
        guard let url = URL(string: "http://\(host)/v1/device/session") else {
            throw RobotError.invalidAddress("bad device API host: \(host)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RobotError.commandFailed("no HTTP response from device API")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(decoding: data, as: UTF8.self)
            throw RobotError.commandFailed("device API session request failed (\(http.statusCode)): \(body.prefix(300))")
        }
        let decoded = try JSONDecoder().decode(SessionResponse.self, from: data)
        guard decoded.ok else {
            throw RobotError.commandFailed("device API refused to mint a session")
        }
        return decoded.session.value
    }
}
