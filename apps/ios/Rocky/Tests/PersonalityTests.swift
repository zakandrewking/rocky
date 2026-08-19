import XCTest

@testable import Rocky

@MainActor
final class PersonalityTests: XCTestCase {
    private func profile(name: String = "Mara") -> EditablePersonality {
        var profile = EditablePersonality.draft()
        profile.name = name
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
        var input = profile()
        input.traits.humor = 0.91
        input.voiceID = "account-designed-voice"
        input.voiceName = "Moonlight"

        PersonalityStore(defaults: defaults).save(input)
        let restored = try XCTUnwrap(PersonalityStore(defaults: defaults).profile(id: input.id))

        XCTAssertEqual(restored.traits.humor, 0.91)
        XCTAssertEqual(restored.voiceID, "account-designed-voice")
        XCTAssertEqual(restored.voiceName, "Moonlight")
    }

    func testUnknownSelectionFallsBackToRocky() {
        let store = PersonalityStore(defaults: UserDefaults(suiteName: "PersonalityTests.fallback.\(UUID())")!)
        XCTAssertEqual(store.resolvedID("deleted-personality"), "rocky")
    }

    func testSlidersMateriallyChangeTheGeneratedActingDirections() {
        var quiet = profile()
        quiet.traits = PersonalityTraits(warmth: 0, energy: 0, humor: 0, curiosity: 0, talkativeness: 0)
        var vivid = profile()
        vivid.traits = PersonalityTraits(warmth: 1, energy: 1, humor: 1, curiosity: 1, talkativeness: 1)

        XCTAssertEqual(quiet.literaryDNA.quotes.count, LiteraryDNASlot.allCases.count)
        XCTAssertEqual(vivid.literaryDNA.quotes.count, LiteraryDNASlot.allCases.count)
        XCTAssertNotEqual(quiet.literaryDNA.quotes.map(\.id), vivid.literaryDNA.quotes.map(\.id))
        for quote in quiet.literaryDNA.quotes {
            XCTAssertTrue(quiet.prompt.contains(quote.text))
        }
        for quote in vivid.literaryDNA.quotes {
            XCTAssertTrue(vivid.prompt.contains(quote.text))
        }
        XCTAssertTrue(quiet.prompt.contains("LITERARY DNA"))
        XCTAssertTrue(quiet.prompt.contains("4–18 spoken words"))
        XCTAssertTrue(vivid.prompt.contains("14–70 spoken words"))
        XCTAssertTrue(vivid.prompt.contains("never imitate Rocky"))
        XCTAssertFalse(quiet.prompt.contains("reserved and unsentimental"))
        XCTAssertFalse(vivid.prompt.contains("identity is deliberately underspecified"))
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

    func testCompiledPromptUsesPassagesButDoesNotExposeTheirSources() {
        let profile = profile(name: "Zizzle")
        let prompt = profile.prompt

        for quote in profile.literaryDNA.quotes {
            XCTAssertTrue(prompt.contains(quote.text))
            XCTAssertFalse(prompt.contains(quote.author))
            XCTAssertFalse(prompt.contains(quote.work))
        }
    }

    func testVoicePaletteUsesDistinctElevenLabsIDs() {
        XCTAssertEqual(Set(ElevenLabsVoiceOption.choices.map(\.id)).count, ElevenLabsVoiceOption.choices.count)
        XCTAssertEqual(ElevenLabsVoiceOption.choices.map(\.name), ["Comet", "Pip", "Rumble"])
    }

    func testDraftNameIsGeneratedWithoutUserText() {
        let draft = EditablePersonality.draft()

        XCTAssertFalse(draft.name.isEmpty)
    }

    func testAIGenerationRequestUsesSlidersAndStrictStructuredOutput() throws {
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
        XCTAssertTrue(input.contains("warmth 12"))
        XCTAssertTrue(input.contains("talkativeness 90"))
        XCTAssertTrue(input.contains("George"))
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["strict"] as? Bool, true)
        XCTAssertEqual(Set(properties.keys), ["name"])
        XCTAssertEqual(schema["required"] as? [String], ["name"])
    }

    func testAINameParsesFromAResponsesOutputMessage() throws {
        let identityText = try XCTUnwrap(String(
            data: JSONSerialization.data(withJSONObject: ["name": "Zoodle"]),
            encoding: .utf8
        ))
        let response = try JSONSerialization.data(withJSONObject: [
            "output": [["content": [["type": "output_text", "text": identityText]]]],
        ])

        let identity = try PersonalityGenerator.parseResponse(response)

        XCTAssertEqual(identity.name, "Zoodle")
    }
}
