import XCTest

@testable import Rocky

@MainActor
final class PersonalityTests: XCTestCase {
    private func profile(name: String = "Mara", generated: Bool = false) -> EditablePersonality {
        var profile = EditablePersonality.draft()
        profile.name = name
        if generated {
            profile.generatedPrompt = "You are \(name), a fully generated character with a specific life and durable behavior."
            profile.generatedTraits = profile.traits
        }
        return profile
    }

    func testRockyIsTheDefaultAndFixedVoiceChoice() {
        let defaults = UserDefaults(suiteName: "PersonalityTests.default.\(UUID())")!
        let store = PersonalityStore(defaults: defaults)

        let choice = store.choice(for: nil)

        XCTAssertEqual(choice.id, "rocky")
        XCTAssertEqual(choice.speech, .hume)
        XCTAssertNil(choice.customPrompt)
    }

    func testCustomProfilesPersistTraitsAndArbitraryAccountVoice() throws {
        let suite = "PersonalityTests.persist.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var input = profile(generated: true)
        input.traits.humor = 0.91
        input.voiceID = "account-designed-voice"
        input.voiceName = "Moonlight"
        input.generatedTraits = input.traits

        PersonalityStore(defaults: defaults).save(input)
        let restored = try XCTUnwrap(PersonalityStore(defaults: defaults).profile(id: input.id))

        XCTAssertEqual(restored.traits.humor, 0.91)
        XCTAssertEqual(restored.voiceID, "account-designed-voice")
        XCTAssertEqual(restored.voiceName, "Moonlight")
        XCTAssertEqual(restored.generatedPrompt, input.generatedPrompt)
        XCTAssertEqual(restored.generatedTraits, input.generatedTraits)
    }

    func testUnknownSelectionFallsBackToRocky() {
        let store = PersonalityStore(defaults: UserDefaults(suiteName: "PersonalityTests.fallback.\(UUID())")!)
        XCTAssertEqual(store.resolvedID("deleted-personality"), "rocky")
    }

    func testEverySliderChangesOnlyItsAssignedQuoteKind() {
        let mappings: [(LiteraryDNASlot, (inout PersonalityTraits, Double) -> Void)] = [
            (.childhood, { $0.warmth = $1 }),
            (.drive, { $0.energy = $1 }),
            (.comicLens, { $0.humor = $1 }),
            (.dream, { $0.curiosity = $1 }),
            (.voice, { $0.talkativeness = $1 }),
            (.physicalForm, { $0.earthToSky = $1 }),
            (.origin, { $0.fantasyToReality = $1 }),
        ]

        for (expectedSlot, setValue) in mappings {
            var low = PersonalityTraits()
            var high = PersonalityTraits()
            setValue(&low, 0)
            setValue(&high, 1)
            let lowDNA = LiteraryQuoteCatalog.selection(for: low)
            let highDNA = LiteraryQuoteCatalog.selection(for: high)

            XCTAssertNotEqual(lowDNA[expectedSlot]?.id, highDNA[expectedSlot]?.id)
            for slot in LiteraryDNASlot.allCases where slot != expectedSlot {
                XCTAssertEqual(
                    lowDNA[slot]?.id,
                    highDNA[slot]?.id,
                    "\(expectedSlot) slider unexpectedly changed \(slot)"
                )
            }
        }
    }

    func testLiteraryQuoteCorpusHasCompleteAttributedPublicDomainSlots() {
        XCTAssertEqual(Set(LiteraryQuoteCatalog.quotes.map(\.id)).count, LiteraryQuoteCatalog.quotes.count)

        for slot in LiteraryDNASlot.allCases {
            XCTAssertEqual(LiteraryQuoteCatalog.quotes.filter { $0.slot == slot }.count, 5)
        }

        for quote in LiteraryQuoteCatalog.quotes {
            XCTAssertFalse(quote.text.isEmpty)
            XCTAssertFalse(quote.author.isEmpty)
            XCTAssertFalse(quote.work.isEmpty)
            XCTAssertTrue(quote.source.hasPrefix("https://www.gutenberg.org/ebooks/"))
            XCTAssertFalse(quote.text.localizedCaseInsensitiveContains("fat and bunchy"))
        }
    }

    func testLiteraryQuoteSelectionIsDeterministic() {
        let traits = PersonalityTraits(
            warmth: 0.31,
            energy: 0.42,
            humor: 0.53,
            curiosity: 0.64,
            talkativeness: 0.75
        )

        XCTAssertEqual(
            LiteraryQuoteCatalog.selection(for: traits),
            LiteraryQuoteCatalog.selection(for: traits)
        )
    }

    func testProfileHasNoRuntimePromptUntilCreationStoresOne() {
        var profile = profile(name: "Zizzle")
        XCTAssertNil(profile.prompt)
        XCTAssertFalse(profile.isGenerated)

        profile.generatedPrompt = "You are Zizzle, keeper of one extremely particular blue button."
        profile.generatedTraits = profile.traits

        XCTAssertEqual(profile.prompt, profile.generatedPrompt)
        XCTAssertTrue(profile.isGenerated)
    }

