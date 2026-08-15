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

    /// Overrides the baked-in body context when no robot is connected. The baked persona (from
    /// services/device-api/src/session.ts) promises a wheeled body with working movement tools;
    /// with no robot on the network that would be a lie, so this replaces the claim rather than
    /// letting Rocky offer to drive somewhere she can't. Appended last, where it wins.
    private static let noBodyNote = """
        ROCKY'S BODY — NOT CONNECTED RIGHT NOW
        - This overrides anything above about your wheeled body. The robot body is not connected,
          so you cannot drive, turn, stop, or read distance at all right now, and you have no
          movement tools.
        - If someone asks you to move or look around, say plainly that your body is not connected
          right now. Do not pretend to move, and do not narrate movement you cannot do.
        - Everything else about you is unchanged: you can still talk with your friends.
        """

    /// The session config (persona, tools, voice, model) is not baked into Swift source -- it's
    /// dumped verbatim from services/device-api/src/session.ts at build time (see
    /// scripts/dump-session-config.mjs) into this bundled resource, so Rocky's persona keeps
    /// exactly one real definition in the repo.
    ///
    /// `hasRobot` is false when discovery found no robot: the movement tools are stripped and the
    /// body context corrected, so the app is still a full voice Rocky (what apps/desktop is) even
    /// with no robot in the room.
    static func mintEphemeralSecret(hasRobot: Bool, speaksWithHume: Bool = false) async throws -> String {
        guard let apiKey = Bundle.main.object(forInfoDictionaryKey: "RockyOpenAIKey") as? String,
            !apiKey.isEmpty
        else {
            throw RobotError.commandFailed(
                "no OpenAI API key baked into this build -- run apps/ios/scripts/generate.sh with OPENAI_API_KEY set in the repo root .env, then rebuild"
            )
        }
        guard let configURL = Bundle.main.url(forResource: "RealtimeSessionConfig", withExtension: "json"),
            let bakedBody = try? Data(contentsOf: configURL)
        else {
            throw RobotError.commandFailed("RealtimeSessionConfig.json missing from the app bundle -- run apps/ios/scripts/generate.sh, not xcodegen generate directly")
        }
        var body = hasRobot ? bakedBody : Self.withoutRobotBody(bakedBody)
        if speaksWithHume { body = Self.withTextOutput(body) }

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

    /// Strips the movement tools out of the baked config and corrects the body context. Edits the
    /// JSON rather than keeping a second hand-written copy of the persona in Swift, so
    /// session.ts stays the single source of truth for everything except this one override.
    /// Returns the input unchanged if the shape is not what we expect -- a config we can't parse
    /// is better sent as-is than dropped.
    static func withoutRobotBody(_ data: Data) -> Data {
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            var session = root["session"] as? [String: Any]
        else { return data }

        session["tools"] = []
        session["tool_choice"] = "none"
        if let instructions = session["instructions"] as? String {
            session["instructions"] = instructions + "\n\n" + noBodyNote
        }
        root["session"] = session
        return (try? JSONSerialization.data(withJSONObject: root)) ?? data
    }

    /// Switches the session to text-only output, for when Hume is speaking for Rocky: OpenAI then
    /// streams words instead of audio, and HumeSpeech turns them into her actual voice.
    ///
    /// Unlike apps/desktop, turn detection is deliberately left server-driven
    /// (`create_response` / `interrupt_response` stay true). Desktop turns both off and
    /// reimplements turn-taking and barge-in itself; matching that would mean owning a state
    /// machine whose failure modes are "never answers" and "talks over you", to buy control this
    /// app has no use for yet. Local playback still has to be stopped on barge-in, which
    /// RealtimeVoiceSession does off `input_audio_buffer.speech_started`.
    static func withTextOutput(_ data: Data) -> Data {
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            var session = root["session"] as? [String: Any]
        else { return data }

        session["output_modalities"] = ["text"]
        root["session"] = session
        return (try? JSONSerialization.data(withJSONObject: root)) ?? data
    }
}
