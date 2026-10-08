import Foundation
import CoreGraphics

// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// See bundled licenses/MPL-2.0.txt.
// Port of the mask-overlay compositing formulas in Redlamp's Develop.metal:
// https://github.com/pdcgomes/redlamp/blob/main/packages/RedlampKernels/Sources/Shaders/Develop.metal
// SpektraFilm applies the preview tint into the final CGImage pixels, not as an
// independently laid-out SwiftUI overlay. The image remains full opacity.

enum RedlampMaskDisplayStyle: String, CaseIterable, Identifiable, Sendable {
    case color = "Color Overlay"
    case colorOnBW = "Color on B&W"
    case imageOnBlack = "Image on Black"
    case imageOnWhite = "Image on White"
    case blackAndWhite = "Mask B&W"
    case imageOnBW = "Image on B&W"
    var id: String { rawValue }
}

struct RedlampMaskDisplay {
    static func rgbaBytes(_ image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let space = image.colorSpace ?? (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
        let bitmap = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue |
                                         CGBitmapInfo.byteOrder32Big.rawValue)
        let ok = rgba.withUnsafeMutableBytes { ptr in
            guard let address = ptr.baseAddress,
                  let context = CGContext(data: address, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space, bitmapInfo: bitmap.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? rgba : nil
    }

    static func compose(
        rgba: [UInt8], displayWidth: Int, displayHeight: Int,
        grade: LocalGradeRecord, preGeometryWidth: Int, preGeometryHeight: Int,
        geometry: GeometrySettings?, style: RedlampMaskDisplayStyle,
        opacity: Float = 0.73
    ) -> [UInt8]? {
        guard displayWidth > 0, displayHeight > 0,
              rgba.count == displayWidth * displayHeight * 4,
              preGeometryWidth > 0, preGeometryHeight > 0 else { return nil }
        // No fake coverage: raster masks and local grades run through exactly the
        // same evaluator as export. Geometry is the identical non-destructive transform.
        let maxEdge = max(preGeometryWidth, preGeometryHeight)
        let scale = min(1, 1080.0 / Double(maxEdge))
        let w = max(1, Int((Double(preGeometryWidth) * scale).rounded()))
        let h = max(1, Int((Double(preGeometryHeight) * scale).rounded()))
        // Read the SAME Metal mask coverage path used by the local-grade renderer;
        // only use the matching Redlamp-derived CPU implementation if GPU is unavailable.
        guard let coverage = MaskMetalEngine.shared?.renderCoverage(
            grade: grade, width: w, height: h
        ), coverage.count == w * h else {
            GPUProcessingFailure.report("Mask overlay Metal evaluation failed. No CPU fallback is running.")
            return nil
        }
        var maskPixels = [Float](repeating: 0, count: w * h * 4)
        for i in 0..<coverage.count {
            let q = i * 4
            maskPixels[q] = coverage[i]
            maskPixels[q + 1] = coverage[i]
            maskPixels[q + 2] = coverage[i]
            maskPixels[q + 3] = 1
        }
        let maskPlane = PixelBufferF32(width: w, height: h, pixels: maskPixels)
        let mapped = GeometryEngine.transformed(maskPlane, settings: geometry)
        let mw = mapped.width, mh = mapped.height
        guard mw > 0, mh > 0 else { return nil }
        var result = rgba
        let appliedOpacity = max(0, min(1, opacity))
        for y in 0..<displayHeight {
            if (y & 31) == 0 && Task.isCancelled { return nil }
            let my = min(mh - 1, Int((Double(y) + 0.5) * Double(mh) / Double(displayHeight)))
            for x in 0..<displayWidth {
                let mx = min(mw - 1, Int((Double(x) + 0.5) * Double(mw) / Double(displayWidth)))
                let cover = max(0, min(1, mapped.pixels[(my * mw + mx) * 4]))
                let o = (y * displayWidth + x) * 4
                let r = Float(rgba[o]) / 255, g = Float(rgba[o + 1]) / 255, b = Float(rgba[o + 2]) / 255
                let gray = r * 0.2126 + g * 0.7152 + b * 0.0722
                let out: (Float, Float, Float)
                switch style {
                case .color:
                    let alpha = cover * appliedOpacity
                    out = (r * (1 - alpha) + 0.95 * alpha,
                           g * (1 - alpha) + 0.18 * alpha,
                           b * (1 - alpha) + 0.18 * alpha)
                case .colorOnBW:
                    let alpha = cover * appliedOpacity
                    out = (gray * (1 - alpha) + 0.95 * alpha,
                           gray * (1 - alpha) + 0.18 * alpha,
                           gray * (1 - alpha) + 0.18 * alpha)
                case .imageOnBlack: out = (r * cover, g * cover, b * cover)
                case .imageOnWhite:
                    out = (1 - cover + r * cover, 1 - cover + g * cover, 1 - cover + b * cover)
                case .blackAndWhite: out = (cover, cover, cover)
                case .imageOnBW:
                    out = (gray * (1 - cover) + r * cover,
                           gray * (1 - cover) + g * cover,
                           gray * (1 - cover) + b * cover)
                }
                result[o] = UInt8(clamping: Int((max(0, min(1, out.0)) * 255).rounded()))
                result[o + 1] = UInt8(clamping: Int((max(0, min(1, out.1)) * 255).rounded()))
                result[o + 2] = UInt8(clamping: Int((max(0, min(1, out.2)) * 255).rounded()))
                // Keep the base photo's alpha; do not create a second overlay surface.
            }
        }
        return result
    }

    static func image(width: Int, height: Int, rgba: [UInt8], colorSpace: CGColorSpace? = nil) -> CGImage? {
        guard width > 0, height > 0, rgba.count == width * height * 4,
              let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: colorSpace ?? (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue |
                                                  CGBitmapInfo.byteOrder32Big.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
