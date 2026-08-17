import XCTest

@testable import Rocky

@MainActor
final class BehaviorWakePolicyTests: XCTestCase {
    func testConnectedStillBodyWakesIntoExploring() {
        XCTAssertEqual(
            BehaviorMonitor.wakeMoodIfNeeded(connected: true, currentMood: "still"),
            "exploring"
        )
    }

    func testStartupDiscoveryAloneAndAlreadyAwakeMoodsAreLeftAlone() {
        XCTAssertNil(BehaviorMonitor.wakeMoodIfNeeded(connected: false, currentMood: "still"))
        XCTAssertNil(BehaviorMonitor.wakeMoodIfNeeded(connected: true, currentMood: "calm"))
        XCTAssertNil(BehaviorMonitor.wakeMoodIfNeeded(connected: true, currentMood: "exploring"))
        XCTAssertNil(BehaviorMonitor.wakeMoodIfNeeded(connected: true, currentMood: "excitable"))
    }
}
