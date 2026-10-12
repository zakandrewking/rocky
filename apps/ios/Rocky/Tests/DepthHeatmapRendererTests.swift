import XCTest

@testable import Rocky

final class DepthHeatmapRendererTests: XCTestCase {
    func testInvalidDepthIsBlack() {
        let color = DepthHeatmapRenderer.color(meters: .nan, confidence: 2)
        XCTAssertEqual(color.0, 0)
        XCTAssertEqual(color.1, 0)
        XCTAssertEqual(color.2, 0)
    }

    func testNearAndFarAreDistinctAndClamp() {
        let near = DepthHeatmapRenderer.color(meters: 0.2, confidence: 2)
        let nearer = DepthHeatmapRenderer.color(meters: 0.1, confidence: 2)
        let far = DepthHeatmapRenderer.color(meters: 4, confidence: 2)
        let farther = DepthHeatmapRenderer.color(meters: 10, confidence: 2)
        XCTAssertEqual(near.0, nearer.0)
        XCTAssertEqual(near.1, nearer.1)
        XCTAssertEqual(far.2, farther.2)
        XCTAssertGreaterThan(near.0, far.0)
        XCTAssertGreaterThan(far.2, near.2)
    }

    func testLowConfidenceIsDimmer() {
        let low = DepthHeatmapRenderer.color(meters: 1, confidence: 0)
        let high = DepthHeatmapRenderer.color(meters: 1, confidence: 2)
        XCTAssertLessThan(Int(low.0) + Int(low.1) + Int(low.2),
                          Int(high.0) + Int(high.1) + Int(high.2))
    }
}
