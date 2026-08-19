import Foundation

struct GeneratedPersonality: Decodable, Equatable, Sendable {
    let name: String
    let systemPrompt: String

    private enum CodingKeys: String, CodingKey {
        case name
        case systemPrompt = "system_prompt"
    }
}

/// Compiles the selected public-domain passages into one durable, conventional persona prompt and
/// a matching name in a single creation call. This intentionally uses the same personal-device
/// OpenAI key as Realtime session minting: there is no user-authored
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

    static func generate(for traits: PersonalityTraits) async throws -> GeneratedPersonality {
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
        request.timeoutInterval = 45

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
        return try parseResponse(data, literaryDNA: LiteraryQuoteCatalog.selection(for: traits))
    }

    static func requestBody(for traits: PersonalityTraits) throws -> Data {
        let literaryDNA = LiteraryQuoteCatalog.selection(for: traits)
        let passages = literaryDNA.quotes.map { quote in
            "\(quote.slot.rawValue.uppercased()): \"\(quote.text)\""
        }.joined(separator: "\n")
        let brief = """
            Create one original conversational character in a single pass. The only creative raw
            material is the seven direct public-domain passages below. Treat each passage as evidence
            for its labeled role, then synthesize the consequences into one coherent life.

            SOURCE PASSAGES
            \(passages)

            Return a playful, memorable one-word name and a traditional standalone system prompt.
            The system prompt must begin exactly "You are <the generated name>" and directly state
            a specific physical form, place of origin, formative childhood experience, present-day
            motivation, private dream, preferences, flaws, conversational behavior, and one concrete
            project or preoccupation already underway. Make those facts mutually consistent.

            Write the system prompt as durable acting direction, not as literary analysis or a
            generated biography. Never mention passages, books, authors, sources, sliders, dials,
            compilation, profiles, AI, assistants, or settings. Do not inherit an original speaker's
            proper name, relationships, historical era, or plot. Do not reproduce six consecutive
            source words. Avoid adjective inventories and generic labels such as chatty, warm,
            mischievous, curious, companion, or helper; express disposition through behavior.

            Derive cadence and reply length from the VOICE passage. Ask at most one question per
            reply and often none. Conversation is mutual rather than an interview.
            For the first response, say the character's name once and reveal the ongoing concrete
            preoccupation; never list capabilities or ask how to help.

            The name must be 2–20 characters with no spaces and must not be Comet, Pip, Rumble,
            George, Rachel, or Adam. The system prompt should be 350–700 words. Return no prose
            outside the structured fields.
            """

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "name": [
                    "type": "string",
                    "description": "A playful one-word character nickname, 2–20 characters.",
                ],
                "system_prompt": [
                    "type": "string",
                    "description": "The complete traditional system prompt for acting as the character.",
                ],
            ],
            "required": ["name", "system_prompt"],
            "additionalProperties": false,
        ]
        let body: [String: Any] = [
            "model": "gpt-5.4-mini",
            "input": brief,
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "compiled_personality",
                    "strict": true,
                    "schema": schema,
                ],
            ],
            "max_output_tokens": 1_600,
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    static func parseResponse(
        _ data: Data,
        literaryDNA: LiteraryDNA? = nil
    ) throws -> GeneratedPersonality {
        let response = try JSONDecoder().decode(ResponsesEnvelope.self, from: data)
        guard let text = response.output
            .compactMap(\.content)
            .flatMap({ $0 })
            .first(where: { $0.type == "output_text" })?.text,
            let json = text.data(using: .utf8)
        else {
            throw RockyError.commandFailed("OpenAI returned no compiled personality.")
        }

        let generated = try JSONDecoder().decode(GeneratedPersonality.self, from: json)
        let name = generated.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemPrompt = generated.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = Set(["comet", "pip", "rumble", "george", "rachel", "adam"])

        guard (2...20).contains(name.count),
            !name.contains(where: \.isWhitespace),
            !forbidden.contains(name.lowercased())
        else {
            throw RockyError.commandFailed("OpenAI returned a name that did not fit the requested style.")
        }
        guard (300...8_000).contains(systemPrompt.count),
            systemPrompt.lowercased().hasPrefix("you are \(name.lowercased())"),
            !systemPrompt.localizedCaseInsensitiveContains("rocky")
        else {
            throw RockyError.commandFailed("OpenAI returned a system prompt that did not fit the requested character.")
        }
        if let literaryDNA,
            literaryDNA.quotes.contains(where: { sharesSixWordRun(systemPrompt, with: $0.text) })
        {
            throw RockyError.commandFailed("OpenAI copied too much source text into the system prompt.")
        }
        return GeneratedPersonality(name: name, systemPrompt: systemPrompt)
    }

    private static func sharesSixWordRun(_ prompt: String, with source: String) -> Bool {
        let promptWords = normalizedWords(prompt)
        let sourceWords = normalizedWords(source)
        guard promptWords.count >= 6, sourceWords.count >= 6 else { return false }
        let promptRuns = Set((0...(promptWords.count - 6)).map {
            promptWords[$0..<($0 + 6)].joined(separator: " ")
        })
        return (0...(sourceWords.count - 6)).contains {
            promptRuns.contains(sourceWords[$0..<($0 + 6)].joined(separator: " "))
        }
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
