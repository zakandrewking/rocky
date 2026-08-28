import XCTest

@testable import Rocky

/// When a look is worth telling Rocky about.
///
/// The passive `<vision>` stream used to fire on two things only: the person-present edge, and a
/// refresh timer. That missed the case that actually came up live -- a friend stayed in view the
/// whole time and held something up, so presence never flipped and the timer had not come round.
/// Nothing was ever said, and Rocky answered as if the object were not there.
///
/// The catch is that Gemini rephrases itself every single frame, so "did the scene change" cannot
/// be a string comparison without turning the conversation into a stream of near-identical
/// descriptions. This is that judgment, and it is a pure function so it can be pinned down here
/// rather than tuned by feel against a live camera.
final class VisionContextTests: XCTestCase {
    func testAnOlderCaptureCannotBecomeCurrentByFinishingLater() {
        let now = Date()
        let newer = VisionSample(
            seq: 8, capturedAt: now, judgedAt: now, reading: .empty
        )
        let older = VisionSample(
            seq: 7,
            capturedAt: now.addingTimeInterval(-1),
            judgedAt: now.addingTimeInterval(1),
            reading: .empty
        )

        XCTAssertFalse(RealtimeVoiceSession.isNewerVision(older, than: newer))
        XCTAssertTrue(RealtimeVoiceSession.isNewerVision(newer, than: older))
    }

    func testContextCarriesSequenceAndMeasuredAge() {
        let captured = Date(timeIntervalSince1970: 1_000)
        let sample = VisionSample(
            seq: 42,
            capturedAt: captured,
            judgedAt: captured.addingTimeInterval(0.8),
            reading: SceneReading(
                personPresent: true,
                bearing: 0,
                person: "a friend",
                scene: "a friend holding a blue cup"
            )
        )

        XCTAssertEqual(
            RealtimeVoiceSession.visionContext(
                for: sample,
                presenceChanged: false,
                sceneChanged: true,
                at: captured.addingTimeInterval(1.25)
            ),
            "<vision seq=\"42\" age_ms=\"1250\">What you can see has just changed: a friend holding a blue cup.</vision>"
        )
    }

    func testHoldingSomethingUpCountsAsAChange() {
        XCTAssertTrue(
            RealtimeVoiceSession.sceneChanged(
                from: "a man at a desk, facing the camera",
                to: "a man holding a can of coconut water up to the camera"
            )
        )
    }

    func testRewordingTheSameSceneDoesNot() {
        XCTAssertFalse(
            RealtimeVoiceSession.sceneChanged(
                from: "a man, facing camera, smiling",
                to: "a man facing the camera and smiling"
            )
        )
        XCTAssertFalse(
            RealtimeVoiceSession.sceneChanged(
                from: "man at a desk with a laptop",
                to: "a man seated at his desk with a laptop"
            )
        )
        XCTAssertFalse(
            RealtimeVoiceSession.sceneChanged(
                from: "a person at a desk showing a blue mug",
                to: "a person seated in the room holding a blue cup"
            )
        )
    }

    func testAChangedColorCountsEvenWhenEveryOtherWordMatches() {
        XCTAssertTrue(
            RealtimeVoiceSession.sceneChanged(
                from: "a person holding a red cup at a kitchen table",
                to: "a person holding a blue cup at a kitchen table"
            )
        )
    }

    func testPuttingAwayTheShownObjectCountsAsAChange() {
        XCTAssertTrue(
            RealtimeVoiceSession.sceneChanged(
                from: "a person holding a can of coconut water at a desk",
                to: "a person sitting at a desk"
            )
        )
    }

    func testTheFirstSceneIsAlwaysWorthTelling() {
        XCTAssertTrue(RealtimeVoiceSession.sceneChanged(from: nil, to: "a man in a kitchen"))
        XCTAssertTrue(RealtimeVoiceSession.sceneChanged(from: "", to: "a man in a kitchen"))
    }

    /// A frame the model said nothing about is not evidence the scene changed -- it is no
    /// evidence at all, and announcing "" would be worse than staying quiet.
    func testNothingDescribedIsNotAChange() {
        XCTAssertFalse(RealtimeVoiceSession.sceneChanged(from: "a man in a kitchen", to: nil))
        XCTAssertFalse(RealtimeVoiceSession.sceneChanged(from: "a man in a kitchen", to: ""))
    }

    /// The generic tool follow-up is built to keep movement silent, down to "produce no additional
    /// words". Sending a look through it would suppress the answer the friend just asked for, so a
    /// turn that looked gets its own follow-up -- even when it also moved.
    func testLookingEarnsAFollowupThatActuallySpeaks() {
        XCTAssertEqual(
            RealtimeVoiceSession.followupPrompt(after: ["look_now"]),
            RealtimeVoiceSession.lookFollowupPrompt
        )
        XCTAssertEqual(
            RealtimeVoiceSession.followupPrompt(after: ["robot_gesture", "look_now"]),
            RealtimeVoiceSession.lookFollowupPrompt
        )
        XCTAssertEqual(
            RealtimeVoiceSession.followupPrompt(after: ["robot_gesture"]),
            RealtimeVoiceSession.toolFollowupPrompt
        )
    }

    func testAWhollyDifferentRoomIsAChange() {
        XCTAssertTrue(
            RealtimeVoiceSession.sceneChanged(
                from: "a man in a kitchen holding a mug",
                to: "an empty hallway with a bicycle against the wall"
            )
        )
    }

    /// A person leaving is caught by the presence edge, but what is left behind still has to read
    /// as different from what was there before.
    func testSomeoneLeavingChangesTheScene() {
        XCTAssertTrue(
            RealtimeVoiceSession.sceneChanged(
                from: "a woman holding a drawing up to the camera",
                to: "an empty room, a chair and a window"
            )
        )
    }
}
