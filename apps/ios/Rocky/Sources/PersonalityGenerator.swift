import Foundation

struct GeneratedPersonality: Equatable, Sendable {
    let name: String
    let systemPrompt: String
}

/// Synthesizes the selected public-domain passages into one compressed character essence and a matching
/// name in a single creation call, then wraps that creative result in deterministic instructions.
/// This intentionally uses the same personal-device
/// OpenAI key as Realtime session minting: there is no user-authored
/// prompt and no laptop service in the on-device flow.
enum PersonalityGenerator {
    private static let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    static let essenceInstruction =
        "You are a character whose essence derives from the following; embody it in all that you say and do."

    private struct GeneratedPayload: Decodable {
        let name: String
        let characterEssence: String

        private enum CodingKeys: String, CodingKey {
            case name
            case characterEssence = "character_essence"
        }
    }

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
        return try parseResponse(data)
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

            Return a playful, memorable one-word name and a character essence. The app will place
            the essence immediately after this instruction:
            "\(essenceInstruction)"

            Write the essence directly to the character in second person. Make it a tiny character
            poem: two to four short stanzas, 45–80 words total. It is not a mood poem. Nearly every
            phrase must be a concrete piece of evidence: a number, named object, bodily feature,
            place, remembered incident, repeated action, expense, promise, or unfinished project.
            Preserve distinctive nouns, verbs, quantities, and turns of phrase from the sources;
            public-domain wording may be reused directly. Add only enough connective language to
            identify who each detail belongs to and make the seven details one possible life.

            Include one unmistakable detail from every passage. Together they must establish the
            character’s physical form, origin, childhood, present pursuit, comic logic, private
            dream, and manner of speech. Prefer a source fact such as “twenty-five dollars” over an
            interpretation such as “self-sacrificing,” and the “old tin kitchen” over “ambitious.”
            Do not explain what a detail symbolizes. Let the evidence do that work.

            Do not write a trait inventory, literary analysis, generic biography, heading, or
            policy section. Do not repeat the generated name; the app introduces it separately.
            Never mention passages, books, authors, sources, sliders, dials, compilation, profiles,
            AI, assistants, or settings. Do not inherit an original speaker's proper name,
            relationships, historical era, or plot. Transpose source facts into the new life while
            keeping their particular diction.
            Avoid generic labels such as chatty, warm, mischievous, curious, companion, or helper;
            make disposition visible through remembered scenes, choices, rituals, and speech.

            Derive cadence and reply length from the VOICE passage. Give the essence a first-response
            instinct that says the character's name once and reveals the ongoing preoccupation,
            without listing capabilities or asking how to help. Conversation should feel mutual,
            not like an interview.

            The name must be 2–20 characters with no spaces and must not be Comet, Pip, Rumble,
            George, Rachel, or Adam. The complete character essence must be 45–80 words. Preserve
            the required life details; cut transitions, explanation, interpretation, repetition,
            and ornament first. Return no prose outside the structured fields.
            """

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "name": [
                    "type": "string",
                    "description": "A playful one-word character nickname, 2–20 characters.",
                ],
                "character_essence": [
                    "type": "string",
                    "description": "A 45–80 word character poem made almost entirely of concrete details from all seven passages.",
                ],
            ],
            "required": ["name", "character_essence"],
            "additionalProperties": false,
        ]
        let body: [String: Any] = [
            "model": "gpt-5.4-mini",
            "input": brief,
            "text": [
                "verbosity": "low",
                "format": [
                    "type": "json_schema",
                    "name": "compiled_personality",
                    "strict": true,
                    "schema": schema,
                ],
            ],
            "max_output_tokens": 800,
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    static func parseResponse(_ data: Data) throws -> GeneratedPersonality {
        let response = try JSONDecoder().decode(ResponsesEnvelope.self, from: data)
        guard let text = response.output
            .compactMap(\.content)
            .flatMap({ $0 })
            .first(where: { $0.type == "output_text" })?.text,
            let json = text.data(using: .utf8)
        else {
            throw RockyError.commandFailed("OpenAI returned no compiled personality.")
        }

        let generated = try JSONDecoder().decode(GeneratedPayload.self, from: json)
        let name = generated.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let essence = generated.characterEssence.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = Set(["comet", "pip", "rumble", "george", "rachel", "adam"])

        guard (2...20).contains(name.count),
            !name.contains(where: \.isWhitespace),
            !forbidden.contains(name.lowercased())
        else {
            throw RockyError.commandFailed("OpenAI returned a name that did not fit the requested style.")
        }
        guard (45...80).contains(essence.split(whereSeparator: \.isWhitespace).count),
            !essence.localizedCaseInsensitiveContains("rocky")
        else {
            throw RockyError.commandFailed("OpenAI returned an essence that did not fit the requested character.")
        }
        return GeneratedPersonality(
            name: name,
            systemPrompt: compileSystemPrompt(name: name, essence: essence)
        )
    }

    static func compileSystemPrompt(name: String, essence: String) -> String {
        """
        \(essenceInstruction)

        Your name is \(name).

        \(essence.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }

}
