import XCTest

@testable import Rocky

final class ServoCalibrationTests: XCTestCase {
    func testMapsLinearlyBetweenOnlyTheTwoEndpoints() {
        let calibration = ServoCalibration(minimum: 20, maximum: 150, reversed: false)

        XCTAssertEqual(calibration.angle(for: -1), 20)
        XCTAssertEqual(calibration.angle(for: 0), 85)
        XCTAssertEqual(calibration.angle(for: 1), 150)
        XCTAssertEqual(calibration.angle(for: -0.5), 53)
        XCTAssertEqual(calibration.angle(for: 0.5), 118)
    }

    func testReverseMirrorsTheLogicalControlWithoutChangingLimits() {
        let calibration = ServoCalibration(minimum: 10, maximum: 160, reversed: true)

        XCTAssertEqual(calibration.angle(for: -1), 160)
        XCTAssertEqual(calibration.angle(for: 0), 85)
        XCTAssertEqual(calibration.angle(for: 1), 10)
    }

    func testCorruptPersistedCalibrationIsMadeServoSafe() {
        let calibration = ServoCalibration(minimum: -20, maximum: 900, reversed: false)

        XCTAssertEqual(calibration.minimum, 0)
        XCTAssertEqual(calibration.maximum, 180)
        XCTAssertEqual(calibration.angle(for: -5), 0)
        XCTAssertEqual(calibration.angle(for: 5), 180)
    }

    func testMinimumAlwaysLeavesRoomForMaximum() {
        let calibration = ServoCalibration(minimum: 500, maximum: -100, reversed: false)

        XCTAssertEqual(calibration.minimum, 179)
        XCTAssertEqual(calibration.maximum, 180)
        XCTAssertEqual(calibration.angle(for: 0), 180)
    }

    func testVerticalControlUsesItsActualUnrotatedTouchCoordinates() {
        XCTAssertEqual(VerticalControlMath.position(atY: 0, height: 200), 1)
        XCTAssertEqual(VerticalControlMath.position(atY: 100, height: 200), 0)
        XCTAssertEqual(VerticalControlMath.position(atY: 200, height: 200), -1)
        XCTAssertEqual(VerticalControlMath.position(atY: -50, height: 200), 1)
        XCTAssertEqual(VerticalControlMath.position(atY: 250, height: 200), -1)
    }

    func testVerticalThumbPositionIsTheInverseOfTouchMapping() {
        for position in stride(from: -1.0, through: 1.0, by: 0.25) {
            let y = VerticalControlMath.y(for: position, height: 174)
            XCTAssertEqual(
                VerticalControlMath.position(atY: y, height: 174), position,
                accuracy: 0.0001
            )
        }
    }

    func testRelativeDragStartsFromCurrentValueInsteadOfFingerLocation() {
        XCTAssertEqual(
            VerticalControlMath.relativePosition(startingAt: 0.4, translationY: 0, height: 160),
            0.4
        )
        XCTAssertEqual(
            VerticalControlMath.relativePosition(startingAt: 0, translationY: -40, height: 160),
            0.5
        )
        XCTAssertEqual(
            VerticalControlMath.relativePosition(startingAt: 0.8, translationY: -160, height: 160),
            1
        )
    }

    func testDriveResponseHasStableCenterAndFullRange() {
        XCTAssertEqual(DriveControlResponse.throttle(0.14), 0)
        XCTAssertEqual(DriveControlResponse.throttle(-0.14), 0)
        XCTAssertEqual(DriveControlResponse.steering(0.20), 0)
        XCTAssertEqual(DriveControlResponse.steering(-0.20), 0)
        XCTAssertEqual(DriveControlResponse.throttle(1), 1)
        XCTAssertEqual(DriveControlResponse.throttle(-1), -1)
        XCTAssertEqual(DriveControlResponse.steering(1), 1)
        XCTAssertEqual(DriveControlResponse.steering(-1), -1)
    }

    func testSteeringIsGentlerThanThrottleAwayFromCenter() {
        XCTAssertLessThan(
            abs(DriveControlResponse.steering(0.4)),
            abs(DriveControlResponse.throttle(0.4))
        )
    }
}
