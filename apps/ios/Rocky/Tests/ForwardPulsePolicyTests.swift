import XCTest

@testable import Rocky

final class ForwardPulsePolicyTests: XCTestCase {
    private func ready(
        linked: Bool = true, still: Bool = true, trackingNormal: Bool = true,
        poseAge: TimeInterval = 0.1, depthAge: TimeInterval = 0.1,
        cameraTravelMeters: Double = 0
    ) -> ForwardPulsePolicy.Snapshot {
        .init(
            linked: linked, still: still, probeRunning: true, depthMode: true,
            trackingNormal: trackingNormal, poseAge: poseAge, depthAge: depthAge,
            cameraTravelMeters: cameraTravelMeters
        )
    }

    func testReadySnapshotMayStart() {
        XCTAssertNil(ForwardPulsePolicy.stopReason(ready()))
    }

    func testLinkAndTrackingFailuresStop() {
        XCTAssertNotNil(ForwardPulsePolicy.stopReason(ready(linked: false)))
        XCTAssertNotNil(ForwardPulsePolicy.stopReason(ready(still: false)))
        XCTAssertNotNil(ForwardPulsePolicy.stopReason(ready(trackingNormal: false)))
    }

    func testStalePoseOrDepthStops() {
        XCTAssertNotNil(ForwardPulsePolicy.stopReason(ready(poseAge: 0.5)))
        XCTAssertNotNil(ForwardPulsePolicy.stopReason(ready(depthAge: 0.5)))
    }

    func testCameraTravelCapsPulse() {
        XCTAssertNil(ForwardPulsePolicy.stopReason(ready(cameraTravelMeters: 0.19)))
        XCTAssertNotNil(ForwardPulsePolicy.stopReason(ready(cameraTravelMeters: 0.2)))
        XCTAssertLessThanOrEqual(ForwardPulsePolicy.duration, 0.6)
    }
}
