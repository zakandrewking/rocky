import CoreImage
import CoreML
import Foundation
import Vision

/// Isolated, serial face-specific Core ML probe. No network, enrollment writes, or voice calls.
/// Vision supplies landmarks only; fal's AuraFace weights supply the identity embedding.
actor AuraFaceProbe {
    static let shared = AuraFaceProbe()
    static let algorithm = "fal.auraface-v1.coreml-int8-fp32"
    static let preprocessing = "arcface-five-point-rgb-112-v1"
    private var model: MLModel?
    private var visionModel: VNCoreMLModel?

    struct Measurement: Sendable {
        let values: [Float]
        let milliseconds: Double
        var identityMeasurement: FaceFeaturePrintMeasurement {
            FaceFeaturePrintMeasurement(descriptor: .init(algorithm: AuraFaceProbe.algorithm, revision: 1,
                values: values, preprocessing: AuraFaceProbe.preprocessing), elapsedMilliseconds: milliseconds)
        }
    }

    func measure(_ data: Data) throws -> Measurement {
        let started = ContinuousClock.now
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            throw FaceProbeCapture.CaptureError.invalidImage
        }
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3
        try VNImageRequestHandler(ciImage: image).perform([request])
        let faces = request.results ?? []
        guard let face = faces.first else { throw FaceProbeCapture.CaptureError.noFace }
        guard faces.count == 1 else { throw FaceProbeCapture.CaptureError.multipleFaces }
        guard let landmarks = face.landmarks,
              let left = landmarks.leftEye, let right = landmarks.rightEye,
              let lips = landmarks.outerLips, let nose = landmarks.noseCrest,
              left.pointCount > 0, right.pointCount > 0, lips.pointCount > 1, nose.pointCount > 0 else {
            throw FaceProbeCapture.CaptureError.eyesMissing
        }
        func pixel(_ point: CGPoint) -> CGPoint {
            CGPoint(x: image.extent.minX + (face.boundingBox.minX + point.x * face.boundingBox.width) * image.extent.width,
                    y: image.extent.minY + (face.boundingBox.minY + point.y * face.boundingBox.height) * image.extent.height)
        }
        func center(_ region: VNFaceLandmarkRegion2D) -> CGPoint {
            let points = region.normalizedPoints
            return pixel(CGPoint(x: points.reduce(0) { $0 + $1.x } / CGFloat(points.count),
                                 y: points.reduce(0) { $0 + $1.y } / CGFloat(points.count)))
        }
        let eyes = [center(left), center(right)].sorted { $0.x < $1.x }
        guard hypot(eyes[1].x - eyes[0].x, eyes[1].y - eyes[0].y) >= 24 else {
            throw FaceProbeCapture.CaptureError.eyesMissing
        }
        let lipPoints = lips.normalizedPoints.sorted { $0.x < $1.x }
        let noseTip = try Self.require(nose.normalizedPoints.min { $0.y < $1.y })
        let source = eyes + [pixel(noseTip), pixel(lipPoints[0]), pixel(lipPoints[lipPoints.count - 1])]
        let transform = try Self.alignment(source)
        let crop = CGRect(x: 0, y: 0, width: 112, height: 112)
        let inverse = transform.inverted()
        guard [CGPoint.zero, CGPoint(x: 112, y: 0), CGPoint(x: 0, y: 112), CGPoint(x: 112, y: 112)]
            .allSatisfy({ image.extent.contains($0.applying(inverse)) }) else {
            throw FaceProbeCapture.CaptureError.faceNearEdge
        }
        let chip = image.transformed(by: transform).cropped(to: crop)
        let normalized = try embedding(chip)
        let duration = started.duration(to: ContinuousClock.now).components
        return Measurement(values: normalized,
                           milliseconds: Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
    }

    /// Independent conversion-parity test entry point for an already aligned 112px fixture.
    func embedAligned(_ data: Data) throws -> [Float] {
        guard let chip = CIImage(data: data), chip.extent.width == 112, chip.extent.height == 112 else {
            throw ProbeError.invalidOutput
        }
        return try embedding(chip)
    }

    private func embedding(_ chip: CIImage) throws -> [Float] {
        let wrapped: VNCoreMLModel
        if let visionModel { wrapped = visionModel }
        else { wrapped = try VNCoreMLModel(for: loadModel()); visionModel = wrapped }
        let request = VNCoreMLRequest(model: wrapped)
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(ciImage: chip).perform([request])
        guard let output = request.results?.first as? VNCoreMLFeatureValueObservation,
              let vector = output.featureValue.multiArrayValue, vector.count == 512 else {
            throw ProbeError.invalidOutput
        }
        return try Self.normalized((0..<vector.count).map { vector[$0].floatValue })
    }

    private func loadModel() throws -> MLModel {
        if let model { return model }
        guard let url = Bundle.main.url(forResource: "AuraFace", withExtension: "mlmodelc") else {
            throw ProbeError.missingModel
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let loaded = try MLModel(contentsOf: url, configuration: configuration)
        model = loaded
        return loaded
    }

    static func normalized(_ values: [Float]) throws -> [Float] {
        guard values.count == 512, values.allSatisfy(\.isFinite) else { throw ProbeError.invalidOutput }
        let norm = sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, norm > 1e-8 else { throw ProbeError.invalidOutput }
        return values.map { Float(Double($0) / norm) }
    }

    /// Least-squares similarity fit, equivalent to the upstream five-point ArcFace crop.
    /// Inputs and destinations use Core Image's bottom-left coordinates.
    static func alignment(_ source: [CGPoint]) throws -> CGAffineTransform {
        guard source.count == 5, source.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw ProbeError.invalidLandmarks
        }
        let destination = [CGPoint(x: 38.2946, y: 112 - 51.6963), CGPoint(x: 73.5318, y: 112 - 51.5014),
                           CGPoint(x: 56.0252, y: 112 - 71.7366), CGPoint(x: 41.5493, y: 112 - 92.3655),
                           CGPoint(x: 70.7299, y: 112 - 92.2041)]
        func mean(_ points: [CGPoint]) -> CGPoint {
            CGPoint(x: points.reduce(0) { $0 + $1.x } / 5, y: points.reduce(0) { $0 + $1.y } / 5)
        }
        let s = mean(source), d = mean(destination)
        var denominator = 0.0, real = 0.0, imaginary = 0.0
        for (from, to) in zip(source, destination) {
            let x = from.x - s.x, y = from.y - s.y, u = to.x - d.x, v = to.y - d.y
            denominator += x * x + y * y
            real += x * u + y * v
            imaginary += x * v - y * u
        }
        guard denominator > 1e-6 else { throw ProbeError.invalidLandmarks }
        let a = real / denominator, b = imaginary / denominator
        guard hypot(a, b) > 1e-8 else { throw ProbeError.invalidLandmarks }
        return CGAffineTransform(a: a, b: b, c: -b, d: a,
                                 tx: d.x - a * s.x + b * s.y, ty: d.y - b * s.x - a * s.y)
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw ProbeError.invalidLandmarks }; return value
    }
    enum ProbeError: LocalizedError {
        case missingModel, invalidOutput, invalidLandmarks
        var errorDescription: String? {
            switch self {
            case .missingModel: "The dedicated face model is not installed."
            case .invalidOutput: "The face model returned an invalid embedding."
            case .invalidLandmarks: "Could not align this face. Keep both eyes and your mouth visible."
            }
        }
    }
}
