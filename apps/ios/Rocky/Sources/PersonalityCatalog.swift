import Foundation

/// The small, UI-facing slice of a character. The actual prompt, tools, model, and voice remain
/// generated from services/device-api/src/characters and are never duplicated in Swift.
struct PersonalityProfile: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let summary: String
}

enum PersonalityCatalog {
    static let selectionKey = "selectedCharacterID"

    private struct BakedCatalog: Decodable {
        let defaultCharacterID: String
        let characters: [PersonalityProfile]

        enum CodingKeys: String, CodingKey {
            case defaultCharacterID = "default_character_id"
            case characters
        }
    }

    private static let baked: BakedCatalog? = {
        guard let url = Bundle.main.url(forResource: "RealtimeSessionConfig", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(BakedCatalog.self, from: data)
    }()

    static let profiles: [PersonalityProfile] = baked?.characters ?? []
    static let defaultCharacterID = baked?.defaultCharacterID ?? "rocky"

    static func resolvedID(_ requestedID: String?) -> String {
        guard let requestedID, profiles.contains(where: { $0.id == requestedID }) else {
            return profiles.first(where: { $0.id == defaultCharacterID })?.id
                ?? profiles.first?.id
                ?? defaultCharacterID
        }
        return requestedID
    }

    static func profile(for requestedID: String?) -> PersonalityProfile? {
        let id = resolvedID(requestedID)
        return profiles.first { $0.id == id }
    }
}
