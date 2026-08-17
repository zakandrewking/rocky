import XCTest

@testable import Rocky

final class RobotPerformanceTests: XCTestCase {
    func testDecodesTextAndMovementInExactPlaybackOrder() throws {
        let steps = try RobotPerformance.decode(
            """
            {"steps":[
              {"kind":"say","text":"A small door opened.","move":"none","sound":"none","duration_ms":0},
              {"kind":"move","text":"","move":"wiggle","sound":"none","duration_ms":0},
              {"kind":"pause","text":"","move":"none","sound":"none","duration_ms":600},
              {"kind":"say","text":"A pocket wind escaped.","move":"none","sound":"none","duration_ms":0},
              {"kind":"sound","text":"","move":"none","sound":"spaceship_flyby","duration_ms":0},
              {"kind":"move","text":"","move":"turn_left","sound":"none","duration_ms":0},
              {"kind":"pause","text":"","move":"none","sound":"none","duration_ms":1200},
              {"kind":"say","text":"We followed it home.","move":"none","sound":"none","duration_ms":0}
            ]}
            """
        )

        XCTAssertEqual(
            steps,
            [
                .say("A small door opened."), .move("wiggle"), .pause(600),
                .say("A pocket wind escaped."), .sound("spaceship_flyby"), .move("turn_left"),
                .pause(1200),
                .say("We followed it home."),
            ]
        )
    }

    func testRejectsAdjacentMovesThatWouldOverwriteEachOther() {
        XCTAssertThrowsError(
            try RobotPerformance.decode(
                """
                {"steps":[
                  {"kind":"say","text":"First.","move":"none","sound":"none","duration_ms":0},
                  {"kind":"move","text":"","move":"wiggle","sound":"none","duration_ms":0},
                  {"kind":"move","text":"","move":"spin","sound":"none","duration_ms":0},
                  {"kind":"pause","text":"","move":"none","sound":"none","duration_ms":500},
                  {"kind":"say","text":"Last.","move":"none","sound":"none","duration_ms":0},
                  {"kind":"move","text":"","move":"wiggle","sound":"none","duration_ms":0},
                  {"kind":"pause","text":"","move":"none","sound":"none","duration_ms":500}
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
                  {"kind":"say","text":"First.","move":"none","sound":"none","duration_ms":0},
                  {"kind":"move","text":"spin now","move":"spin","sound":"none","duration_ms":0},
                  {"kind":"pause","text":"","move":"none","sound":"none","duration_ms":500},
                  {"kind":"say","text":"Middle.","move":"none","sound":"none","duration_ms":0},
                  {"kind":"move","text":"","move":"wiggle","sound":"none","duration_ms":0},
                  {"kind":"pause","text":"","move":"none","sound":"none","duration_ms":500},
                  {"kind":"say","text":"Last.","move":"none","sound":"none","duration_ms":0}
                ]}
                """
            )
        )
    }

    func testRequiresAnExplicitPauseAfterEveryMovement() {
        XCTAssertThrowsError(
            try RobotPerformance.decode(
                """
                {"steps":[
                  {"kind":"say","text":"First.","move":"none","sound":"none","duration_ms":0},
                  {"kind":"move","text":"","move":"fast_forward","sound":"none","duration_ms":0},
                  {"kind":"say","text":"Too soon.","move":"none","sound":"none","duration_ms":0},
                  {"kind":"move","text":"","move":"turn_around","sound":"none","duration_ms":0},
                  {"kind":"pause","text":"","move":"none","sound":"none","duration_ms":900},
                  {"kind":"say","text":"Last.","move":"none","sound":"none","duration_ms":0},
                  {"kind":"sound","text":"","move":"none","sound":"chime","duration_ms":0}
                ]}
                """
            )
        )
    }

    func testAPauseDoesNotReplaceStoryTextBetweenMovements() {
        XCTAssertThrowsError(
            try RobotPerformance.decode(
                """
                {"steps":[
                  {"kind":"say","text":"First.","move":"none","sound":"none","duration_ms":0},
                  {"kind":"move","text":"","move":"forward","sound":"none","duration_ms":0},
                  {"kind":"pause","text":"","move":"none","sound":"none","duration_ms":500},
                  {"kind":"move","text":"","move":"turn_left","sound":"none","duration_ms":0},
                  {"kind":"pause","text":"","move":"none","sound":"none","duration_ms":500},
                  {"kind":"say","text":"Last.","move":"none","sound":"none","duration_ms":0},
                  {"kind":"sound","text":"","move":"none","sound":"chime","duration_ms":0}
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

    func testRepairsAnEffectMisplacedInMoveByRealtimeArguments() throws {
        let steps = try RobotPerformance.decode(
            """
            {"steps":[
              {"kind":"say","text":"The dance begins.","move":"none","sound":"none","duration_ms":0},
              {"kind":"move","text":"","move":"wiggle","sound":"none","duration_ms":0},
              {"kind":"pause","text":"","move":"none","sound":"none","duration_ms":600},
              {"kind":"say","text":"A bright path opens.","move":"none","sound":"none","duration_ms":0},
              {"kind":"move","text":"","move":"forward","sound":"none","duration_ms":0},
              {"kind":"pause","text":"","move":"none","sound":"none","duration_ms":700},
              {"kind":"sound","text":"","move":"chime","duration_ms":0}
            ]}
            """
        )

        XCTAssertEqual(steps.last, .sound("chime"))
    }

}
