// Adapted from Redlamp MaskEdges.swift (MPL-2.0), process 13.
// See Resources/Redlamp-MPL-2.0.txt and IMPLEMENTATION_SOURCES.md.
import Foundation
import CoreGraphics

/// Apply analysis-grid guided-filter coefficients to the unedited photo's full-size pixels.
/// Where the photo has no edge, retain the original mask instead of blurring its shape.
enum CoarseMaskEdges {
    static func refine(_ mask: GrayMask, analysis: CGImage, full: CGImage) -> GrayMask {
        let size = PixelSize(width: analysis.width, height: analysis.height)
        guard let smallRGB = RGBImage(analysis, size: size),
              let fullRGB = RGBImage(full, size: PixelSize(width: full.width, height: full.height)) else { return mask }
        let input = mask.resized(to: size).coverage
        @Sendable func ev(_ encoded: SIMD3<Float>) -> Float {
            let rgb = SRGB.decode(encoded)
            return log2(max(rgb.x * 0.25 + rgb.y * 0.5 + rgb.z * 0.25, 1e-6))
        }
        let guide = (0..<(size.width * size.height)).map { ev(smallRGB.rgb($0 % size.width, $0 / size.width)) }
        let epsilon: Float = 0.02
        let (a, b) = GuidedFilter.coefficients(input, guide: guide, width: size.width, height: size.height, radius: 3, epsilon: epsilon)
        let mean = BoxFilter.blur(guide, width: size.width, height: size.height, radius: 3)
        let square = BoxFilter.blur(guide.map { $0 * $0 }, width: size.width, height: size.height, radius: 3)
        let trust = BoxFilter.blur(zip(square, mean).map { square, mean in
            let variance = max(square - mean * mean, 0)
            return variance / (variance + epsilon)
        }, width: size.width, height: size.height, radius: 3)
        @Sendable func sample(_ values: [Float], _ x: Int, _ y: Int) -> Float {
            let fx = min(Float(size.width - 1), max(0, (Float(x) + 0.5) * Float(size.width) / Float(full.width) - 0.5))
            let fy = min(Float(size.height - 1), max(0, (Float(y) + 0.5) * Float(size.height) / Float(full.height) - 0.5))
            let x0 = Int(fx), y0 = Int(fy), x1 = min(x0 + 1, size.width - 1), y1 = min(y0 + 1, size.height - 1)
            let tx = fx - Float(x0), ty = fy - Float(y0)
            let top = values[y0 * size.width + x0] * (1 - tx) + values[y0 * size.width + x1] * tx
            let bottom = values[y1 * size.width + x0] * (1 - tx) + values[y1 * size.width + x1] * tx
            return top * (1 - ty) + bottom * ty
        }
        var pixels = [UInt8](repeating: 0, count: full.width * full.height)
        Parallel.fill(&pixels) { index in
            let x = index % full.width, y = index / full.width
            let guided = min(1, max(0, sample(a, x, y) * ev(fullRGB.rgb(x, y)) + sample(b, x, y)))
            let weight = min(1, max(0, sample(trust, x, y)))
            let value = sample(input, x, y) * (1 - weight) + guided * weight
            return UInt8((min(1, max(0, value)) * 255).rounded())
        }
        return GrayMask(width: full.width, height: full.height, pixels: pixels)
    }
}
