import XCTest

@testable import Rocky

@MainActor
final class PersonalityTests: XCTestCase {
    private func profile(name: String = "Mara") -> EditablePersonality {
        var profile = EditablePersonality.draft()
        profile.name = name
        profile.concept = "A lunar cartographer who loves impossible coastlines."
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

        XCTAssertTrue(quiet.prompt.contains("reserved and unsentimental"))
        XCTAssertTrue(quiet.prompt.contains("4–18 spoken words"))
        XCTAssertTrue(vivid.prompt.contains("deeply affectionate"))
        XCTAssertTrue(vivid.prompt.contains("14–70 spoken words"))
        XCTAssertTrue(vivid.prompt.contains("never imitate Rocky"))
    }

    func testVoicePaletteUsesDistinctElevenLabsIDs() {
        XCTAssertEqual(Set(ElevenLabsVoiceOption.choices.map(\.id)).count, ElevenLabsVoiceOption.choices.count)
        XCTAssertEqual(ElevenLabsVoiceOption.choices.map(\.name), ["Comet", "Pip", "Rumble"])
    }

    func testDraftIdentityIsGeneratedWithoutUserText() {
        let draft = EditablePersonality.draft()

        XCTAssertFalse(draft.name.isEmpty)
        XCTAssertFalse(draft.concept.isEmpty)
        XCTAssertTrue(draft.concept.contains(draft.name))
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

        XCTAssertEqual(body["model"] as? String, "gpt-5.4-mini")
        XCTAssertTrue(input.contains("warmth 12"))
        XCTAssertTrue(input.contains("talkativeness 90"))
        XCTAssertTrue(input.contains("George"))
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["strict"] as? Bool, true)
    }

    func testAIIdentityParsesFromAResponsesOutputMessage() throws {
        let concept = "From a workshop hidden beneath a thundercloud, Zoodle tunes lightning into tiny songs. They believe every stubborn problem has a rhythm, greet surprises with delighted questions, and always pause to thank useful mistakes. When excited, they arrange nearby objects into constellations before explaining what they have discovered."
        let identityText = try XCTUnwrap(String(
            data: JSONSerialization.data(withJSONObject: ["name": "Zoodle", "concept": concept]),
            encoding: .utf8
        ))
        let response = try JSONSerialization.data(withJSONObject: [
            "output": [["content": [["type": "output_text", "text": identityText]]]],
        ])

        let identity = try PersonalityGenerator.parseResponse(response)

        XCTAssertEqual(identity.name, "Zoodle")
        XCTAssertEqual(identity.concept, concept)
    }
}
