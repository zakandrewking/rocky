import XCTest

@testable import Rocky

final class RobotPerformanceTests: XCTestCase {
    func testDecodesTextAndMovementInExactPlaybackOrder() throws {
        let steps = try RobotPerformance.decode(
            """
            {"steps":[
              {"kind":"say","text":"A small door opened.","move":"none","sound":"none"},
              {"kind":"move","text":"","move":"wiggle","sound":"none"},
              {"kind":"say","text":"A pocket wind escaped.","move":"none","sound":"none"},
              {"kind":"sound","text":"","move":"none","sound":"spaceship_flyby"},
              {"kind":"move","text":"","move":"spin","sound":"none"},
              {"kind":"say","text":"We followed it home.","move":"none","sound":"none"}
            ]}
            """
        )

        XCTAssertEqual(
            steps,
            [
                .say("A small door opened."), .move("wiggle"),
                .say("A pocket wind escaped."), .sound("spaceship_flyby"), .move("spin"),
                .say("We followed it home."),
            ]
        )
    }

    func testRejectsAdjacentMovesThatWouldOverwriteEachOther() {
        XCTAssertThrowsError(
            try RobotPerformance.decode(
                """
                {"steps":[
                  {"kind":"say","text":"First.","move":"none","sound":"none"},
                  {"kind":"move","text":"","move":"wiggle","sound":"none"},
                  {"kind":"move","text":"","move":"spin","sound":"none"},
                  {"kind":"say","text":"Last.","move":"none","sound":"none"},
                  {"kind":"move","text":"","move":"wiggle","sound":"none"}
                ]}
                """
            )
        )
    }

    func testRejectsStageDirectionsInsideMoveSteps() {
        XCTAssertThrowsError(
            try RobotPerformance.decode(
                """
                {"steps":[
                  {"kind":"say","text":"First.","move":"none","sound":"none"},
                  {"kind":"move","text":"spin now","move":"spin","sound":"none"},
                  {"kind":"say","text":"Middle.","move":"none","sound":"none"},
                  {"kind":"move","text":"","move":"wiggle","sound":"none"},
                  {"kind":"say","text":"Last.","move":"none","sound":"none"}
                ]}
                """
            )
        )
    }

    func testAnInterruptedCueReplaysButACompletedCueDoesNot() {
        XCTAssertEqual(RobotPerformance.resumeIndex(nextIndex: 6, currentStepIndex: 5), 5)
        XCTAssertEqual(RobotPerformance.resumeIndex(nextIndex: 6, currentStepIndex: nil), 6)
    }

    func testIncludesRequestedSpaceOperaEffects() {
        XCTAssertNotNil(StorySoundEffect(rawValue: "laser_blast"))
        XCTAssertNotNil(StorySoundEffect(rawValue: "spaceship_flyby"))
    }
}
