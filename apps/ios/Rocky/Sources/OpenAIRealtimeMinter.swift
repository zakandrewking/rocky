import Foundation

/// Mints an ephemeral Realtime client secret directly from OpenAI -- no laptop server in the
/// loop. Personal-device tradeoff, not the general-purpose answer: this needs the real,
/// unscoped OPENAI_API_KEY baked into the app (see project.yml's RockyOpenAIKey and
/// scripts/generate.sh), which only belongs on a phone whose loss you're willing to eat the
/// cost of -- see services/device-api/src/session.ts's header comment for why that service
/// exists at all for the case where that is not an acceptable risk (e.g. a robot a child could
/// carry out of the house).
enum OpenAIRealtimeMinter {
    private struct ClientSecretResponse: Decodable {
        let value: String
    }

    /// The session config (persona, tools, voice, model) is not baked into Swift source -- it's
    /// dumped verbatim from services/device-api/src/session.ts at build time (see
    /// scripts/dump-session-config.mjs) into this bundled resource, so Rocky's persona keeps
    /// exactly one real definition in the repo.
    static func mintEphemeralSecret() async throws -> String {
        guard let apiKey = Bundle.main.object(forInfoDictionaryKey: "RockyOpenAIKey") as? String,
            !apiKey.isEmpty
        else {
            throw RobotError.commandFailed(
                "no OpenAI API key baked into this build -- run apps/ios/scripts/generate.sh with OPENAI_API_KEY set in the repo root .env, then rebuild"
            )
        }
        guard let configURL = Bundle.main.url(forResource: "RealtimeSessionConfig", withExtension: "json"),
            let body = try? Data(contentsOf: configURL)
        else {
            throw RobotError.commandFailed("RealtimeSessionConfig.json missing from the app bundle -- run apps/ios/scripts/generate.sh, not xcodegen generate directly")
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/realtime/client_secrets")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("rocky-ios", forHTTPHeaderField: "OpenAI-Safety-Identifier")
        request.httpBody = body
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RobotError.commandFailed("no HTTP response from OpenAI")
        }
        guard (200...299).contains(http.statusCode) else {
            let responseBody = String(decoding: data, as: UTF8.self)
            throw RobotError.commandFailed("OpenAI session creation failed (\(http.statusCode)): \(responseBody.prefix(300))")
        }
        return try JSONDecoder().decode(ClientSecretResponse.self, from: data).value
    }
}
