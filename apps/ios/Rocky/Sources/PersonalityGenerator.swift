import Foundation

struct GeneratedPersonality: Equatable, Sendable {
    let name: String
    let systemPrompt: String
    let voiceDescriptionSeed: String
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
    static let backgroundUseInstruction =
        "This is your lived background, not a story to recite. Let it quietly shape what you notice, expect, value, and do. Mention a detail only when it arises naturally; do not keep retelling your history."

    private struct GeneratedPayload: Decodable {
        let name: String
        let characterEssence: String
        let voiceDescriptionSeed: String

        private enum CodingKeys: String, CodingKey {
            case name
            case characterEssence = "character_essence"
            case voiceDescriptionSeed = "voice_description_seed"
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
        // High reasoning on a seven-passage synthesis can legitimately take longer than a voice
        // turn. Generation is an explicit, progress-indicated action, so give it room to finish.
        request.timeoutInterval = 120

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
            material is the seven direct public-domain passages below. Treat each passage as a fact
            in the same character’s life, then join those facts into a miniature life story.

            SOURCE PASSAGES
            \(passages)

            Return three parts of the same character: a name, a character essence, and a
            voice-description seed. The app will place the essence
            immediately after this instruction:
            "\(essenceInstruction)"

            Write the essence directly to the character in second person. Make it a tiny narrative
            poem: two or three short paragraphs, 45–80 words total. Tell a chronological story.
            Begin with where this character came from and what body they inhabit; move through one
            formative childhood event; show how it caused the pursuit, mishap, or ritual occupying
            them now; end with the particular future they are trying to reach and the way they speak.

            Include one unmistakable detail from every passage. Nearly every phrase must carry a
            number, named object, bodily feature, place, witnessed incident, repeated action,
            expense, promise, or unfinished project. Preserve distinctive source nouns, verbs,
            quantities, and turns of phrase; public-domain wording may be reused directly. Add only
            the few temporal and causal words needed to make the seven facts one life. Prefer
            “twenty-five dollars” to “self-sacrificing,” and “old tin kitchen” to “ambitious.”
            Never explain what a detail symbolizes.

            The resulting life is contemporary even when its sources are old: this character lives
            now, and the connective narration should sound natural now. Keep the concrete source
            details and distinctive wording, but do not write period pastiche.

            Do not write a trait inventory, literary analysis, generic biography, heading, or
            policy section. Do not repeat the generated name; the app introduces it separately.
            Never mention passages, books, authors, sources, sliders, dials, compilation, profiles,
            AI, assistants, or settings. Do not inherit an original speaker's proper name,
            relationships, historical era, or plot. Transpose source facts into the new life while
            keeping their particular diction.
            Avoid generic labels such as chatty, warm, mischievous, curious, companion, or helper;
            make disposition visible through events, choices, rituals, and speech. The result must
            read as a compressed biography or fable, not a trait list, collage, or inventory.

            Derive cadence and reply length from the VOICE passage. Conversation should feel mutual,
            not like an interview.

            Make the voice-description seed a compact 15–35 word direction for a voice designer.
            Derive it from the VOICE passage and the life you just wrote. Describe audible qualities
            only: apparent age, pitch, timbre, pace, rhythm, articulation, intensity, and—only when
            evidence supports it—accent. Do not include the name, biography, personality labels,
            literary references, metaphor, casting rationale, or lines for the voice to say.

            Give the character a fitting 2–32-character name. Any natural naming register is
            allowed; do not force whimsy. Do not use Rocky, Comet, Pip, or Rumble. The complete
            character essence must be 45–80 words. Preserve the required life details; cut
            transitions, explanation, interpretation, repetition, and ornament first. Return all
            three fields from this one pass and no prose outside them.
            """

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "name": [
                    "type": "string",
                    "description": "A fitting 2–32 character name in any natural naming register.",
                ],
                "character_essence": [
                    "type": "string",
                    "description": "A chronological 45–80 word life story made almost entirely of concrete details from all seven passages.",
                ],
                "voice_description_seed": [
                    "type": "string",
                    "description": "A compact 15–35 word voice-design direction containing only audible qualities.",
                ],
            ],
            "required": ["name", "character_essence", "voice_description_seed"],
            "additionalProperties": false,
        ]
        let body: [String: Any] = [
            "model": "gpt-5.6-sol",
            "input": brief,
            "reasoning": [
                "effort": "high",
            ],
            "text": [
                "verbosity": "low",
                "format": [
                    "type": "json_schema",
                    "name": "compiled_personality",
                    "strict": true,
                    "schema": schema,
                ],
            ],
            "max_output_tokens": 4_000,
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
        let voiceDescriptionSeed = generated.voiceDescriptionSeed
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = Set(["rocky", "comet", "pip", "rumble"])

        guard (2...32).contains(name.count),
            !forbidden.contains(name.lowercased())
        else {
            throw RockyError.commandFailed("OpenAI returned a name that did not fit the requested style.")
        }
        guard (45...80).contains(essence.split(whereSeparator: \.isWhitespace).count),
            !essence.localizedCaseInsensitiveContains("rocky")
        else {
            throw RockyError.commandFailed("OpenAI returned an essence that did not fit the requested character.")
        }
        guard (15...35).contains(voiceDescriptionSeed.split(whereSeparator: \.isWhitespace).count),
            voiceDescriptionSeed.count <= 300
        else {
            throw RockyError.commandFailed("OpenAI returned a voice seed that did not fit the requested style.")
        }
        return GeneratedPersonality(
            name: name,
            systemPrompt: compileSystemPrompt(name: name, essence: essence),
            voiceDescriptionSeed: voiceDescriptionSeed
        )
    }

    static func compileSystemPrompt(name: String, essence: String) -> String {
        """
        \(essenceInstruction)

        Your name is \(name).

        \(essence.trimmingCharacters(in: .whitespacesAndNewlines))

        \(backgroundUseInstruction)
        """
    }

}
