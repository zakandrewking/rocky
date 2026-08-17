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
        - This overrides anything above about embodied sensations and movement. You cannot feel or
          move your body while this connection is absent.
        - If movement becomes relevant, say once and naturally that you cannot feel your body right
          now. Do not pretend or narrate imaginary movement, then return to your friend and topic.
        - Your identity, agency, relationships, and conversation are unchanged.
        """

    /// The session config (persona, tools, voice, model) is not baked into Swift source -- it's
    /// dumped verbatim from services/device-api/src/session.ts at build time (see
    /// scripts/dump-session-config.mjs) into this bundled resource, so Rocky's persona keeps
    /// exactly one real definition in the repo.
    ///
    /// `hasRobot` is false when discovery found no robot: the movement tools are stripped and the
    /// body context corrected, so the app is still a full voice Rocky (what apps/desktop is) even
    /// with no robot in the room.
    /// Whether the baked session asks the model for words rather than speech -- which is exactly
    /// the characters whose voice comes from Hume. The config decides this, not the app: the
    /// character owns its voice (services/device-api/src/characters), so reading it back here is
    /// what keeps a character swap from needing an app change.
    static var characterSpeaksThroughHume: Bool {
        guard let url = Bundle.main.url(forResource: "RealtimeSessionConfig", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let session = root["session"] as? [String: Any],
            let modalities = session["output_modalities"] as? [String]
        else { return false }
        return modalities == ["text"]
    }

    static func mintEphemeralSecret(hasBody: Bool) async throws -> String {
        guard let apiKey = Bundle.main.object(forInfoDictionaryKey: "RockyOpenAIKey") as? String,
            !apiKey.isEmpty
        else {
            throw RockyError.commandFailed(
                "no OpenAI API key baked into this build -- run apps/ios/scripts/generate.sh with OPENAI_API_KEY set in the repo root .env, then rebuild"
            )
        }
        guard let configURL = Bundle.main.url(forResource: "RealtimeSessionConfig", withExtension: "json"),
            let bakedBody = try? Data(contentsOf: configURL)
        else {
            throw RockyError.commandFailed("RealtimeSessionConfig.json missing from the app bundle -- run apps/ios/scripts/generate.sh, not xcodegen generate directly")
        }
        // The baked config already describes the one body there is (session.ts), so a robot on the
        // network needs no edit at all. Only its absence does.
        let requestBody = hasBody ? bakedBody : Self.withoutRobotBody(bakedBody)

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/realtime/client_secrets")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("rocky-ios", forHTTPHeaderField: "OpenAI-Safety-Identifier")
        request.httpBody = requestBody
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RockyError.commandFailed("no HTTP response from OpenAI")
        }
        guard (200...299).contains(http.statusCode) else {
            let responseBody = String(decoding: data, as: UTF8.self)
            throw RockyError.commandFailed("OpenAI session creation failed (\(http.statusCode)): \(responseBody.prefix(300))")
        }
        return try JSONDecoder().decode(ClientSecretResponse.self, from: data).value
    }

    /// Strips the body tools out of the baked config and corrects the body context, for when
    /// discovery found no robot. Edits the JSON rather than keeping a second hand-written copy of
    /// the persona in Swift, so session.ts stays the single source of truth for everything except
    /// this one override. Returns the input unchanged if the shape is not what we expect -- a
    /// config we can't parse is better sent as-is than dropped.
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

    /// Changes body capabilities inside an existing Realtime session. Re-minting would throw
    /// away the paused conversation; this updates only instructions and tools, leaving it intact.
    static func bodySessionUpdate(hasBody: Bool) -> [String: Any]? {
        guard let configURL = Bundle.main.url(forResource: "RealtimeSessionConfig", withExtension: "json"),
            let baked = try? Data(contentsOf: configURL)
        else { return nil }
        let selected = hasBody ? baked : withoutRobotBody(baked)
        guard let root = try? JSONSerialization.jsonObject(with: selected) as? [String: Any],
            let session = root["session"] as? [String: Any],
            let instructions = session["instructions"], let tools = session["tools"],
            let toolChoice = session["tool_choice"]
        else { return nil }
        return [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "instructions": instructions,
                "tools": tools,
                "tool_choice": toolChoice,
            ],
        ]
    }

}