    func testVoicePaletteUsesDistinctElevenLabsIDs() {
        XCTAssertEqual(Set(ElevenLabsVoiceOption.choices.map(\.id)).count, ElevenLabsVoiceOption.choices.count)
        XCTAssertEqual(ElevenLabsVoiceOption.choices.map(\.name), ["Comet", "Pip", "Rumble"])
    }

    func testDraftNameIsGeneratedWithoutUserText() {
        let draft = EditablePersonality.draft()

        XCTAssertFalse(draft.name.isEmpty)
    }

    func testAIGenerationRequestUsesSelectedPassagesAndStrictStructuredOutput() throws {
        let traits = PersonalityTraits(
            warmth: 0.12,
            energy: 0.34,
            humor: 0.56,
            curiosity: 0.78,
            talkativeness: 0.9
        )
        let data = try PersonalityGenerator.requestBody(for: traits)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let input = try XCTUnwrap(body["input"] as? String)
        let text = try XCTUnwrap(body["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])

        XCTAssertEqual(body["model"] as? String, "gpt-5.4-mini")
        for quote in LiteraryQuoteCatalog.selection(for: traits).quotes {
            XCTAssertTrue(input.contains(quote.text))
            XCTAssertFalse(input.contains(quote.author))
            XCTAssertFalse(input.contains(quote.work))
        }
        XCTAssertFalse(input.localizedCaseInsensitiveContains("rocky"))
        XCTAssertTrue(input.contains("seven direct public-domain passages"))
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["strict"] as? Bool, true)
        XCTAssertEqual(Set(properties.keys), ["name", "system_prompt"])
        XCTAssertEqual(schema["required"] as? [String], ["name", "system_prompt"])
        XCTAssertEqual(body["max_output_tokens"] as? Int, 1_600)
    }

    func testCreatedNameAndTraditionalPromptParseFromOneResponsesMessage() throws {
        let prompt = "You are Zoodle, a small but exacting night gardener. "
            + String(repeating: "You tend one silver seed, dislike careless promises, and speak from concrete experience. ", count: 8)
        let identityText = try XCTUnwrap(String(
            data: JSONSerialization.data(withJSONObject: [
                "name": "Zoodle",
                "system_prompt": prompt,
            ]),
            encoding: .utf8
        ))
        let response = try JSONSerialization.data(withJSONObject: [
            "output": [["content": [["type": "output_text", "text": identityText]]]],
        ])

        let identity = try PersonalityGenerator.parseResponse(response)

        XCTAssertEqual(identity.name, "Zoodle")
        XCTAssertEqual(identity.systemPrompt, prompt.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertFalse(identity.systemPrompt.localizedCaseInsensitiveContains("rocky"))
    }

    func testUngeneratedProfilesCannotBeSavedOrSelected() {
        let defaults = UserDefaults(suiteName: "PersonalityTests.creation-required.\(UUID())")!
        let store = PersonalityStore(defaults: defaults)
        let draft = profile(name: "Legacy")

        store.save(draft)

        XCTAssertNil(store.profile(id: draft.id))
        XCTAssertEqual(store.resolvedID(draft.id), PersonalityCatalog.defaultCharacterID)
    }

    func testSliderEditInvalidatesGeneratedPromptUntilTheSameTraitsAreRegenerated() {
        var generated = profile(name: "Mara", generated: true)
        let originalTraits = generated.traits

        generated.traits.earthToSky = 1

        XCTAssertTrue(generated.hasGeneratedArtifact)
        XCTAssertFalse(generated.generationIsCurrent)
        XCTAssertNil(generated.prompt)

        generated.traits = originalTraits
        XCTAssertTrue(generated.generationIsCurrent)
        XCTAssertNotNil(generated.prompt)
    }

    func testDeletingProfileRemovesItFromPersistence() {
        let suite = "PersonalityTests.delete.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let generated = profile(generated: true)
        let store = PersonalityStore(defaults: defaults)
        store.save(generated)

        store.delete(id: generated.id)

        XCTAssertNil(store.profile(id: generated.id))
        XCTAssertNil(PersonalityStore(defaults: defaults).profile(id: generated.id))
    }

    func testLegacyTraitsDecodeWithNewWorldAxisDefaults() throws {
        let data = Data(#"{"warmth":0.1,"energy":0.2,"humor":0.3,"curiosity":0.4,"talkativeness":0.5}"#.utf8)
        let traits = try JSONDecoder().decode(PersonalityTraits.self, from: data)

        XCTAssertEqual(traits.earthToSky, 0.35)
        XCTAssertEqual(traits.fantasyToReality, 0.45)
    }
}
