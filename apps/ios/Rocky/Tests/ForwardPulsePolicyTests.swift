import XCTest

@testable import Rocky

final class ForwardPulsePolicyTests: XCTestCase {
    private func ready(
        linked: Bool = true, still: Bool = true, trackingNormal: Bool = true,
        poseAge: TimeInterval = 0.1, depthAge: TimeInterval = 0.1,
        cameraTravelMeters: Double = 0, headingChangeDegrees: Double = 0
    ) -> MotorPulsePolicy.Snapshot {
        .init(
            linked: linked, still: still, probeRunning: true, depthMode: true,
            trackingNormal: trackingNormal, poseAge: poseAge, depthAge: depthAge,
            cameraTravelMeters: cameraTravelMeters,
            headingChangeDegrees: headingChangeDegrees
        )
    }

    func testReadySnapshotMayStart() {
        XCTAssertNil(MotorPulsePolicy.stopReason(ready(), motion: .forward))
    }

    func testLinkAndTrackingFailuresStop() {
        XCTAssertNotNil(MotorPulsePolicy.stopReason(ready(linked: false), motion: .rightTurn))
        XCTAssertNotNil(MotorPulsePolicy.stopReason(ready(still: false), motion: .forward))
        XCTAssertNotNil(MotorPulsePolicy.stopReason(ready(trackingNormal: false), motion: .rightTurn))
    }

    func testStalePoseOrDepthStops() {
        XCTAssertNotNil(MotorPulsePolicy.stopReason(ready(poseAge: 0.5), motion: .rightTurn))
        XCTAssertNotNil(MotorPulsePolicy.stopReason(ready(depthAge: 0.5), motion: .forward))
    }

    func testCameraTravelCapsPulse() {
        XCTAssertNil(MotorPulsePolicy.stopReason(ready(cameraTravelMeters: 0.19), motion: .forward))
        XCTAssertNotNil(MotorPulsePolicy.stopReason(ready(cameraTravelMeters: 0.2), motion: .forward))
        XCTAssertLessThanOrEqual(MotorPulsePolicy.Motion.forward.duration, 0.6)
    }

    func testTurnCapsTranslationAndAngle() {
        XCTAssertNil(MotorPulsePolicy.stopReason(
            ready(cameraTravelMeters: 0.09, headingChangeDegrees: 34), motion: .rightTurn
        ))
        XCTAssertNotNil(MotorPulsePolicy.stopReason(
            ready(cameraTravelMeters: 0.1), motion: .rightTurn
        ))
        XCTAssertNotNil(MotorPulsePolicy.stopReason(
            ready(headingChangeDegrees: 35), motion: .rightTurn
        ))
        XCTAssertLessThanOrEqual(MotorPulsePolicy.Motion.rightTurn.duration, 0.5)
    }

    func testHeadingChangeIsPositiveForRightTurnAndWraps() {
        XCTAssertEqual(MotorPulsePolicy.headingChangeDegrees(
            from: SIMD2(0, -1), to: SIMD2(1, 0)
        ), 90, accuracy: 0.001)
        XCTAssertEqual(MotorPulsePolicy.headingChangeDegrees(
            from: SIMD2(0, -1), to: SIMD2(-1, 0)
        ), -90, accuracy: 0.001)
    }
}
