import XCTest

@testable import Rocky

final class ServoCalibrationTests: XCTestCase {
    func testS3PresentsTheFullPhysicalTravelWhileKeepingCyberOSCommandsBounded() {
        let profile = ServoTravelProfile.forPort("S3")

        XCTAssertEqual(profile.physicalMaximum, 270)
        XCTAssertEqual(profile.physicalAngle(forCommandAngle: 0), 0)
        XCTAssertEqual(profile.physicalAngle(forCommandAngle: 90), 135)
        XCTAssertEqual(profile.physicalAngle(forCommandAngle: 180), 270)
        XCTAssertEqual(profile.physicalAngle(forCommandAngle: 500), 270)
    }

    func testS4KeepsTheOrdinaryServoDegreeScale() {
        let profile = ServoTravelProfile.forPort("s4")

        XCTAssertEqual(profile.physicalMaximum, 180)
        XCTAssertEqual(profile.physicalAngle(forCommandAngle: 90), 90)
        XCTAssertEqual(profile.physicalAngle(forCommandAngle: 180), 180)
    }

    func testMapsAnAsymmetricCalibrationAroundItsRealCenter() {
        let calibration = ServoCalibration(minimum: 20, center: 80, maximum: 150, reversed: false)

        XCTAssertEqual(calibration.angle(for: -1), 20)
        XCTAssertEqual(calibration.angle(for: 0), 80)
        XCTAssertEqual(calibration.angle(for: 1), 150)
        XCTAssertEqual(calibration.angle(for: -0.5), 50)
        XCTAssertEqual(calibration.angle(for: 0.5), 115)
    }

    func testReverseMirrorsTheLogicalControlWithoutChangingLimits() {
        let calibration = ServoCalibration(minimum: 10, center: 90, maximum: 160, reversed: true)

        XCTAssertEqual(calibration.angle(for: -1), 160)
        XCTAssertEqual(calibration.angle(for: 0), 90)
        XCTAssertEqual(calibration.angle(for: 1), 10)
    }

    func testCorruptPersistedCalibrationIsMadeServoSafe() {
        let calibration = ServoCalibration(minimum: -20, center: 500, maximum: 900, reversed: false)

        XCTAssertEqual(calibration.minimum, 0)
        XCTAssertEqual(calibration.center, 179)
        XCTAssertEqual(calibration.maximum, 180)
        XCTAssertEqual(calibration.angle(for: -5), 0)
        XCTAssertEqual(calibration.angle(for: 5), 180)
    }
}
