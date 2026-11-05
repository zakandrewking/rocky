import CoreGraphics
import XCTest
@testable import Rocky

final class AuraFaceProbeTests: XCTestCase {
    func testFivePointAlignmentFitsTranslatedRotatedScaledCanonicalLandmarks() throws {
        let canonical = [CGPoint(x: 38.2946, y: 112 - 51.6963), CGPoint(x: 73.5318, y: 112 - 51.5014),
                         CGPoint(x: 56.0252, y: 112 - 71.7366), CGPoint(x: 41.5493, y: 112 - 92.3655),
                         CGPoint(x: 70.7299, y: 112 - 92.2041)]
        let move = CGAffineTransform(a: 2, b: 0.4, c: -0.4, d: 2, tx: 100, ty: 120)
        let source = canonical.map { $0.applying(move) }
        let fitted = try AuraFaceProbe.alignment(source)
        for (point, expected) in zip(source, canonical) {
            let actual = point.applying(fitted)
            XCTAssertEqual(actual.x, expected.x, accuracy: 0.00001)
            XCTAssertEqual(actual.y, expected.y, accuracy: 0.00001)
        }
        XCTAssertThrowsError(try AuraFaceProbe.alignment(Array(repeating: .zero, count: 5)))
        XCTAssertThrowsError(try AuraFaceProbe.alignment([]))
    }

    func testOutputNormalizationRejectsInvalidVectors() throws {
        var values = [Float](repeating: 0, count: 512)
        values[0] = 3; values[1] = 4
        let normalized = try AuraFaceProbe.normalized(values)
        XCTAssertEqual(normalized[0], 0.6, accuracy: 0.000001)
        XCTAssertEqual(normalized[1], 0.8, accuracy: 0.000001)
        XCTAssertThrowsError(try AuraFaceProbe.normalized([0]))
        XCTAssertThrowsError(try AuraFaceProbe.normalized(Array(repeating: 0, count: 512)))
        values[0] = .nan
        XCTAssertThrowsError(try AuraFaceProbe.normalized(values))
    }

    func testModelMatchesUpstreamSyntheticRGBFixturesOnDevice() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Verify actual Neural Engine/CPU model execution on the paired iPhone")
        #else
        let probe = AuraFaceProbe()
        for name in ["synthetic-a-1", "synthetic-b-1", "synthetic-c-1"] {
            let png = try fixture(name + "-112", extension: "png")
            let json = try fixture(name + "-112", extension: "json")
            let expected = try JSONDecoder().decode([Float].self, from: Data(contentsOf: json))
            let actual = try await probe.embedAligned(Data(contentsOf: png))
            let dot = zip(actual, expected).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
            print("AuraFace upstream/device cosine \(name): \(dot)")
            XCTAssertGreaterThan(dot, 0.999)
        }
        #endif
    }

    func testFaceSpecificPipelineSeparatesSyntheticKnownAndUnknownOnDevice() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Run dedicated face-model pipeline on the paired iPhone")
        #else
        let probe = AuraFaceProbe()
        var vectors: [String: [Float]] = [:]
        var timing: [Double] = []
        for name in ["synthetic-a-1", "synthetic-a-2", "synthetic-b-1", "synthetic-b-2", "synthetic-c-1", "synthetic-c-2"] {
            let measurement = try await probe.measure(Data(contentsOf: fixture(name, extension: "png")))
            vectors[name] = measurement.values
            timing.append(measurement.milliseconds)
        }
        func distance(_ a: String, _ b: String) throws -> Double {
            let left = try XCTUnwrap(vectors[a]), right = try XCTUnwrap(vectors[b])
            return sqrt(zip(left, right).reduce(0.0) { $0 + pow(Double($1.0 - $1.1), 2) })
        }
        let same = try [distance("synthetic-a-1", "synthetic-a-2"), distance("synthetic-b-1", "synthetic-b-2"), distance("synthetic-c-1", "synthetic-c-2")]
        let different = try [distance("synthetic-a-1", "synthetic-b-1"), distance("synthetic-a-1", "synthetic-c-1"), distance("synthetic-b-1", "synthetic-c-1")]
        print("AuraFace synthetic pipeline same=\(same) different=\(different) total_ms=\(timing)")
        XCTAssertLessThan(try XCTUnwrap(same.max()), try XCTUnwrap(different.min()))
        XCTAssertLessThan(try XCTUnwrap(timing.dropFirst().max()), 1000)
        #endif
    }

    private func fixture(_ name: String, extension ext: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext))
    }
}
