import ARKit
import CoreGraphics
import CoreVideo
import UIKit

/// A diagnostic picture of ARKit scene depth, not a traversability or obstacle map.
/// Input distances are metres from the camera plane. Nothing is written to disk.
enum DepthHeatmapRenderer {
    static let nearMeters: Float = 0.2
    static let farMeters: Float = 4.0

    static func color(meters: Float, confidence: UInt8) -> (UInt8, UInt8, UInt8, UInt8) {
        guard meters.isFinite, meters > 0 else { return (0, 0, 0, 255) }
        let t = max(0, min(1, (meters - nearMeters) / (farMeters - nearMeters)))
        let stops: [(Float, Float, Float)] = [
            (255, 57, 67), (255, 205, 60), (69, 221, 135),
            (48, 178, 232), (65, 74, 218),
        ]
        let scaled = t * Float(stops.count - 1)
        let index = min(Int(scaled), stops.count - 2)
        let fraction = scaled - Float(index)
        let left = stops[index]
        let right = stops[index + 1]
        let brightness: Float = confidence == 0 ? 0.28 : (confidence == 1 ? 0.68 : 1)
        func channel(_ a: Float, _ b: Float) -> UInt8 {
            UInt8((a + (b - a) * fraction) * brightness)
        }
        return (channel(left.0, right.0), channel(left.1, right.1),
                channel(left.2, right.2), 255)
    }

    static func image(from depth: ARDepthData) -> UIImage? {
        let map = depth.depthMap
        let confidence = depth.confidenceMap
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32 else { return nil }
        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        guard width > 0, height > 0 else { return nil }
        if let confidence {
            guard CVPixelBufferGetWidth(confidence) == width,
                  CVPixelBufferGetHeight(confidence) == height else { return nil }
        }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        if let confidence { CVPixelBufferLockBaseAddress(confidence, .readOnly) }
        defer {
            if let confidence { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }
            CVPixelBufferUnlockBaseAddress(map, .readOnly)
        }
        guard let mapBase = CVPixelBufferGetBaseAddress(map) else { return nil }
        let confidenceBase = confidence.flatMap(CVPixelBufferGetBaseAddress)
        let depthRowBytes = CVPixelBufferGetBytesPerRow(map)
        let confidenceRowBytes = confidence.map(CVPixelBufferGetBytesPerRow) ?? 0
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let depths = mapBase.advanced(by: y * depthRowBytes).assumingMemoryBound(to: Float.self)
            let confidences = confidenceBase?.advanced(by: y * confidenceRowBytes)
                .assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let (r, g, b, a) = color(meters: depths[x], confidence: confidences?[x] ?? 2)
                let offset = (y * width + x) * 4
                rgba[offset] = r
                rgba[offset + 1] = g
                rgba[offset + 2] = b
                rgba[offset + 3] = a
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cgImage = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { return nil }
        // ARKit's depth buffer uses sensor orientation. Rocky's UI is portrait-only.
        return UIImage(cgImage: cgImage, scale: 1, orientation: .right)
    }
}
