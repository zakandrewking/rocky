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
    /// letting the selected character offer to drive somewhere they can't. Appended last, where
    /// it wins.
    private static let noBodyNote = """
        YOUR BODY — NOT CONNECTED RIGHT NOW
        - This overrides anything above about embodied sensations and movement. You cannot feel or
          move your body while this connection is absent.
        - If movement becomes relevant, say once and naturally that you cannot feel your body right
          now. Do not pretend or narrate imaginary movement, then return to your friend and topic.
        - Your identity, agency, relationships, and conversation are unchanged.
        """

    /// Rocky's full session and a custom-personality session template are dumped from
    /// services/device-api at build time. Swift replaces only the template's persona token; shared
    /// conduct, tools, model, and body rules remain generated from the server source of truth.
    ///
    /// `hasRobot` is false when discovery found no robot: the movement tools are stripped and the
    /// body context corrected, so the app is still a full voice Rocky (what apps/desktop is) even
    /// with no robot in the room.
    static func mintEphemeralSecret(
        hasBody: Bool,
        personality: PersonalityChoice = PersonalityCatalog.rockyChoice
    ) async throws -> String {
        guard let apiKey = Bundle.main.object(forInfoDictionaryKey: "RockyOpenAIKey") as? String,
            !apiKey.isEmpty
        else {
            throw RockyError.commandFailed(
                "no OpenAI API key baked into this build -- run apps/ios/scripts/generate.sh with OPENAI_API_KEY set in the repo root .env, then rebuild"
            )
        }
        guard let requestBody = sessionData(hasBody: hasBody, personality: personality)
        else {
            throw RockyError.commandFailed("selected personality config missing from the app bundle -- run apps/ios/scripts/generate.sh, not xcodegen generate directly")
        }

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
    static func bodySessionUpdate(
        hasBody: Bool,
        personality: PersonalityChoice = PersonalityCatalog.rockyChoice
    ) -> [String: Any]? {
        guard let baked = bakedSessionData(for: personality) else { return nil }
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

    /// The exact instruction string sent for the selected character in the current body state.
    /// The editor uses this instead of reimplementing template substitution, so its preview cannot
    /// drift from session creation. Function-tool schemas are separate Realtime session fields,
    /// not part of the system prompt.
    static func systemInstructions(
        hasBody: Bool,
        personality: PersonalityChoice = PersonalityCatalog.rockyChoice
    ) -> String? {
        guard let data = sessionData(hasBody: hasBody, personality: personality),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let session = root["session"] as? [String: Any]
        else { return nil }
        return session["instructions"] as? String
    }

    private static func sessionData(hasBody: Bool, personality: PersonalityChoice) -> Data? {
        guard let baked = bakedSessionData(for: personality) else { return nil }
        // The baked config already describes the one body there is (session.ts), so a robot on the
        // network needs no edit at all. Only its absence does.
        return hasBody ? baked : withoutRobotBody(baked)
    }

    /// Extracts one generated session from the bundled catalog. Kept internal so tests can prove
    /// that every personality the selector shows can actually start a conversation.
    static func bakedSessionData(
        for personality: PersonalityChoice = PersonalityCatalog.rockyChoice
    ) -> Data? {
        guard let configURL = Bundle.main.url(forResource: "RealtimeSessionConfig", withExtension: "json"),
            let data = try? Data(contentsOf: configURL),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var session: [String: Any]?
        if personality.isRocky {
            let characters = root["characters"] as? [[String: Any]]
            session = characters?.first(where: { $0["id"] as? String == PersonalityCatalog.defaultCharacterID })?["session"] as? [String: Any]
        } else if var custom = root["custom_session"] as? [String: Any],
            let token = root["custom_persona_token"] as? String,
            let prompt = personality.customPrompt,
            let instructions = custom["instructions"] as? String
        {
            custom["instructions"] = instructions.replacingOccurrences(of: token, with: prompt)
            session = custom
        }
        guard let session else { return nil }
        return try? JSONSerialization.data(withJSONObject: ["session": session])
    }

}
