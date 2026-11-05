import XCTest
@testable import Rocky

final class LiveFaceRecognitionTests: XCTestCase {
    private func vector(_ first: Float = 0, revision: Int = 2) -> FaceFeaturePrintDescriptor {
        var values = [Float](repeating: 0, count: 768)
        values[0] = first
        return .init(revision: revision, values: values)
    }

    @MainActor
    func testVaultRoundTripAtomicRejectionAndDeletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("vault.json")
        let store = FriendStore(url: url)
        try store.remember(name: "Zak", descriptor: vector())
        try store.remember(name: "Zak", descriptor: vector(0.1))
        XCTAssertEqual(store.vault.friends.count, 1)
        XCTAssertEqual(store.vault.friends.first?.templates.count, 2)
        let bytes = try Data(contentsOf: url)
        XCTAssertThrowsError(try store.remember(name: "<instruction>", descriptor: vector()))
        XCTAssertThrowsError(try store.remember(name: "Other", descriptor: vector(revision: 1)))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let reloaded = FriendStore(url: url)
        XCTAssertEqual(reloaded.vault, store.vault)
        try reloaded.forget(try XCTUnwrap(reloaded.vault.friends.first?.id))
        XCTAssertTrue(FriendStore(url: url).vault.friends.isEmpty)
    }

    @MainActor
    func testCorruptVaultIsNotOverwrittenByEnrollment() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("vault.json")
        let broken = Data("corrupted".utf8)
        try broken.write(to: url)
        let store = FriendStore(url: url)
        XCTAssertNotNil(store.error)
        XCTAssertThrowsError(try store.remember(name: "Zak", descriptor: vector()))
        XCTAssertEqual(try Data(contentsOf: url), broken)
        try store.clear()
        XCTAssertNil(store.error)
        XCTAssertTrue(FriendStore(url: url).vault.friends.isEmpty)
    }

    func testEncryptedBackupRoundTripWrongPasswordAndTampering() throws {
        let vault = FriendVault(friends: [FriendProfile(name: "Zak", templates: [vector()])])
        let encrypted = try FriendBackup.seal(vault, password: "test-only-password")
        XCTAssertEqual(try FriendBackup.open(encrypted, password: "test-only-password"), vault)
        XCTAssertThrowsError(try FriendBackup.open(encrypted, password: "wrong-password"))
        var changed = encrypted
        changed[changed.count / 2] ^= 1
        XCTAssertThrowsError(try FriendBackup.open(changed, password: "test-only-password"))
        let second = try FriendBackup.seal(vault, password: "test-only-password")
        XCTAssertNotEqual(encrypted, second)
    }

    func testOpenSetMatchRequiresAbsoluteThresholdAndPersonMargin() {
        let zak = FriendProfile(name: "Zak", templates: [vector(0), vector(0.01)])
        let other = FriendProfile(name: "Other", templates: [vector(0.8)])
        XCTAssertEqual(FaceMatcher.match(vector(0.1), friends: [zak, other])?.id, zak.id)
        XCTAssertNil(FaceMatcher.match(vector(0.45), friends: [zak, other]))
        let lookalike = FriendProfile(name: "Similar", templates: [vector(0.05)])
        XCTAssertNil(FaceMatcher.match(vector(0.02), friends: [zak, lookalike]))
        XCTAssertNil(FaceMatcher.match(vector(revision: 1), friends: [zak]))
        XCTAssertEqual(FaceMatcher.assess(vector(0.45), friends: [zak, other]).reason, "outside match threshold")
        XCTAssertEqual(FaceMatcher.assess(vector(0.02), friends: [zak, lookalike]).reason, "ambiguous match")
        XCTAssertEqual(FaceMatcher.assess(vector(revision: 1), friends: [zak]).reason, "incompatible templates")
        XCTAssertEqual(FaceMatcher.assess(vector(0.1), friends: [zak]).reason, "candidate match")
    }

    func testConsensusRejectsSingleFramesSwitchesAndLongGaps() {
        var consensus = FaceConsensus()
        let a = UUID(), b = UUID(), now = Date()
        XCTAssertFalse(consensus.observe(a, at: now))
        XCTAssertFalse(consensus.observe(a, at: now.addingTimeInterval(1)))
        XCTAssertTrue(consensus.observe(a, at: now.addingTimeInterval(2)))
        XCTAssertFalse(consensus.observe(a, at: now.addingTimeInterval(1.5)))
        XCTAssertFalse(consensus.observe(b, at: now.addingTimeInterval(3)))
        XCTAssertFalse(consensus.observe(nil, at: now.addingTimeInterval(4)))
        XCTAssertFalse(consensus.observe(a, at: now.addingTimeInterval(5)))
        XCTAssertFalse(consensus.observe(a, at: now.addingTimeInterval(10)))
    }

    func testArrivalsDoNotInterruptOrRepeatAfterCameraBlips() {
        var policy = FaceArrivalPolicy()
        let a = FacePresence(kind: .recognized, friendID: UUID(), name: "Zak")
        let b = FacePresence(kind: .recognized, friendID: UUID(), name: "Other")
        let now = Date()
        XCTAssertFalse(policy.observe(a, at: now, conversationAge: 5, quiet: true))
        XCTAssertFalse(policy.observe(a, at: now.addingTimeInterval(20), conversationAge: 25, quiet: true))
        XCTAssertFalse(policy.observe(.init(kind: .unknown), at: now.addingTimeInterval(21), conversationAge: 26, quiet: true))
        XCTAssertFalse(policy.observe(a, at: now.addingTimeInterval(24), conversationAge: 29, quiet: true))
        XCTAssertFalse(policy.observe(b, at: now.addingTimeInterval(25), conversationAge: 30, quiet: false))
        XCTAssertFalse(policy.observe(b, at: now.addingTimeInterval(30), conversationAge: 35, quiet: true))
        _ = policy.observe(.init(kind: .nobody), at: now.addingTimeInterval(60), conversationAge: 65, quiet: true)
        XCTAssertTrue(policy.observe(a, at: now.addingTimeInterval(70), conversationAge: 75, quiet: true))
    }

    func testConversationContextDoesNotCarryAnOldNameIntoUncertainty() throws {
        let known = FaceConversation.context(.init(kind: .recognized, friendID: UUID(), name: "Zak"), sequence: 1)
        XCTAssertTrue(known.contains("Zak"))
        let uncertain = FaceConversation.context(.init(kind: .multiple), sequence: 2)
        XCTAssertFalse(uncertain.contains("Zak"))
        XCTAssertTrue(uncertain.contains("speaker"))
        let event = ConversationItemCreateEvent(id: "face_test", text: uncertain, role: "system")
        let data = try JSONEncoder().encode(event)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let item = try XCTUnwrap(json["item"] as? [String: Any])
        XCTAssertEqual(item["role"] as? String, "system")
    }
}
