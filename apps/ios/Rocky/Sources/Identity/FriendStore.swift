import Foundation
import CryptoKit
import CommonCrypto
import Security

struct FriendProfile: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var templates: [FaceFeaturePrintDescriptor]
}

struct FriendVault: Codable, Equatable, Sendable {
    var version = 1
    var preprocessing = FaceProbeCapture.preprocessing
    var osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    var friends: [FriendProfile] = []

    func validate() throws {
        guard version == 1,
              [FaceProbeCapture.preprocessing, FaceProbeCapture.legacyPreprocessing].contains(preprocessing),
              osMajor == ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
              friends.count <= 20, Set(friends.map(\.id)).count == friends.count,
              Set(friends.map { $0.name.lowercased() }).count == friends.count else {
            throw FriendStoreError.incompatible
        }
        for friend in friends {
            guard FriendStore.cleanName(friend.name) == friend.name,
                  !friend.name.isEmpty, !friend.templates.isEmpty, friend.templates.count <= 5,
                  friend.templates.allSatisfy({
                      $0.algorithm == FaceFeaturePrintDescriptor.algorithm && $0.revision == 2
                          && $0.values.count == 768 && $0.values.allSatisfy(\.isFinite)
                          && ($0.preprocessing == nil || $0.preprocessing == FaceProbeCapture.preprocessing)
                  }) else { throw FriendStoreError.incompatible }
        }
    }
}

enum FriendStoreError: LocalizedError {
    case incompatible, invalidName, capacity, backup
    var errorDescription: String? {
        switch self {
        case .incompatible: "This friend file is corrupt or uses a different face model or iOS version. Your current friends were left unchanged."
        case .invalidName: "Use a short name with letters, spaces, apostrophes or hyphens."
        case .capacity: "MVP limit: 20 friends and 5 face samples per friend. Forget a friend before enrolling them again."
        case .backup: "Couldn’t open this backup. Check the password and file."
        }
    }
}

/// Disk writes commit before published state changes. A load error never silently overwrites the
/// original vault. No raw media can be represented in this schema.
@MainActor
final class FriendStore: ObservableObject {
    @Published private(set) var vault = FriendVault()
    @Published private(set) var error: String?
    private let url: URL
    private var loadFailed = false

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Friends/vault.json")
        do {
            if FileManager.default.fileExists(atPath: self.url.path) {
                let size = try self.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 2_000_000 else { throw FriendStoreError.incompatible }
                let loaded = try JSONDecoder().decode(FriendVault.self, from: Data(contentsOf: self.url))
                try loaded.validate()
                vault = loaded
            }
        } catch {
            loadFailed = true
            self.error = "Saved friends could not be loaded. Restore a compatible backup or explicitly clear the vault."
        }
    }

    nonisolated static func cleanName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { $0.isLetter || $0 == " " || $0 == "'" || $0 == "-" }
            .prefix(40).description
    }

    func remember(name: String, descriptor: FaceFeaturePrintDescriptor) throws {
        guard !loadFailed else { throw FriendStoreError.incompatible }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, Self.cleanName(name) == name else { throw FriendStoreError.invalidName }
        var next = vault
        if let index = next.friends.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            // An explicit new capture refreshes only this friend's obsolete templates. Preserve
            // their name/ID and every other friend; never silently compare across pipelines.
            next.friends[index].templates.removeAll { $0.preprocessing != descriptor.preprocessing }
            guard next.friends[index].templates.count < 5 else { throw FriendStoreError.capacity }
            next.friends[index].templates.append(descriptor)
        } else {
            guard next.friends.count < 20 else { throw FriendStoreError.capacity }
            next.friends.append(FriendProfile(name: name, templates: [descriptor]))
        }
        next.preprocessing = FaceProbeCapture.preprocessing
        try commit(next)
    }

    func forget(_ id: UUID) throws {
        guard !loadFailed else { throw FriendStoreError.incompatible }
        var next = vault
        next.friends.removeAll { $0.id == id }
        try commit(next)
    }

    func clear() throws { try commit(FriendVault()) }

    func restore(_ restored: FriendVault) throws { try commit(restored) }

    private func commit(_ next: FriendVault) throws {
        try next.validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                               withIntermediateDirectories: true,
                                               attributes: [.protectionKey: FileProtectionType.complete])
        try JSONEncoder().encode(next).write(to: url, options: [.atomic, .completeFileProtection])
        vault = next
        loadFailed = false
        error = nil
    }
}

/// Portable backup: PBKDF2-HMAC-SHA256 (200k rounds, random 128-bit salt) + AES-GCM.
/// The key/password is not stored. Work runs off the main actor; wrong passwords never mutate disk.
enum FriendBackup {
    private struct Envelope: Codable {
        var version = 1
        let salt: Data
        let sealed: Data
    }
    static func seal(_ vault: FriendVault, password: String) throws -> Data {
        try vault.validate()
        guard password.count >= 10 else { throw FriendStoreError.backup }
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw FriendStoreError.backup }
        let encrypted = try AES.GCM.seal(JSONEncoder().encode(vault), using: key(password, salt))
        return try JSONEncoder().encode(Envelope(salt: salt, sealed: encrypted.combined!))
    }
    static func open(_ data: Data, password: String) throws -> FriendVault {
        do {
            guard data.count <= 2_000_000 else { throw FriendStoreError.backup }
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.version == 1, envelope.salt.count == 16 else { throw FriendStoreError.backup }
            let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealed),
                                         using: key(password, envelope.salt))
            let vault = try JSONDecoder().decode(FriendVault.self, from: bytes)
            try vault.validate()
            return vault
        } catch FriendStoreError.incompatible { throw FriendStoreError.incompatible }
        catch { throw FriendStoreError.backup }
    }
    private static func key(_ password: String, _ salt: Data) throws -> SymmetricKey {
        let passwordBytes = Array(password.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = passwordBytes.withUnsafeBytes { pass in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                    pass.baseAddress?.assumingMemoryBound(to: Int8.self), pass.count,
                    saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 200_000, &derived, 32)
            }
        }
        guard status == kCCSuccess else { throw FriendStoreError.backup }
        return SymmetricKey(data: derived)
    }
}
