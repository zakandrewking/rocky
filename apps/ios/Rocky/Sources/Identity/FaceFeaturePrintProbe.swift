import CoreImage
import Foundation
import Vision

/// A versioned vector produced by the first, deliberately isolated face-identity experiment.
///
/// This is not yet Rocky's recognizer. It exists to answer the cheaper questions first: does a
/// license-clean model produce stable, useful separation on aligned face crops, and how long does
/// that take on the actual phone? Keeping the model contract explicit here also prevents a future
/// profile store from comparing vectors made by incompatible algorithms.
struct FaceFeaturePrintDescriptor: Codable, Equatable, Sendable {
    static let algorithm = "apple.vision.image-feature-print"

    let algorithm: String
    let revision: Int
    let values: [Float]

    init(revision: Int, values: [Float]) {
        self.algorithm = Self.algorithm
        self.revision = revision
        self.values = values
    }

    /// Euclidean distance matches Vision's feature-print comparison semantics: smaller is more
    /// similar. No recognition threshold belongs here; that must come from representative device
    /// trials rather than being borrowed from an unrelated model or dataset.
    func distance(to other: Self) throws -> Double {
        guard algorithm == other.algorithm, revision == other.revision else {
            throw FaceFeaturePrintError.incompatibleModel
        }
        guard values.count == other.values.count else {
            throw FaceFeaturePrintError.incompatibleVectorSize
        }
        let squared = zip(values, other.values).reduce(0.0) { partial, pair in
            let delta = Double(pair.0 - pair.1)
            return partial + delta * delta
        }
        return squared.squareRoot()
    }
}

struct FaceFeaturePrintMeasurement: Sendable {
    let descriptor: FaceFeaturePrintDescriptor
    let elapsedMilliseconds: Double
}

enum FaceFeaturePrintError: Error, Equatable {
    case emptyVector
    case incompatibleModel
    case incompatibleVectorSize
    case missingObservation
    case unexpectedElementType
    case unexpectedDataSize
}

/// Revision-pinned Apple Vision baseline for already-cropped face fixtures.
///
/// The legacy-named Vision request is used intentionally: it is synchronous, revision-pinned and
/// returns the feature bytes directly, so Swift 6 never has to send CreateMLComponents'
/// explicitly non-Sendable `ImageFeaturePrint` extractor across an async boundary. The eventual
/// camera integration, if this baseline proves useful, will own a dedicated isolation boundary.
/// The probe never touches `PersonCamera`.
struct FaceFeaturePrintProbe: Sendable {
    static let revision = 2

    func measure(_ image: CIImage) throws -> FaceFeaturePrintMeasurement {
        let started = ContinuousClock.now
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = Self.revision
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(ciImage: image).perform([request])
        guard let observation = request.results?.first else {
            throw FaceFeaturePrintError.missingObservation
        }
        guard observation.elementType == .float else {
            throw FaceFeaturePrintError.unexpectedElementType
        }
        let expectedBytes = observation.elementCount * MemoryLayout<Float>.size
        guard observation.data.count == expectedBytes else {
            throw FaceFeaturePrintError.unexpectedDataSize
        }
        var values = [Float](repeating: 0, count: observation.elementCount)
        _ = values.withUnsafeMutableBytes { destination in
            observation.data.copyBytes(to: destination.bindMemory(to: UInt8.self))
        }
        guard !values.isEmpty else { throw FaceFeaturePrintError.emptyVector }
        let elapsed = ContinuousClock.now - started
        let components = elapsed.components
        let milliseconds = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        return FaceFeaturePrintMeasurement(
            descriptor: FaceFeaturePrintDescriptor(revision: Self.revision, values: values),
            elapsedMilliseconds: milliseconds
        )
    }
}
