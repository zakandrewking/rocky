import CoreImage
import XCTest
@testable import Rocky

final class FaceFeaturePrintProbeTests: XCTestCase {
    func testDescriptorRoundTripsAndRejectsIncompatibleModels() throws {
        let descriptor = FaceFeaturePrintDescriptor(revision: 2, values: [0.25, -0.5, 1])
        let data = try JSONEncoder().encode(descriptor)
        XCTAssertEqual(try JSONDecoder().decode(FaceFeaturePrintDescriptor.self, from: data), descriptor)
        XCTAssertEqual(try descriptor.distance(to: descriptor), 0, accuracy: 0.000_001)

        let otherRevision = FaceFeaturePrintDescriptor(revision: 1, values: descriptor.values)
        XCTAssertThrowsError(try descriptor.distance(to: otherRevision)) { error in
            XCTAssertEqual(error as? FaceFeaturePrintError, .incompatibleModel)
        }
        let otherSize = FaceFeaturePrintDescriptor(revision: 2, values: [0.25])
        XCTAssertThrowsError(try descriptor.distance(to: otherSize)) { error in
            XCTAssertEqual(error as? FaceFeaturePrintError, .incompatibleVectorSize)
        }
    }

    func testRevisionTwoIsDeterministicAndSeparatesSyntheticFixtures() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip(
            "Vision's feature-print Espresso context is unavailable in the iOS 26.2 simulator; run this test on the paired iPhone"
        )
        #else
        let probe = FaceFeaturePrintProbe()
        var measurements: [String: FaceFeaturePrintMeasurement] = [:]
        for name in Self.fixtureNames {
            let image = try Self.fixture(named: name)
            measurements[name] = try probe.measure(image)
        }

        let repeated = try probe.measure(Self.fixture(named: "synthetic-a-1"))
        let first = try XCTUnwrap(measurements["synthetic-a-1"])
        XCTAssertEqual(first.descriptor, repeated.descriptor)
        XCTAssertEqual(first.descriptor.revision, 2)
        XCTAssertFalse(first.descriptor.values.isEmpty)
        XCTAssertTrue(first.descriptor.values.allSatisfy(\.isFinite))

        let samePerson = try [
            distance("synthetic-a-1", "synthetic-a-2", in: measurements),
            distance("synthetic-b-1", "synthetic-b-2", in: measurements),
            distance("synthetic-c-1", "synthetic-c-2", in: measurements),
        ]
        let differentPerson = try [
            distance("synthetic-a-1", "synthetic-b-1", in: measurements),
            distance("synthetic-a-1", "synthetic-c-1", in: measurements),
            distance("synthetic-b-1", "synthetic-c-1", in: measurements),
        ]
        let slowest = measurements.values.map(\.elapsedMilliseconds).max() ?? 0
        print(
            "face feature print revision 2: dimensions=\(first.descriptor.values.count) "
                + "same=\(samePerson) different=\(differentPerson) slowest_ms=\(slowest)"
        )

