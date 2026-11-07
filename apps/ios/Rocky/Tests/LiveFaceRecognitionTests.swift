import XCTest
@testable import Rocky

final class LiveFaceRecognitionTests: XCTestCase {
    private func vector(_ angle: Float = 0, revision: Int = 1) -> FaceFeaturePrintDescriptor {
        var values = [Float](repeating: 0, count: 512)
        values[0] = cos(angle); values[1] = sin(angle)
        return .init(algorithm: AuraFaceProbe.algorithm, revision: revision, values: values,
                     preprocessing: AuraFaceProbe.preprocessing)
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
        XCTAssertThrowsError(try store.remember(name: "Other", descriptor: vector(revision: 2)))
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
        let other = FriendProfile(name: "Other", templates: [vector(2)])
        XCTAssertEqual(FaceMatcher.match(vector(0.1), friends: [zak, other])?.id, zak.id)
        XCTAssertNil(FaceMatcher.match(vector(1), friends: [zak, other]))
        let lookalike = FriendProfile(name: "Similar", templates: [vector(0.05)])
        XCTAssertNil(FaceMatcher.match(vector(0.02), friends: [zak, lookalike]))
        XCTAssertNil(FaceMatcher.match(vector(revision: 2), friends: [zak]))
        XCTAssertEqual(FaceMatcher.assess(vector(1), friends: [zak, other]).reason, "ambiguous match")
        XCTAssertEqual(FaceMatcher.assess(vector(0.02), friends: [zak, lookalike]).reason, "ambiguous match")
        XCTAssertEqual(FaceMatcher.assess(vector(revision: 2), friends: [zak]).reason, "incompatible templates")
        XCTAssertEqual(FaceMatcher.assess(vector(0.1), friends: [zak]).reason, "candidate match")
        XCTAssertEqual(FaceMatcher.assess(vector(0.45), friends: [zak]).nearestDistance ?? -1,
                       2 * sin(0.44 / 2), accuracy: 0.000_001)
        XCTAssertNil(FaceMatcher.assess(vector(revision: 2), friends: [zak]).nearestDistance)
    }

    @MainActor
    func testLegacyTemplatesRequireExplicitRefreshWithoutLosingOtherFriends() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FriendStore(url: directory.appendingPathComponent("vault.json"))
        let old = FaceFeaturePrintDescriptor(revision: 2, values: Array(repeating: 0, count: 768),
                                             preprocessing: FaceProbeCapture.preprocessing)
        try store.restore(FriendVault(preprocessing: FaceProbeCapture.preprocessing,
            friends: [FriendProfile(name: "Zak", templates: [old]), FriendProfile(name: "Other", templates: [old])]))
        let previous = store.vault
        let current = vector()
        XCTAssertThrowsError(try current.distance(to: old))
        XCTAssertNil(FaceMatcher.match(current, friends: store.vault.friends))
        XCTAssertThrowsError(try store.remember(name: "Zak", descriptor: old))
        try store.remember(name: "Zak", descriptor: current)
        XCTAssertEqual(store.vault.friends.count, 2)
        XCTAssertEqual(store.vault.friends[0].id, previous.friends[0].id)
        XCTAssertEqual(store.vault.friends[0].templates, [current])
        XCTAssertEqual(store.vault.friends[1], previous.friends[1])
        XCTAssertEqual(FaceMatcher.match(current, friends: store.vault.friends)?.id, previous.friends[0].id)
        var legacy = previous
        legacy.preprocessing = FaceProbeCapture.legacyPreprocessing
        try legacy.validate()
        try store.restore(legacy)
        XCTAssertEqual(store.vault, legacy)
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

    func testTentativeBandIsNotRecognitionAndStillRequiresPersonMargin() {
        let zak = FriendProfile(name: "Zak", templates: [vector()])
        XCTAssertNotNil(FaceMatcher.assess(vector(0.8), friends: [zak]).friend)
        let maybe = FaceMatcher.assess(vector(1.1), friends: [zak])
        XCTAssertNil(maybe.friend)
        XCTAssertEqual(maybe.tentativeFriend?.id, zak.id)
        XCTAssertNil(FaceMatcher.assess(vector(1.4), friends: [zak]).tentativeFriend)
        let similar = FriendProfile(name: "Other", templates: [vector(0.03)])
        XCTAssertNil(FaceMatcher.assess(vector(1.1), friends: [zak, similar]).tentativeFriend)
        XCTAssertNil(FaceMatcher.assess(vector(revision: 2), friends: [zak]).tentativeFriend)
        XCTAssertEqual(FaceMatcher.verificationDistance, 1.2)
    }

