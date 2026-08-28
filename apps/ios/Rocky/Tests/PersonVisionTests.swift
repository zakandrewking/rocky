import XCTest

@testable import Rocky

/// `parseReading` is the one piece of `PersonVision` that runs with no network or camera --
/// everything about turning Gemini's reply into a `SceneReading` lives here, where it can be
/// tested without a device.
final class PersonVisionTests: XCTestCase {
    func testParsesAPersonWithABearing() throws {
        let reading = try XCTUnwrap(PersonVision.parseReading(
            #"{"person_present": true, "bearing": -0.4, "person": "man, facing camera", "scene": "a man at a desk"}"#
        ))

        XCTAssertTrue(reading.personPresent)
        XCTAssertEqual(reading.bearing, -0.4)
        XCTAssertEqual(reading.person, "man, facing camera")
        XCTAssertEqual(reading.scene, "a man at a desk")
    }

    /// The live failure this whole pass came from: a friend held a drink up and asked about it,
    /// and the answer had nothing in it about a drink. The object has to survive parsing, which it
    /// could not when the model was only ever asked whether a person was present.
    func testKeepsWhatSomeoneIsHolding() throws {
        let reading = try XCTUnwrap(PersonVision.parseReading(
            #"{"person_present": true, "bearing": 0.1, "person": "man, facing camera", "scene": "a man holding a can of coconut water"}"#
        ))

        XCTAssertEqual(reading.scene, "a man holding a can of coconut water")
    }

    /// An empty room and an empty room with a drawing held up in it are different facts, so the
    /// scene outlives a false `person_present` even though the person-only fields do not.
    func testAnEmptyRoomStillDescribesWhatIsInIt() throws {
        let reading = try XCTUnwrap(PersonVision.parseReading(
            #"{"person_present": false, "bearing": 0.2, "person": "nobody", "scene": "an empty kitchen, a drawing taped to the fridge"}"#
        ))

        XCTAssertFalse(reading.personPresent)
        XCTAssertNil(reading.bearing)
        XCTAssertNil(reading.person)
        XCTAssertEqual(reading.scene, "an empty kitchen, a drawing taped to the fridge")
    }

    /// "description" is what the earlier person-only prompt asked for. A reply still in that shape
    /// should degrade to the old behaviour rather than to silence.
    func testStillUnderstandsTheOlderReplyShape() throws {
        let reading = try XCTUnwrap(PersonVision.parseReading(
            #"{"person_present": true, "bearing": 0.3, "description": "person, facing camera"}"#
        ))

        XCTAssertEqual(reading.person, "person, facing camera")
        XCTAssertNil(reading.scene)
    }

    func testToleratesJSONWrappedInProse() throws {
        let reading = try XCTUnwrap(PersonVision.parseReading(
            #"Sure thing! {"person_present": true, "bearing": 0.9, "scene": "a hallway"} hope that helps"#
        ))

        XCTAssertTrue(reading.personPresent)
        XCTAssertEqual(reading.bearing, 0.9)
        XCTAssertEqual(reading.scene, "a hallway")
    }

    /// Confirmed against the real API (2026-08-21): despite the system prompt asking for "exactly
    /// one line of JSON and nothing else," Gemini wraps its reply in a markdown code fence anyway.
    func testToleratesAMarkdownCodeFence() throws {
        let reading = try XCTUnwrap(PersonVision.parseReading(
            "```json\n{\"person_present\": false, \"bearing\": null, \"person\": null, \"scene\": null}\n```"
        ))

        XCTAssertEqual(reading, .empty)
    }

    func testClampsAnOutOfRangeBearing() throws {
        let reading = try XCTUnwrap(PersonVision.parseReading(#"{"person_present": true, "bearing": 4.2}"#))

        XCTAssertEqual(reading.bearing, 1)
    }

    func testBlankPhrasesReadAsNothingSaid() throws {
        let reading = try XCTUnwrap(PersonVision.parseReading(
            #"{"person_present": true, "bearing": 0, "person": "  ", "scene": ""}"#
        ))

        XCTAssertNil(reading.person)
        XCTAssertNil(reading.scene)
    }

    func testUnparseableTextIsNotAnEmptyRoomObservation() {
        XCTAssertNil(PersonVision.parseReading("not json at all"))
        XCTAssertNil(PersonVision.parseReading(""))
        XCTAssertNil(PersonVision.parseReading("{not valid json}"))
    }

    func testMissingPersonPresentIsNotEvidenceOfAbsence() {
        XCTAssertNil(PersonVision.parseReading(#"{"bearing": 0.1}"#))
    }

    /// Freshness is measured from when the light hit the lens, not when the judgment came back --
    /// `look_now` compares that against the moment a friend asked, and a round trip is long enough
    /// for the difference to decide the answer.
    func testASampleAgesFromWhenItWasCaptured() {
        let captured = Date()
        let sample = VisionSample(
            seq: 1,
            capturedAt: captured,
            judgedAt: captured.addingTimeInterval(1.4),
            reading: .empty
        )

        XCTAssertEqual(sample.latency, 1.4, accuracy: 0.001)
        XCTAssertEqual(sample.age(at: captured.addingTimeInterval(3)), 3, accuracy: 0.001)
    }
}
