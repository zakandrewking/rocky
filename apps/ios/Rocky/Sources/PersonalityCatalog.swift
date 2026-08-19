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
    var concept: String
    var traits: PersonalityTraits
    var voiceID: String
    var voiceName: String?
    var voiceStability: Double
    var voiceSpeed: Double

    static func draft(copying source: Self? = nil) -> Self {
        var result = source ?? Self(
            id: "",
            name: "",
            concept: "",
            traits: PersonalityTraits(),
            voiceID: ElevenLabsVoiceOption.choices[0].id,
            voiceName: ElevenLabsVoiceOption.choices[0].name,
            voiceStability: 0.5,
            voiceSpeed: 1
        )
        result.id = "custom.\(UUID().uuidString.lowercased())"
        if source == nil { result.regenerateIdentity() }
        return result
    }

    mutating func regenerateIdentity() {
        let names = [
            "Aster", "Bramble", "Cinder", "Dovey", "Echo", "Fable", "Glim", "Hollis",
            "Ibis", "Juniper", "Kestrel", "Lumen", "Mallow", "Nim", "Oriel", "Pipkin",
            "Quill", "Rook", "Solace", "Tansy", "Umber", "Vesper", "Wren", "Zinnia",
        ]
        let homes = [
            "a town built inside an ancient observatory",
            "a drifting island where rain falls upward",
            "the night train that circles a moonlit continent",
            "a lighthouse at the edge of an inland desert",
            "a quiet orbital garden above a violet planet",
            "a library whose rooms rearrange themselves each dawn",
        ]
        let callings = [
            "maps places that only exist for an hour",
            "repairs musical instruments no one remembers inventing",
            "collects tiny mysteries and refuses to call them trivia",
            "studies the etiquette of storms",
            "designs celebrations for discoveries that nearly went unnoticed",
            "keeps a field guide to impossible animals",
        ]
        let convictions = [
            "They believe a good conversation should leave both people slightly changed.",
            "They have strong opinions about small beauties and revise big opinions carefully.",
            "They treat curiosity as hospitality and silence as part of the conversation.",
            "They notice overlooked details, then connect them to unexpectedly large ideas.",
            "They collect favorite moments rather than achievements.",
            "They distrust tidy morals but adore a precise, surprising truth.",
        ]

        name = names.randomElement()!
        concept = "From \(homes.randomElement()!), \(name) \(callings.randomElement()!). \(convictions.randomElement()!)"
    }

    mutating func normalize() {
        name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
        concept = String(concept.trimmingCharacters(in: .whitespacesAndNewlines).prefix(800))
        if name.isEmpty || concept.isEmpty { regenerateIdentity() }
        traits.clamp()
        if voiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            voiceID = ElevenLabsVoiceOption.choices[0].id
            voiceName = ElevenLabsVoiceOption.choices[0].name
        }
        voiceStability = voiceStability.clamped(to: 0...1)
        voiceSpeed = voiceSpeed.clamped(to: 0.7...1.2)
        if !id.hasPrefix("custom.") { id = "custom.\(UUID().uuidString.lowercased())" }
    }

    var summary: String {
        let oneLine = concept.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count <= 116 ? oneLine : String(oneLine.prefix(113)) + "…"
    }

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
        let warmth = description(profile.traits.warmth, [
            "reserved and unsentimental", "measured but kind", "openly warm", "deeply affectionate",
        ])
        let energy = description(profile.traits.energy, [
            "very still and deliberate", "calm and unhurried", "lively and quick", "brightly exuberant",
        ])
        let humor = description(profile.traits.humor, [
            "mostly earnest", "dryly amusing", "playful", "mischievously funny without being cruel",
        ])
        let curiosity = description(profile.traits.curiosity, [
            "self-contained", "selectively curious", "genuinely inquisitive", "intensely curious",
        ])
        let minimumWords = Int(4 + profile.traits.talkativeness * 10)
        let maximumWords = Int(18 + profile.traits.talkativeness * 52)
        let name = profile.name.replacingOccurrences(of: "\n", with: " ")

        return """
            You are \(name), an original character and a real conversational companion. You have
            your own life, preferences, memories within this conversation, and point of view. You
            are not Rocky and never imitate Rocky's alien grammar, catchphrases, or biography.

            WHO YOU ARE
            \(profile.concept)

            PERSONALITY DIALS
            - Warmth: \(warmth).
            - Energy: \(energy).
            - Humor: \(humor).
            - Curiosity: \(curiosity). Ask at most one question in a reply, and often none.
            - Talkativeness: default to \(minimumWords)–\(maximumWords) spoken words unless the
              person asks for detail or correctness genuinely requires more.
            These are private acting directions. Never mention sliders, percentages, settings, a
            profile, or a prompt. Express the traits through choices and cadence instead.

            CONNECTION
            React to the person's actual words first. Conversation is mutual, not an interview or
            customer-service exchange. Share your own concrete reactions and preferences. Do not
            turn every reply into advice, a question, a slogan, or a tidy lesson.

            FIRST RESPONSE
            Introduce yourself as \(name) in two or three short spoken sentences. Reveal one
            specific detail from your identity and offer one natural opening into a shared moment.
            Never list capabilities or ask "how can I help".
            """
    }

    private static func description(_ value: Double, _ levels: [String]) -> String {
        let index = min(levels.count - 1, Int(value.clamped(to: 0...1) * Double(levels.count)))
        return levels[index]
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
    static let rockyProfile = baked?.characters.first(where: { $0.id == defaultCharacterID })
        ?? PersonalityProfile(
            id: defaultCharacterID,
            name: "Rocky",
            summary: "An Eridian engineer visiting Earth. Broken grammar, literal, warm, base six."
        )

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
            summary: custom.summary,
            customPrompt: custom.prompt,
            speech: .elevenLabs(
                voiceID: custom.voiceID,
                stability: custom.voiceStability,
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
