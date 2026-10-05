import Foundation
import CoreGraphics
import CoreVideo
import Vision

struct SubjectMaskPayload: Sendable {
    let width: Int
    let height: Int
    let personAlpha: [UInt8]
    /// Vision-normalized rectangles (origin bottom-left) used to raise confidence for faces/neck.
    let faceRects: [CGRect]

    static func empty(width: Int, height: Int) -> SubjectMaskPayload {
        SubjectMaskPayload(width: width, height: height, personAlpha: [UInt8](repeating: 255, count: max(1, width * height)), faceRects: [])
    }

    func alpha(x: Int, y: Int) -> UInt8 {
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        return personAlpha[y * width + x]
    }

    func isInsideFace(x: Int, y: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        let nx = (Double(x) + 0.5) / Double(width)
        let nyBottom = 1.0 - (Double(y) + 0.5) / Double(height)
        return faceRects.contains { rect in
            // Slightly expand the face downwards to include ears, jaw and neck, all useful
            // photographic skin references that a strict face rectangle can cut off.
            let expanded = CGRect(
                x: max(0, rect.minX - rect.width * 0.10),
                y: max(0, rect.minY - rect.height * 0.32),
                width: min(1, rect.width * 1.20),
                height: min(1, rect.height * 1.42)
            )
            return expanded.contains(CGPoint(x: nx, y: nyBottom))
        }
    }
}

/// Subject isolation is native Vision so the application stays self-contained on macOS.
/// Skin classification combines three concrete open-source approaches: DeoTime/vectorscope's
/// BT.601 YCbCr + complexion-spanning HSV ranges and PrimeraHue's MIT-licensed rg-chromaticity
/// skin gate. Subject isolation prevents warm décor and clothing from dominating the result,
/// while face/neck regions intentionally get a lower confidence threshold.
actor SubjectSkinMaskEngine {
    func subjectMask(from buffer: PixelBufferF32, width: Int, height: Int) throws -> SubjectMaskPayload {
        guard width > 0, height > 0,
              let cg = buffer.makeCGImage8(colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()) else {
            return .empty(width: width, height: height)
        }

        var faces: [CGRect] = []
        let faceRequest = VNDetectFaceRectanglesRequest()
        let segmentation = VNGeneratePersonSegmentationRequest()
        segmentation.qualityLevel = .accurate
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try handler.perform([segmentation, faceRequest])
        faces = (faceRequest.results ?? []).map(\.boundingBox)

        guard let observation = segmentation.results?.first else {
            // Fallback is deliberately permissive so Skin Check still works if Vision cannot
            // segment an unusual frame; the color classifier remains active in that case.
            return .empty(width: width, height: height)
        }
        let pixelBuffer = observation.pixelBuffer
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return .empty(width: width, height: height) }
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var out = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let syf = min(
                Double(sourceHeight - 1),
                max(0.0, (Double(y) + 0.5) * Double(sourceHeight) / Double(height) - 0.5)
            )
            let y0 = Int(floor(syf))
            let y1 = min(sourceHeight - 1, y0 + 1)
            let fy = syf - Double(y0)
            let row0 = base.advanced(by: y0 * rowBytes).assumingMemoryBound(to: UInt8.self)
            let row1 = base.advanced(by: y1 * rowBytes).assumingMemoryBound(to: UInt8.self)

            for x in 0..<width {
                let sxf = min(
                    Double(sourceWidth - 1),
                    max(0.0, (Double(x) + 0.5) * Double(sourceWidth) / Double(width) - 0.5)
                )
                let x0 = Int(floor(sxf))
                let x1 = min(sourceWidth - 1, x0 + 1)
                let fx = sxf - Double(x0)

                let top = Double(row0[x0]) * (1.0 - fx) + Double(row0[x1]) * fx
                let bottom = Double(row1[x0]) * (1.0 - fx) + Double(row1[x1]) * fx
                let value = top * (1.0 - fy) + bottom * fy
                out[y * width + x] = UInt8(clamping: Int(value.rounded()))
            }
        }
        return SubjectMaskPayload(width: width, height: height, personAlpha: out, faceRects: faces)
    }
}

struct OpenSourceSkinClassifier {
    struct Result: Sendable {
        let matches: Bool
        let confidence: Double
    }

