import XCTest

@testable import Rocky

/// `parseDetection` is the one piece of `PersonVision` that runs with no network or camera --
/// everything about turning Claude's reply into a `PersonDetection` lives here, where it can be
/// tested without a device.
final class PersonVisionTests: XCTestCase {
    func testParsesAPersonWithABearing() {
        let detection = PersonVision.parseDetection(
            #"{"person_present": true, "bearing": -0.4, "description": "person, facing camera"}"#
        )

        XCTAssertTrue(detection.personPresent)
        XCTAssertEqual(detection.bearing, -0.4)
        XCTAssertEqual(detection.description, "person, facing camera")
    }

    func testNoPersonIgnoresAnyOtherFields() {
        let detection = PersonVision.parseDetection(
            #"{"person_present": false, "bearing": 0.2, "description": "empty room"}"#
        )

        XCTAssertFalse(detection.personPresent)
        XCTAssertNil(detection.bearing)
        XCTAssertNil(detection.description)
    }

    func testToleratesJSONWrappedInProse() {
        let detection = PersonVision.parseDetection(
            #"Sure thing! {"person_present": true, "bearing": 0.9, "description": null} hope that helps"#
        )

        XCTAssertTrue(detection.personPresent)
        XCTAssertEqual(detection.bearing, 0.9)
        XCTAssertNil(detection.description)
    }

    func testClampsAnOutOfRangeBearing() {
        let detection = PersonVision.parseDetection(#"{"person_present": true, "bearing": 4.2}"#)

        XCTAssertEqual(detection.bearing, 1)
    }

    func testUnparseableTextReadsAsNoPerson() {
        XCTAssertEqual(PersonVision.parseDetection("not json at all"), .none)
        XCTAssertEqual(PersonVision.parseDetection(""), .none)
        XCTAssertEqual(PersonVision.parseDetection("{not valid json}"), .none)
    }

    func testMissingPersonPresentDefaultsToFalse() {
        let detection = PersonVision.parseDetection(#"{"bearing": 0.1}"#)

        XCTAssertEqual(detection, .none)
    }
}
