import CoreImage
import Foundation
import Vision

/// The lab's preprocessing is separate from the raw synthetic-fixture probe. Version this before
/// reusing any vector in enrollment. This experiment never persists vectors or source images.
enum FaceProbeCapture {
    static let legacyPreprocessing = "eyes-320-v1"
    static let preprocessing = "camera-480-eyes-320-v2"
    static let outputSize = CGSize(width: 320, height: 320)
    private static let context = CIContext()

    static func measure(_ data: Data) throws -> FaceFeaturePrintMeasurement {
        guard let source = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            throw CaptureError.invalidImage
        }
        let image = try normalized(source)
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3
        try VNImageRequestHandler(ciImage: image).perform([request])
        let faces = request.results ?? []
        guard !faces.isEmpty else { throw CaptureError.noFace }
        guard faces.count == 1, let face = faces.first else { throw CaptureError.multipleFaces }
        guard let left = face.landmarks?.leftEye, let right = face.landmarks?.rightEye,
              left.pointCount > 0, right.pointCount > 0 else { throw CaptureError.eyesMissing }
        func center(_ eye: VNFaceLandmarkRegion2D) -> CGPoint {
            let points = eye.normalizedPoints
            let x = points.reduce(CGFloat.zero) { $0 + $1.x } / CGFloat(eye.pointCount)
            let y = points.reduce(CGFloat.zero) { $0 + $1.y } / CGFloat(eye.pointCount)
            return CGPoint(
                x: image.extent.minX + (face.boundingBox.minX + x * face.boundingBox.width) * image.extent.width,
                y: image.extent.minY + (face.boundingBox.minY + y * face.boundingBox.height) * image.extent.height
            )
        }
        let transform = try alignment(eyeA: center(left), eyeB: center(right))
        let aligned = image.transformed(by: transform)
        let crop = CGRect(origin: .zero, size: outputSize)
        // Check actual source coverage, not the rotated image's larger axis-aligned extent.
        let inverse = transform.inverted()
        let corners = [CGPoint.zero, CGPoint(x: 320, y: 0), CGPoint(x: 0, y: 320), CGPoint(x: 320, y: 320)]
        guard corners.allSatisfy({ image.extent.contains($0.applying(inverse)) }) else {
            throw CaptureError.faceNearEdge
        }
        let measurement = try FaceFeaturePrintProbe().measure(aligned.cropped(to: crop))
        return FaceFeaturePrintMeasurement(
            descriptor: .init(revision: measurement.descriptor.revision,
                              values: measurement.descriptor.values, preprocessing: preprocessing),
            elapsedMilliseconds: measurement.elapsedMilliseconds
        )
    }

    /// Still photos and video must have the same sampling scale BEFORE landmark detection and
    /// alignment. The image-similarity baseline is not invariant to their very different detail.
    /// Rasterizing also prevents lazy Core Image transforms from changing Vision's input path.
    static func normalized(_ source: CIImage) throws -> CIImage {
        let extent = source.extent
        guard extent.width > 0, extent.height > 0, !extent.isInfinite else { throw CaptureError.invalidImage }
        let scale = min(1, 480 / max(extent.width, extent.height))
        let image = source.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let bounds = CGRect(x: 0, y: 0, width: floor(extent.width * scale), height: floor(extent.height * scale))
        guard let raster = context.createCGImage(image, from: bounds, format: .RGBA8,
                                                colorSpace: CGColorSpaceCreateDeviceRGB()) else {
            throw CaptureError.invalidImage
        }
        return CIImage(cgImage: raster)
    }

    /// Roll-normalize and scale the eye centers onto a fixed 320×320 crop. This deliberately
    /// rejects tiny faces rather than magnifying a few pixels into a misleading identity score.
    static func alignment(eyeA: CGPoint, eyeB: CGPoint) throws -> CGAffineTransform {
        let (left, right) = eyeA.x <= eyeB.x ? (eyeA, eyeB) : (eyeB, eyeA)
        let dx = right.x - left.x
        let dy = right.y - left.y
        let distance = hypot(dx, dy)
        guard distance.isFinite, distance >= 24 else { throw CaptureError.eyesMissing }
        let scale = 112 / distance
        let angle = atan2(dy, dx)
        let a = scale * cos(angle)
        let b = -scale * sin(angle)
        return CGAffineTransform(a: a, b: b, c: -b, d: a,
                                 tx: 104 - a * left.x + b * left.y,
                                 ty: 200 - b * left.x - a * left.y)
    }

    enum CaptureError: LocalizedError {
        case invalidImage, noFace, multipleFaces, eyesMissing, faceNearEdge
        var errorDescription: String? {
            switch self {
            case .invalidImage: "Couldn’t read this capture. Please retake it."
            case .noFace: "No face found. Keep one face in the photo."
            case .multipleFaces: "Keep exactly one face in the photo."
            case .eyesMissing: "Move closer and keep both eyes visible."
            case .faceNearEdge: "Center your face with some space around it."
            }
        }
    }
}
