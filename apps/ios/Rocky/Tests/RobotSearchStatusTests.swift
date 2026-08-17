import XCTest

@testable import Rocky

final class RobotSearchStatusTests: XCTestCase {
    func testFoundAddressWaitingForTCPIsNotReportedAsMissingOrSettled() {
        XCTAssertFalse(
            RobotSearchStatus.isSettled(connected: false, searchFinished: true, hasHost: true)
        )
        XCTAssertEqual(
            RobotSearchStatus.label(
                connected: false,
                searchFinished: true,
                hasHost: true,
                mode: "unknown",
                mood: "still"
            ),
            "robot: found · connecting…"
        )
    }

    func testConnectedStatusAlwaysShowsCurrentModeAndMood() {
        XCTAssertTrue(
            RobotSearchStatus.isSettled(connected: true, searchFinished: true, hasHost: true)
        )
        XCTAssertEqual(
            RobotSearchStatus.label(
                connected: true,
                searchFinished: true,
                hasHost: true,
                mode: "listening",
                mood: "exploring"
            ),
            "robot: connected · listening/exploring"
        )
    }

    func testCompletedSweepWithoutAddressIsActuallyNotFound() {
        XCTAssertTrue(
            RobotSearchStatus.isSettled(connected: false, searchFinished: true, hasHost: false)
        )
        XCTAssertEqual(
            RobotSearchStatus.label(
                connected: false,
                searchFinished: true,
                hasHost: false,
                mode: "unknown",
                mood: "still"
            ),
            "robot: not found · voice only"
        )
    }
}
