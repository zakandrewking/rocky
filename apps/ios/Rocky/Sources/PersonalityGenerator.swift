import Foundation

struct GeneratedPersonalityName: Decodable, Equatable, Sendable {
    let name: String
}

/// Turns the personality dials into a playful name. This intentionally
/// uses the same personal-device OpenAI key as Realtime session minting: there is no user-authored
/// prompt and no laptop service in the on-device flow.
enum PersonalityGenerator {
    private static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    private struct ResponsesEnvelope: Decodable {
        struct Output: Decodable {
            struct Content: Decodable {
                let type: String
                let text: String?
            }

            let content: [Content]?
        }

        let output: [Output]
    }

    static func generate(for traits: PersonalityTraits) async throws -> GeneratedPersonalityName {
        guard let apiKey = Bundle.main.object(forInfoDictionaryKey: "RockyOpenAIKey") as? String,
            !apiKey.isEmpty
        else {
            throw RockyError.commandFailed(
                "OpenAI is not configured in this build. Rebuild after adding OPENAI_API_KEY to .env."
            )
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("rocky-ios-personality-generator", forHTTPHeaderField: "OpenAI-Safety-Identifier")
        request.httpBody = try requestBody(for: traits)
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RockyError.commandFailed("No HTTP response while generating the personality.")
        }
        guard (200...299).contains(http.statusCode) else {
            let detail = String(decoding: data, as: UTF8.self)
            throw RockyError.commandFailed(
                "Personality generation failed (\(http.statusCode)): \(detail.prefix(240))"
            )
        }
        return try parseResponse(data)
    }

    static func requestBody(for traits: PersonalityTraits) throws -> Data {
        let brief = """
            Invent a character matching these acting dials, each from 0 to 100:
            warmth \(score(traits.warmth)), energy \(score(traits.energy)), humor \(score(traits.humor)),
            curiosity \(score(traits.curiosity)), talkativeness \(score(traits.talkativeness)).

            Return only a fun, memorable, one-word nickname in the spirit of Rocky, Comet, Pip, or
            Rumble—but do not use those names. Let the sound of the name subtly fit the dials.
            Never use an ordinary human name such as George, Rachel, or Adam. Do not invent or
            return a biography, description, backstory, title, heading, or any other text.
            """

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "name": [
                    "type": "string",
                    "description": "A playful one-word character nickname, 2–20 characters.",
                ],
            ],
            "required": ["name"],
            "additionalProperties": false,
        ]
        let body: [String: Any] = [
            "model": "gpt-5.4-mini",
            "input": brief,
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "personality_name",
                    "strict": true,
                    "schema": schema,
                ],
            ],
            "max_output_tokens": 80,
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    static func parseResponse(_ data: Data) throws -> GeneratedPersonalityName {
        let response = try JSONDecoder().decode(ResponsesEnvelope.self, from: data)
        guard let text = response.output
            .compactMap(\.content)
            .flatMap({ $0 })
            .first(where: { $0.type == "output_text" })?.text,
            let json = text.data(using: .utf8)
        else {
            throw RockyError.commandFailed("OpenAI returned no personality name.")
        }

        let generated = try JSONDecoder().decode(GeneratedPersonalityName.self, from: json)
        let name = generated.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = Set(["rocky", "comet", "pip", "rumble", "george", "rachel", "adam"])

        guard (2...20).contains(name.count),
            !name.contains(where: \.isWhitespace),
            !forbidden.contains(name.lowercased())
        else {
            throw RockyError.commandFailed("OpenAI returned a name that did not fit the requested style.")
        }
        return GeneratedPersonalityName(name: name)
    }

    private static func score(_ value: Double) -> Int {
        Int((min(1, max(0, value)) * 100).rounded())
    }
}
