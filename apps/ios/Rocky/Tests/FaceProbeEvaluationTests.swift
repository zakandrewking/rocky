import CoreGraphics
import XCTest
@testable import Rocky

final class FaceProbeEvaluationTests: XCTestCase {
    func testComparisonsRequireReferenceAndStaySeparatedByGroundTruth() throws {
        var evaluation = FaceProbeEvaluation()
        XCTAssertThrowsError(try evaluation.add(measurement([1, 0], 10), as: .samePerson))
        try evaluation.add(measurement([0, 0], 20), as: .reference)
        try evaluation.add(measurement([0.1, 0], 30), as: .samePerson)
        try evaluation.add(measurement([1, 0], 50), as: .differentPerson)
        XCTAssertEqual(evaluation.sameDistances.first ?? -1, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(evaluation.differentDistances, [1])
        XCTAssertEqual(evaluation.capturePercentile(0.5), 30)
        XCTAssertEqual(evaluation.capturePercentile(0.95), 50)

        let incompatible = FaceFeaturePrintMeasurement(
            descriptor: .init(revision: 1, values: [0, 0]), elapsedMilliseconds: 20
        )
        XCTAssertThrowsError(try evaluation.add(incompatible, as: .samePerson))
        XCTAssertEqual(evaluation.trials.count, 2)
        try evaluation.add(measurement([1, 1], 40), as: .reference)
        XCTAssertTrue(evaluation.trials.isEmpty)
        XCTAssertNil(evaluation.capturePercentile(0.95))
    }

    func testAlignmentMapsRotatedEyesToCanonicalCropRegardlessOfLandmarkOrder() throws {
        let left = CGPoint(x: 120, y: 180)
        let right = CGPoint(x: 200, y: 240)
        let transform = try FaceProbeCapture.alignment(eyeA: right, eyeB: left)
        let mappedLeft = left.applying(transform)
        let mappedRight = right.applying(transform)
        XCTAssertEqual(mappedLeft.x, 104, accuracy: 0.000_001)
        XCTAssertEqual(mappedRight.x, 216, accuracy: 0.000_001)
        XCTAssertEqual(mappedLeft.y, 200, accuracy: 0.000_001)
        XCTAssertEqual(mappedRight.y, 200, accuracy: 0.000_001)
        XCTAssertThrowsError(try FaceProbeCapture.alignment(eyeA: .zero, eyeB: CGPoint(x: 2, y: 2)))
    }

    @MainActor
    func testConversationReferenceReplacesOnlyTemporaryLabState() {
        let model = FaceProbeLabModel()
        let reference = measurement([0.25, 0.5], 12)
        model.useConversationReference(reference)
        XCTAssertEqual(model.evaluation.reference, reference.descriptor)
        XCTAssertEqual(model.evaluation.referenceMilliseconds, 12)
        XCTAssertTrue(model.evaluation.trials.isEmpty)
        model.reset()
        XCTAssertNil(model.evaluation.reference)
    }

    @MainActor
    func testResetInvalidatesAnInFlightCapture() async {
        let model = FaceProbeLabModel()
        let generation = model.generation
        let pending = model.capture(Data([0]), as: .reference, generation: generation)
        model.reset()
        await pending?.value
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.error)
        XCTAssertNil(model.evaluation.reference)
        XCTAssertTrue(model.evaluation.trials.isEmpty)
        XCTAssertNil(model.capture(Data([0]), as: .reference, generation: generation))
    }

    private func measurement(_ values: [Float], _ milliseconds: Double) -> FaceFeaturePrintMeasurement {
        FaceFeaturePrintMeasurement(descriptor: .init(revision: 2, values: values),
                                    elapsedMilliseconds: milliseconds)
    }
}
