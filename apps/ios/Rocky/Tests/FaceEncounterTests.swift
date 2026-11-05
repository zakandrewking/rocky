import XCTest
@testable import Rocky

final class FaceEncounterTests: XCTestCase {
    private func vector(_ angle: Float = 0) -> FaceFeaturePrintDescriptor {
        var values = [Float](repeating: 0, count: 512)
        values[0] = cos(angle); values[1] = sin(angle)
        return .init(algorithm: AuraFaceProbe.algorithm, revision: 1, values: values,
                     preprocessing: AuraFaceProbe.preprocessing)
    }

    func testEnrollmentRequiresThreeFreshContinuousFramesTokenAndExplicitConsent() throws {
        var encounter = FaceEncounter()
        let now = Date()
        XCTAssertNil(encounter.observe(vector(), at: now))
        XCTAssertNil(encounter.observe(vector(0.1), at: now.addingTimeInterval(1)))
        let token = try XCTUnwrap(encounter.observe(vector(0.2), at: now.addingTimeInterval(2))).uuidString
        let at = now.addingTimeInterval(2.5)
        XCTAssertThrowsError(try encounter.referenceForEnrollment(token: token, consent: false, at: at))
        XCTAssertThrowsError(try encounter.referenceForEnrollment(token: UUID().uuidString, consent: true, at: at))
        XCTAssertThrowsError(try encounter.referenceForEnrollment(token: token, consent: true, at: now.addingTimeInterval(5)))
        XCTAssertEqual(try encounter.referenceForEnrollment(token: token, consent: true, at: at), vector())
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
            XCTAssertThrowsError(try encounter.referenceForEnrollment(token: token, consent: true,
                                                                       at: now.addingTimeInterval(6)))
        }
    }

    func testContextAllowsIntroductionsOnlyForStableUnfamiliarFaces() {
        let id = UUID()
        let context = FaceConversation.context(.init(kind: .unfamiliar, encounterID: id), sequence: 1)
        XCTAssertTrue(context.contains(id.uuidString))
        XCTAssertTrue(context.contains("A name alone is not permission"))
        XCTAssertTrue(context.contains("remember_visible_friend"))
        let uncertain = FaceConversation.context(.init(kind: .unknown), sequence: 2)
        XCTAssertFalse(uncertain.contains(id.uuidString))
        XCTAssertFalse(uncertain.contains("One stable unfamiliar face is visible"))
    }
}
