import XCTest
@testable import Rocky

final class FaceEncounterTests: XCTestCase {
    private func vector(_ angle: Float = 0) -> FaceFeaturePrintDescriptor {
        var values = [Float](repeating: 0, count: 512)
        values[0] = cos(angle); values[1] = sin(angle)
        return .init(algorithm: AuraFaceProbe.algorithm, revision: 1, values: values,
                     preprocessing: AuraFaceProbe.preprocessing)
    }

    func testEnrollmentRequiresThreeFreshContinuousFramesAndCurrentToken() throws {
        var encounter = FaceEncounter()
        let now = Date()
        XCTAssertNil(encounter.observe(vector(), at: now))
        let incompleteToken = try XCTUnwrap(encounter.id).uuidString
        XCTAssertThrowsError(try encounter.referenceForEnrollment(token: incompleteToken, at: now))
        XCTAssertNil(encounter.observe(vector(0.1), at: now.addingTimeInterval(1)))
        let token = try XCTUnwrap(encounter.observe(vector(0.2), at: now.addingTimeInterval(2))).uuidString
        let at = now.addingTimeInterval(2.5)
        XCTAssertThrowsError(try encounter.referenceForEnrollment(token: UUID().uuidString, at: at))
        XCTAssertThrowsError(try encounter.referenceForEnrollment(token: token, at: now.addingTimeInterval(5)))
        XCTAssertEqual(try encounter.referenceForEnrollment(token: token, at: at), vector())
    }

    func testFaceSwitchGroupGapAndResetRevokeOldEncounter() throws {
        for reason in ["switch", "group", "gap", "reset"] {
            var encounter = FaceEncounter()
            let now = Date()
            _ = encounter.observe(vector(), at: now)
            _ = encounter.observe(vector(), at: now.addingTimeInterval(1))
            let token = try XCTUnwrap(encounter.observe(vector(), at: now.addingTimeInterval(2))).uuidString
            switch reason {
            case "switch": _ = encounter.observe(vector(2), at: now.addingTimeInterval(3))
            case "group": _ = encounter.observe(nil, at: now.addingTimeInterval(3))
            case "gap": _ = encounter.observe(vector(), at: now.addingTimeInterval(6))
            default: encounter.reset()
            }
            XCTAssertThrowsError(try encounter.referenceForEnrollment(token: token,
                                                                       at: now.addingTimeInterval(6)))
        }
    }

    func testContextAllowsIntroductionsOnlyForStableUnfamiliarFaces() {
        let id = UUID()
        let context = FaceConversation.context(.init(kind: .unfamiliar, encounterID: id), sequence: 1)
        XCTAssertTrue(context.contains(id.uuidString))
        XCTAssertTrue(context.contains("When they introduce themselves by name"))
        XCTAssertTrue(context.contains("Do not ask a separate permission-to-remember"))
        XCTAssertTrue(context.contains("If they say not to remember them, do not save"))
        XCTAssertTrue(context.contains("remember_visible_friend"))
        let uncertain = FaceConversation.context(.init(kind: .unknown), sequence: 2)
        XCTAssertFalse(uncertain.contains(id.uuidString))
        XCTAssertFalse(uncertain.contains("One stable unfamiliar face is visible"))
    }

    func testTentativeContextCarriesQuestionIdsWithoutClaimingRecognition() {
        let friend = UUID(), encounter = UUID()
        let context = FaceConversation.context(.init(kind: .tentative, friendID: friend, name: "Zak", encounterID: encounter), sequence: 3)
        XCTAssertTrue(context.contains("NOT a confirmed identity"))
        XCTAssertTrue(context.contains(friend.uuidString))
        XCTAssertTrue(context.contains(encounter.uuidString))
        XCTAssertTrue(context.contains("resolve_visible_friend"))
        XCTAssertTrue(context.contains("a no leaves that friend's samples untouched"))
        XCTAssertFalse(context.contains("I recognize one visible saved friend"))
    }

    func testQualityDipPreservesOnlyShortContinuityNotEnrollmentReadiness() throws {
        var encounter = FaceEncounter()
        let now = Date()
        for i in 0..<3 { _ = encounter.observe(vector(), at: now.addingTimeInterval(Double(i))) }
        let token = try XCTUnwrap(encounter.id).uuidString
        encounter.suspendForQuality(at: now.addingTimeInterval(3))
        XCTAssertEqual(encounter.currentID(at: now.addingTimeInterval(3))?.uuidString, token)
        XCTAssertThrowsError(try encounter.referenceForEnrollment(token: token, at: now.addingTimeInterval(3)))
        XCTAssertNil(encounter.observe(vector(), at: now.addingTimeInterval(3.1)))
        XCTAssertNil(encounter.observe(vector(), at: now.addingTimeInterval(3.2)))
        XCTAssertEqual(encounter.observe(vector(), at: now.addingTimeInterval(3.3))?.uuidString, token)
        encounter.suspendForQuality(at: now.addingTimeInterval(6))
        XCTAssertNil(encounter.id)
    }

    func testUncertainEnrollmentContextReportsNameWithoutClaimingIdentityOrSave() {
        let id = UUID()
        let context = FaceConversation.context(.init(kind: .unknown, encounterID: id), sequence: 1)
        XCTAssertTrue(context.contains(id.uuidString))
        XCTAssertTrue(context.contains("single-face enrollment candidate"))
        XCTAssertTrue(context.contains("Do not merely acknowledge a self-introduction and skip the tool"))
        XCTAssertTrue(context.contains("pending=true is NOT saved"))
        XCTAssertFalse(context.contains("I recognize one visible saved friend"))
    }
}
