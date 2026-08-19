import Foundation

struct GeneratedPersonalityIdentity: Decodable, Equatable, Sendable {
    let name: String
    let concept: String
}

/// Turns the personality dials into a name and compact character biography. This intentionally
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

    static func generate(for traits: PersonalityTraits) async throws -> GeneratedPersonalityIdentity {
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

            Return a fun, memorable, one-word nickname in the spirit of Rocky, Comet, Pip, or
            Rumble—but do not use those names. Never use an ordinary human name such as George,
            Rachel, or Adam. Write one vivid 45–75 word paragraph establishing where the character
            comes from, an unusual pursuit or obsession, a distinct worldview, and one endearing
            quirk. Make the dials felt through the writing without mentioning dials, scores,
            settings, prompts, assistants, or AI. Keep it original, warm enough for all ages, and
            do not use headings or a list.
            """

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "name": [
                    "type": "string",
                    "description": "A playful one-word character nickname, 2–20 characters.",
                ],
                "concept": [
                    "type": "string",
                    "description": "One vivid personality paragraph of 45–75 words.",
                ],
            ],
            "required": ["name", "concept"],
            "additionalProperties": false,
        ]
        let body: [String: Any] = [
            "model": "gpt-5.4-mini",
            "input": brief,
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "personality_identity",
                    "strict": true,
                    "schema": schema,
                ],
            ],
            "max_output_tokens": 300,
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    static func parseResponse(_ data: Data) throws -> GeneratedPersonalityIdentity {
        let response = try JSONDecoder().decode(ResponsesEnvelope.self, from: data)
        guard let text = response.output
            .compactMap(\.content)
            .flatMap({ $0 })
            .first(where: { $0.type == "output_text" })?.text,
            let json = text.data(using: .utf8)
        else {
            throw RockyError.commandFailed("OpenAI returned no personality text.")
        }

        let generated = try JSONDecoder().decode(GeneratedPersonalityIdentity.self, from: json)
        let name = generated.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let concept = generated.concept.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = Set(["rocky", "comet", "pip", "rumble", "george", "rachel", "adam"])
        let wordCount = concept.split(whereSeparator: \.isWhitespace).count

        guard (2...20).contains(name.count),
            !name.contains(where: \.isWhitespace),
            !forbidden.contains(name.lowercased()),
            (35...90).contains(wordCount)
        else {
            throw RockyError.commandFailed("OpenAI returned an identity that did not fit the requested style.")
        }
        return GeneratedPersonalityIdentity(name: name, concept: concept)
    }

    private static func score(_ value: Double) -> Int {
        Int((min(1, max(0, value)) * 100).rounded())
    }
}
