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
    var earthToSky = 0.35
    var fantasyToReality = 0.45

    private enum CodingKeys: String, CodingKey {
        case warmth, energy, humor, curiosity, talkativeness, earthToSky, fantasyToReality
    }

    init(
        warmth: Double = 0.65,
        energy: Double = 0.5,
        humor: Double = 0.45,
        curiosity: Double = 0.65,
        talkativeness: Double = 0.45,
        earthToSky: Double = 0.35,
        fantasyToReality: Double = 0.45
    ) {
        self.warmth = warmth
        self.energy = energy
        self.humor = humor
        self.curiosity = curiosity
        self.talkativeness = talkativeness
        self.earthToSky = earthToSky
        self.fantasyToReality = fantasyToReality
    }

    static func randomized() -> Self {
        Self(
            warmth: .random(in: 0...1),
            energy: .random(in: 0...1),
            humor: .random(in: 0...1),
            curiosity: .random(in: 0...1),
            talkativeness: .random(in: 0...1),
            earthToSky: .random(in: 0...1),
            fantasyToReality: .random(in: 0...1)
        )
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        warmth = try values.decode(Double.self, forKey: .warmth)
        energy = try values.decode(Double.self, forKey: .energy)
        humor = try values.decode(Double.self, forKey: .humor)
        curiosity = try values.decode(Double.self, forKey: .curiosity)
        talkativeness = try values.decode(Double.self, forKey: .talkativeness)
        // Profiles saved before these axes existed migrate to deliberately moderate defaults.
        earthToSky = try values.decodeIfPresent(Double.self, forKey: .earthToSky) ?? 0.35
        fantasyToReality = try values.decodeIfPresent(Double.self, forKey: .fantasyToReality) ?? 0.45
    }

    mutating func clamp() {
        warmth = warmth.clamped(to: 0...1)
        energy = energy.clamped(to: 0...1)
        humor = humor.clamped(to: 0...1)
        curiosity = curiosity.clamped(to: 0...1)
        talkativeness = talkativeness.clamped(to: 0...1)
        earthToSky = earthToSky.clamped(to: 0...1)
        fantasyToReality = fantasyToReality.clamped(to: 0...1)
    }
}

/// An app-generated, user-tuned personality. Conduct and body rules are deliberately absent: the
/// generated session appends the shared device rules after this prompt, where they win.
struct EditablePersonality: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var traits: PersonalityTraits
    var voiceID: String
    var voiceName: String?
    var voiceSpeed: Double
    var generatedPrompt: String?
    /// A voice-design brief produced in the same pass as the character. Retained for the voice
    /// design stage without mixing synthesis directions into the conversational system prompt.
    var generatedVoiceDescriptionSeed: String?
    /// The exact slider state compiled into `generatedPrompt`. Persisting this provenance makes it
    /// impossible for a stale prompt to become selectable after an edit or relaunch.
    var generatedTraits: PersonalityTraits?

    static func draft(copying source: Self? = nil) -> Self {
        var result = source ?? Self(
            id: "",
            name: "",
            traits: .randomized(),
            voiceID: ElevenLabsVoiceOption.choices[0].id,
            voiceName: ElevenLabsVoiceOption.choices[0].name,
            voiceSpeed: 1,
            generatedPrompt: nil,
            generatedVoiceDescriptionSeed: nil,
            generatedTraits: nil
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
        generatedPrompt = generatedPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        generatedVoiceDescriptionSeed = generatedVoiceDescriptionSeed?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if generatedVoiceDescriptionSeed?.isEmpty == true { generatedVoiceDescriptionSeed = nil }
        if generatedPrompt?.isEmpty == true { generatedPrompt = nil }
        if generatedPrompt == nil {
            generatedVoiceDescriptionSeed = nil
            generatedTraits = nil
        } else {
            generatedTraits?.clamp()
        }
        if !id.hasPrefix("custom.") { id = "custom.\(UUID().uuidString.lowercased())" }
    }

    var literaryDNA: LiteraryDNA { LiteraryQuoteCatalog.selection(for: traits) }
    var hasGeneratedArtifact: Bool {
        guard let generatedPrompt else { return false }
        return !generatedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && generatedTraits != nil
    }
    var generationIsCurrent: Bool { hasGeneratedArtifact && generatedTraits == traits }
    var voiceDescriptionSeed: String? {
        guard generationIsCurrent else { return nil }
        return generatedVoiceDescriptionSeed
    }
    var prompt: String? {
        guard generationIsCurrent else { return nil }
        guard let generatedPrompt = generatedPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
            !generatedPrompt.isEmpty
        else { return nil }
        return generatedPrompt
    }
    var isGenerated: Bool { generationIsCurrent }
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
        return customProfiles.contains(where: { $0.id == requestedID && $0.isGenerated })
            ? requestedID
            : PersonalityCatalog.defaultCharacterID
    }

    func choice(for requestedID: String?) -> PersonalityChoice {
        let id = resolvedID(requestedID)
        guard let custom = customProfiles.first(where: { $0.id == id }), let prompt = custom.prompt else {
            return PersonalityCatalog.rockyChoice
        }
        return PersonalityChoice(
            id: custom.id,
            name: custom.name,
            summary: "",
            customPrompt: prompt,
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
        guard profile.isGenerated else { return }
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
