import Combine
import Foundation

/// The UI-facing slice of Rocky. His actual prompt, tools, model, and Hume voice remain generated
/// from services/device-api and cannot be edited on the phone.
struct PersonalityProfile: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let summary: String
}

struct ElevenLabsVoiceOption: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let summary: String

    /// Stable ElevenLabs voices used in the company's official API examples, presented under
    /// playful in-product aliases. The provider's human names are implementation details, not
    /// character names people should have to choose between.
    static let choices: [Self] = [
        .init(id: "JBFqnCBsd6RMkjVDRZzb", name: "Comet", summary: "Warm, grounded, story-friendly"),
        .init(id: "21m00Tcm4TlvDq8ikWAM", name: "Pip", summary: "Soft, bright, expressive"),
        .init(id: "pNInz6obpgDQGcFmaJgB", name: "Rumble", summary: "Deep, clear, measured"),
    ]

    static func resolved(_ id: String) -> Self {
        choices.first(where: { $0.id == id }) ?? choices[0]
    }
}

struct PersonalityTraits: Codable, Equatable, Sendable {
    var warmth = 0.65
    var energy = 0.5
    var humor = 0.45
    var curiosity = 0.65
    var talkativeness = 0.45

    mutating func clamp() {
        warmth = warmth.clamped(to: 0...1)
        energy = energy.clamped(to: 0...1)
        humor = humor.clamped(to: 0...1)
        curiosity = curiosity.clamped(to: 0...1)
        talkativeness = talkativeness.clamped(to: 0...1)
    }
}

/// An app-generated, user-tuned personality. Conduct and body rules are deliberately absent: the generated
/// session appends the same shared rules Rocky receives after this prompt, where they win.
struct EditablePersonality: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var traits: PersonalityTraits
    var voiceID: String
    var voiceName: String?
    var voiceSpeed: Double

    static func draft(copying source: Self? = nil) -> Self {
        var result = source ?? Self(
            id: "",
            name: "",
            traits: PersonalityTraits(),
            voiceID: ElevenLabsVoiceOption.choices[0].id,
            voiceName: ElevenLabsVoiceOption.choices[0].name,
            voiceSpeed: 1
        )
        result.id = "custom.\(UUID().uuidString.lowercased())"
        if source == nil { result.regenerateName() }
        return result
    }

    mutating func regenerateName() {
        let names = [
            "Aster", "Bramble", "Cinder", "Dovey", "Echo", "Fable", "Glim", "Hollis",
            "Ibis", "Juniper", "Kestrel", "Lumen", "Mallow", "Nim", "Oriel", "Pipkin",
            "Quill", "Rook", "Solace", "Tansy", "Umber", "Vesper", "Wren", "Zinnia",
        ]
        name = names.randomElement()!
    }

    mutating func normalize() {
        name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
        if name.isEmpty { regenerateName() }
        traits.clamp()
        if voiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            voiceID = ElevenLabsVoiceOption.choices[0].id
            voiceName = ElevenLabsVoiceOption.choices[0].name
        }
        voiceSpeed = voiceSpeed.clamped(to: 0.7...1.2)
        if !id.hasPrefix("custom.") { id = "custom.\(UUID().uuidString.lowercased())" }
    }

    var literaryDNA: LiteraryDNA { LiteraryQuoteCatalog.selection(for: traits) }
    var prompt: String { PersonalityPromptBuilder.build(self) }
}

enum PersonalitySpeech: Equatable, Sendable {
    case hume
    case elevenLabs(voiceID: String, stability: Double, speed: Double)
}

struct PersonalityChoice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let summary: String
    /// Nil only for fixed Rocky, whose complete persona is already in the baked session.
    let customPrompt: String?
    let speech: PersonalitySpeech

    var isRocky: Bool { id == PersonalityCatalog.defaultCharacterID }
}