    /// Concrete sources:
    /// - DeoTime/vectorscope: BT.601 full-range Cb 77...127 / Cr 133...173 and broad HSV ranges.
    /// - geoffsmithBK/primera-suite (MIT), PrimeraHue: rg-chromaticity gate centered around
    ///   green-normalized skin ratios with red-leading-vs-blue discrimination.
    ///
    /// Input must already be canonical display-encoded sRGB. StudioAnalysis performs the
    /// renderer-output transform once before subject/skin classification. This avoids the old
    /// double-gamma bug on Rec.709 Gamma 2.4 output.
    static func classify(displayR: Float, displayG: Float, displayB: Float, inFaceRegion: Bool) -> Result {
        let r = Double(max(0, min(1, displayR)))
        let g = Double(max(0, min(1, displayG)))
        let b = Double(max(0, min(1, displayB)))

        let cb = (-0.169 * r - 0.331 * g + 0.500 * b) * 255.0 + 128.0
        let cr = ( 0.500 * r - 0.419 * g - 0.081 * b) * 255.0 + 128.0
        let ycbcr = cb >= 77 && cb <= 127 && cr >= 133 && cr <= 173

        let (h, s, v) = hsv(r: r, g: g, b: b)
        let ranges: [(Double, Double, Double, Double, Double, Double)] = [
            (0, 30, 0.08, 0.62, 0.68, 1.00),
            (0, 35, 0.12, 0.76, 0.48, 1.00),
            (4, 40, 0.16, 0.86, 0.27, 0.88),
            (7, 45, 0.18, 0.91, 0.13, 0.68),
            (9, 50, 0.12, 0.88, 0.06, 0.50),
        ]
        let hsvMatch = ranges.contains {
            h >= $0.0 && h <= $0.1 &&
            s >= $0.2 && s <= $0.3 &&
            v >= $0.4 && v <= $0.5
        }

        // PrimeraHue v0.6.0 uses normalized rg chromaticity because those ratios are largely
        // invariant to overall brightness. This is especially useful for dark skin and for
        // underexposed portraits where HSV value/saturation alone can become unreliable.
        let sum = max(1.0e-8, r + g + b)
        let rn = r / sum
        let gn = g / sum
        let bn = b / sum
        let gnGate = smoothstep(0.22, 0.33, gn) * (1.0 - smoothstep(0.37, 0.48, gn))
        let rbGate = smoothstep(0.0, 0.04, rn - bn)
        let hueDistance = circularHueDistance(h, 28.0)
        let hueGate = 1.0 - smoothstep(0.0, 32.0, hueDistance)
        let chromaticityScore = max(0.0, min(1.0, gnGate * rbGate * hueGate))
        let rgMatch = chromaticityScore >= (inFaceRegion ? 0.20 : 0.38)

        // Face/neck: two independent classifiers agreeing is strongest, but rg chromaticity is
        // allowed to rescue low-light/low-saturation skin. Body: require rg plus at least one of
        // the conventional display-domain gates to reject skin-colored clothes and wood.
        let conventionalCount = (ycbcr ? 1 : 0) + (hsvMatch ? 1 : 0)
        let matches: Bool
        if inFaceRegion {
            matches = conventionalCount >= 2 || (rgMatch && conventionalCount >= 1) || chromaticityScore >= 0.62
        } else {
            matches = rgMatch && conventionalCount >= 1
        }

        let confidence: Double
        if !matches {
            confidence = 0
        } else {
            let conventional = conventionalCount == 2 ? 0.95 : (conventionalCount == 1 ? 0.70 : 0.45)
            let rg = 0.55 + 0.45 * chromaticityScore
            confidence = min(1.0, (inFaceRegion ? 0.10 : 0.0) + 0.52 * conventional + 0.48 * rg)
        }
        return Result(matches: matches, confidence: confidence)
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge1 > edge0 else { return x >= edge1 ? 1 : 0 }
        let t = max(0, min(1, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    private static func circularHueDistance(_ h1: Double, _ h2: Double) -> Double {
        let d = abs(h1 - h2).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }


    private static func hsv(r: Double, g: Double, b: Double) -> (Double, Double, Double) {
        let maximum = max(r, max(g, b))
        let minimum = min(r, min(g, b))
        let delta = maximum - minimum
        var hue = 0.0
        if delta > 1e-9 {
            if maximum == r { hue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if maximum == g { hue = 60 * ((b - r) / delta + 2) }
            else { hue = 60 * ((r - g) / delta + 4) }
        }
        if hue < 0 { hue += 360 }
        let saturation = maximum <= 1e-9 ? 0 : delta / maximum
        return (hue, saturation, maximum)
    }
}