        // This is deliberately only a fixture regression, not Rocky's recognition threshold.
        // Real enrolled/unknown people under actual lighting establish that later on the phone.
        XCTAssertLessThan(try XCTUnwrap(samePerson.max()), try XCTUnwrap(differentPerson.min()))
        #endif
    }

    private static let fixtureNames = [
        "synthetic-a-1", "synthetic-a-2", "synthetic-b-1",
        "synthetic-b-2", "synthetic-c-1", "synthetic-c-2",
    ]

    func testVideoResolutionAndMirroringAgainstStillReferenceOnDevice() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Run camera-domain feature comparison on the paired iPhone")
        #else
        let context = CIContext()
        for name in ["synthetic-a-1", "synthetic-b-1", "synthetic-c-1"] {
            let image = try Self.fixture(named: name)
            let reference = try FaceProbeCapture.measure(Data(contentsOf: Self.fixtureURL(named: name)))
            let scale = 480 / max(image.extent.width, image.extent.height)
            let video = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let mirrored = video.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1,
                                                                   tx: video.extent.width, ty: 0))
            for (label, candidate) in [("original JPEG", image), ("video PNG", video),
                                       ("video", video), ("mirrored video", mirrored)] {
                let data: Data
                if label == "video PNG" {
                    data = try XCTUnwrap(context.pngRepresentation(of: candidate, format: .RGBA8,
                        colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:]))
                } else {
                    data = try XCTUnwrap(context.jpegRepresentation(of: candidate,
                        colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:]))
                }
                let measurement = try FaceProbeCapture.measure(data)
                let distance = try reference.descriptor.distance(to: measurement.descriptor)
                print("synthetic camera domain \(name) \(label): \(distance)")
                XCTAssertTrue(distance.isFinite)
                if label == "video PNG" {
                    // The local camera lane must stay lossless AND normalized. Lossy JPEG moved
                    // these exact same sources outside 0.32 even after scale normalization.
                    XCTAssertLessThan(distance, 0.01)
                } else if label == "video" {
                    XCTAssertGreaterThan(distance, FaceMatcher.maximumDistance)
                }
            }
        }
        #endif
    }

    func testCapturePipelineAlignsAndSeparatesSyntheticFacesOnDevice() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Run the face capture pipeline on the paired iPhone")
        #else
        var measurements: [String: FaceFeaturePrintMeasurement] = [:]
        for name in Self.fixtureNames {
            let data = try Data(contentsOf: Self.fixtureURL(named: name))
            measurements[name] = try FaceProbeCapture.measure(data)
        }
        let same = try [
            distance("synthetic-a-1", "synthetic-a-2", in: measurements),
            distance("synthetic-b-1", "synthetic-b-2", in: measurements),
            distance("synthetic-c-1", "synthetic-c-2", in: measurements),
        ]
        let different = try [
            distance("synthetic-a-1", "synthetic-b-1", in: measurements),
            distance("synthetic-a-1", "synthetic-c-1", in: measurements),
            distance("synthetic-b-1", "synthetic-c-1", in: measurements),
        ]
        print("synthetic aligned capture pipeline \(FaceProbeCapture.preprocessing): same=\(same) different=\(different)")
        XCTAssertLessThan(try XCTUnwrap(same.max()), try XCTUnwrap(different.min()))
        let a = FriendProfile(name: "Synthetic A", templates: [try XCTUnwrap(measurements["synthetic-a-1"]).descriptor])
        let b = FriendProfile(name: "Synthetic B", templates: [try XCTUnwrap(measurements["synthetic-b-1"]).descriptor])
        XCTAssertEqual(FaceMatcher.match(try XCTUnwrap(measurements["synthetic-a-2"]).descriptor,
                                        friends: [a, b])?.id, a.id)
        XCTAssertEqual(FaceMatcher.match(try XCTUnwrap(measurements["synthetic-b-2"]).descriptor,
                                        friends: [a, b])?.id, b.id)
        XCTAssertNil(FaceMatcher.match(try XCTUnwrap(measurements["synthetic-c-2"]).descriptor,
                                     friends: [a, b]))
        #endif
    }

    private static func fixture(named name: String) throws -> CIImage {
        try XCTUnwrap(CIImage(contentsOf: fixtureURL(named: name)))
    }

    private static func fixtureURL(named name: String) throws -> URL {
        let urls = Bundle(for: FaceFeaturePrintProbeTests.self).urls(
            forResourcesWithExtension: "png", subdirectory: nil
        ) ?? []
        return try XCTUnwrap(urls.first { $0.deletingPathExtension().lastPathComponent == name })
    }

    private func distance(
        _ lhs: String,
        _ rhs: String,
        in measurements: [String: FaceFeaturePrintMeasurement]
    ) throws -> Double {
        try XCTUnwrap(measurements[lhs]).descriptor.distance(
            to: XCTUnwrap(measurements[rhs]).descriptor
        )
    }
}