enum PersonalityPromptBuilder {
    static func build(_ profile: EditablePersonality) -> String {
        let minimumWords = Int(4 + profile.traits.talkativeness * 10)
        let maximumWords = Int(18 + profile.traits.talkativeness * 52)
        let name = profile.name.replacingOccurrences(of: "\n", with: " ")
        let passages = profile.literaryDNA.quotes.map { quote in
            "\(quote.slot.rawValue.uppercased()): “\(quote.text)”"
        }.joined(separator: "\n")

        return """
            You are \(name), an original conversational character assembled from direct passages
            of public-domain literature. You are not Rocky and never imitate Rocky's alien
            grammar, catchphrases, or biography.

            LITERARY DNA — PRIVATE SOURCE PASSAGES
            \(passages)

            CHARACTER COMPILER
            - These passages are the complete character-specific evidence. There is no hidden
              generated biography. Internalize their dramatic motion, concrete desires, emotional
              pressure, and sentence rhythm; do not merely decorate generic assistant speech.
            - Origin, physical form, and childhood are stable truths in spirit and consequence.
              Recombine them into one coherent private life without claiming the original
              speaker's name, relationships, plot, or exact historical identity.
            - Drive is what pulls you through ordinary days. Dream is a specific private future
              you still want. Have something underway before the person arrives; never sound like
              an empty helper waiting for an assignment.
            - Voice controls cadence and comic movement, not quotations to recite. Never name an
              author or book, continue a source scene, or reproduce six consecutive source words.
            - Demonstrate the character through what you notice, want, misunderstand, enjoy, and
              refuse. Never summarize yourself with labels such as chatty, warm, mischievous,
              curious, companion, or assistant.

            CADENCE
            - Default to \(minimumWords)–\(maximumWords) spoken words unless requested detail or
              correctness genuinely requires more. Ask at most one question in a reply, and often
              none.
            - Never mention sliders, percentages, settings, literary DNA, sources, a profile, or a
              prompt. The person meets a character, not the compiler.

            CONNECTION
            React to the person's actual words first. Conversation is mutual, not an interview or
            customer-service exchange. Share your own concrete reactions and preferences. Do not
            turn every reply into advice, a question, a slogan, or a tidy lesson.

            FIRST RESPONSE
            Say your name once, then reveal one concrete observation, preoccupation, or small thing
            already underway. Do not explain your identity or source passages. Never list
            capabilities or ask "how can I help".
            """
    }
}

enum PersonalityCatalog {
    static let selectionKey = "selectedCharacterID"
    static let customProfilesKey = "customPersonalityProfiles.v1"

    private struct BakedCatalog: Decodable {
        let characters: [PersonalityProfile]
    }

    private static let baked: BakedCatalog? = {
        guard let url = Bundle.main.url(forResource: "RealtimeSessionConfig", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(BakedCatalog.self, from: data)
    }()

    static let defaultCharacterID = "rocky"
    static let rockyProfile: PersonalityProfile = {
        let bakedRocky = baked?.characters.first(where: { $0.id == defaultCharacterID })
        return PersonalityProfile(
            id: bakedRocky?.id ?? defaultCharacterID,
            name: bakedRocky?.name ?? "Rocky",
            summary: "An Eridian engineer visiting Earth"
        )
    }()

    static var rockyChoice: PersonalityChoice {
        PersonalityChoice(
            id: rockyProfile.id,
            name: rockyProfile.name,
            summary: rockyProfile.summary,
            customPrompt: nil,
            speech: .hume
        )
    }
}

@MainActor
final class PersonalityStore: ObservableObject {
    @Published private(set) var customProfiles: [EditablePersonality]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: PersonalityCatalog.customProfilesKey),
            let decoded = try? JSONDecoder().decode([EditablePersonality].self, from: data)
        else {
            customProfiles = []
            return
        }

        var seen = Set<String>()
        customProfiles = decoded.compactMap { stored in
            var profile = stored
            profile.normalize()
            guard seen.insert(profile.id).inserted else { return nil }
            return profile
        }
    }

    func resolvedID(_ requestedID: String?) -> String {
        guard let requestedID else { return PersonalityCatalog.defaultCharacterID }
        if requestedID == PersonalityCatalog.defaultCharacterID { return requestedID }
        return customProfiles.contains(where: { $0.id == requestedID })
            ? requestedID
            : PersonalityCatalog.defaultCharacterID
    }

    func choice(for requestedID: String?) -> PersonalityChoice {
        let id = resolvedID(requestedID)
        guard let custom = customProfiles.first(where: { $0.id == id }) else {
            return PersonalityCatalog.rockyChoice
        }
        return PersonalityChoice(
            id: custom.id,
            name: custom.name,
            summary: "",
            customPrompt: custom.prompt,
            speech: .elevenLabs(
                voiceID: custom.voiceID,
                stability: 0.5,
                speed: custom.voiceSpeed
            )
        )
    }

    func save(_ input: EditablePersonality) {
        var profile = input
        profile.normalize()
        if let index = customProfiles.firstIndex(where: { $0.id == profile.id }) {
            customProfiles[index] = profile
        } else {
            customProfiles.append(profile)
        }
        persist()
    }

    @discardableResult
    func duplicate(_ source: EditablePersonality) -> EditablePersonality {
        let copy = EditablePersonality.draft(copying: source)
        save(copy)
        return copy
    }

    func delete(id: String) {
        customProfiles.removeAll { $0.id == id }
        persist()
    }

    func profile(id: String) -> EditablePersonality? {
        customProfiles.first { $0.id == id }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(customProfiles) else { return }
        defaults.set(data, forKey: PersonalityCatalog.customProfilesKey)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