    @MainActor
    func testConfirmedSamplesPreserveAnchorAndOtherPeopleAtCapacity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FriendStore(url: directory.appendingPathComponent("vault.json"))
        try store.remember(name: "Zak", descriptor: vector())
        try store.remember(name: "Other", descriptor: vector(2))
        let id = store.vault.friends[0].id
        let other = store.vault.friends[1]
        for angle in [Float(0.1), 0.2, 0.3, 0.4, 0.5, 0.6] {
            try store.addConfirmedSample(friendID: id, descriptor: vector(angle))
        }
        XCTAssertEqual(store.vault.friends[0].templates.count, 5)
        XCTAssertEqual(store.vault.friends[0].templates.first, vector())
        XCTAssertEqual(store.vault.friends[0].templates.last, vector(0.6))
        XCTAssertEqual(store.vault.friends[1], other)
        let before = store.vault
        XCTAssertThrowsError(try store.addConfirmedSample(friendID: UUID(), descriptor: vector()))
        XCTAssertThrowsError(try store.addConfirmedSample(friendID: id, descriptor: vector(revision: 2)))
        XCTAssertEqual(store.vault, before)
    }

    @MainActor
    func testTentativeYesLearnsAndNoEnablesNewIntroductionWithoutChangingGuessedFriend() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for confirmed in [true, false] {
            let store = FriendStore(url: directory.appendingPathComponent("\(confirmed).json"))
            try store.remember(name: "Zak", descriptor: vector())
            let original = store.vault.friends[0]
            let live = LiveFaceRecognition()
            live.configure(store.vault.friends)
            for _ in 0..<3 {
                live.accept(.success(FaceFeaturePrintMeasurement(descriptor: vector(1.1), elapsedMilliseconds: 1)), capturedAt: Date())
            }
            XCTAssertEqual(live.presence.kind, .tentative)
            let token = try XCTUnwrap(live.presence.encounterID).uuidString
            XCTAssertThrowsError(try live.resolveVisibleFriend(friendID: original.id.uuidString, encounterID: token,
                                                              confirmed: confirmed, store: store, at: Date().addingTimeInterval(3)))
            XCTAssertEqual(store.vault.friends, [original])
            XCTAssertThrowsError(try live.resolveVisibleFriend(friendID: UUID().uuidString, encounterID: token,
                                                              confirmed: confirmed, store: store))
            XCTAssertThrowsError(try live.resolveVisibleFriend(friendID: original.id.uuidString, encounterID: UUID().uuidString,
                                                              confirmed: confirmed, store: store))
            try live.resolveVisibleFriend(friendID: original.id.uuidString, encounterID: token,
                                          confirmed: confirmed, store: store)
            if confirmed {
                XCTAssertEqual(store.vault.friends[0].templates.count, 2)
                XCTAssertEqual(FaceMatcher.match(vector(1.1), friends: store.vault.friends)?.id, original.id)
            } else {
                XCTAssertEqual(store.vault.friends, [original])
                XCTAssertEqual(live.presence.kind, .unfamiliar)
                live.accept(.success(FaceFeaturePrintMeasurement(descriptor: vector(1.1), elapsedMilliseconds: 1)), capturedAt: Date())
                XCTAssertEqual(live.presence.kind, .unfamiliar)
                try live.rememberVisibleFriend(name: "Alex", encounterID: token, store: store)
                XCTAssertEqual(store.vault.friends.count, 2)
                XCTAssertEqual(store.vault.friends[0], original)
                XCTAssertEqual(store.vault.friends[1].name, "Alex")
            }
            XCTAssertThrowsError(try live.resolveVisibleFriend(friendID: original.id.uuidString, encounterID: token,
                                                              confirmed: true, store: store))
            live.reset()
        }
    }

    @MainActor
    func testFaceLossRevokesTentativeReferenceUpdate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FriendStore(url: directory.appendingPathComponent("vault.json"))
        try store.remember(name: "Zak", descriptor: vector())
        let original = store.vault
        let live = LiveFaceRecognition()
        live.configure(store.vault.friends)
        for _ in 0..<3 {
            live.accept(.success(.init(descriptor: vector(1.1), elapsedMilliseconds: 1)), capturedAt: Date())
        }
        let token = try XCTUnwrap(live.presence.encounterID).uuidString
        live.accept(.failure(FaceProbeCapture.CaptureError.noFace), capturedAt: Date())
        XCTAssertThrowsError(try live.resolveVisibleFriend(friendID: original.friends[0].id.uuidString,
                            encounterID: token, confirmed: true, store: store))
        XCTAssertEqual(store.vault, original)
        live.reset()
    }

    func testDistanceTrendsAreBoundedFiniteAndThrottled() throws {
        var trend = FaceDistanceTrend()
        let now = Date()
        XCTAssertNil(trend.record(.nan, at: now))
        XCTAssertNil(trend.record(-1, at: now))
        XCTAssertEqual(trend.record(0.4, at: now)?.count, 1)
        XCTAssertNil(trend.record(0.2, at: now.addingTimeInterval(1)))
        let summary = try XCTUnwrap(trend.record(0.3, at: now.addingTimeInterval(5)))
        XCTAssertEqual(summary.count, 2)
        XCTAssertEqual(summary.minimum, 0.2)
        XCTAssertEqual(summary.mean, 0.25)
        XCTAssertEqual(summary.maximum, 0.3)
        XCTAssertEqual(trend.record(0.1, at: now.addingTimeInterval(10))?.count, 1)
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
