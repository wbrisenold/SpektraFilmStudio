import Foundation
import CoreGraphics
import Vision

// Crop/geometry behavior follows the professional model used by darktable's crop/clipping
// and perspective (ashift) modules: non-destructive normalized crop, straighten, keystone,
// automatic crop to valid pixels, and Auto/Level/Vertical/Full correction modes.
// The Swift implementation is original; see IMPLEMENTATION_SOURCES.md.

enum CropPresetCategory: String, CaseIterable, Identifiable, Sendable {
    case photo = "Photo & Print"
    case social = "Social"
    case cinema = "Film & Cinema"
    var id: String { rawValue }
}

struct CropAspectPreset: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let ratio: Double? // width / height; nil = original/free
    let category: CropPresetCategory

    static let all: [CropAspectPreset] = [
        .init(id: "free", label: "Free", ratio: nil, category: .photo),
        .init(id: "original", label: "Original", ratio: -1, category: .photo),
        .init(id: "1x1", label: "1 : 1", ratio: 1, category: .photo),
        .init(id: "2x3", label: "2 : 3", ratio: 2.0/3.0, category: .photo),
        .init(id: "3x2", label: "3 : 2", ratio: 3.0/2.0, category: .photo),
        .init(id: "4x5", label: "4 : 5 / 8 × 10", ratio: 4.0/5.0, category: .photo),
        .init(id: "5x4", label: "5 : 4", ratio: 5.0/4.0, category: .photo),
        .init(id: "5x7", label: "5 : 7", ratio: 5.0/7.0, category: .photo),
        .init(id: "7x5", label: "7 : 5", ratio: 7.0/5.0, category: .photo),
        .init(id: "11x14", label: "11 : 14", ratio: 11.0/14.0, category: .photo),
        .init(id: "a-series", label: "A-Series Paper", ratio: 1.0/sqrt(2.0), category: .photo),

        .init(id: "ig-square", label: "Instagram Square · 1 : 1", ratio: 1, category: .social),
        .init(id: "ig-portrait", label: "Instagram Portrait · 4 : 5", ratio: 4.0/5.0, category: .social),
        .init(id: "ig-landscape", label: "Instagram Landscape · 1.91 : 1", ratio: 1.91, category: .social),
        .init(id: "story", label: "Story / Reel / TikTok · 9 : 16", ratio: 9.0/16.0, category: .social),
        .init(id: "yt", label: "YouTube / Video · 16 : 9", ratio: 16.0/9.0, category: .social),
        .init(id: "pinterest", label: "Pinterest · 2 : 3", ratio: 2.0/3.0, category: .social),
        .init(id: "social-wide", label: "Wide Social / Link · 1.91 : 1", ratio: 1.91, category: .social),

        .init(id: "silent", label: "Silent / 4-perf · 1.33 : 1", ratio: 4.0/3.0, category: .cinema),
        .init(id: "academy", label: "Academy · 1.375 : 1", ratio: 1.375, category: .cinema),
        .init(id: "imax-gt", label: "IMAX 15/70 · 1.43 : 1", ratio: 1.43, category: .cinema),
        .init(id: "euro", label: "European Widescreen · 1.66 : 1", ratio: 1.66, category: .cinema),
        .init(id: "hdtv", label: "HDTV · 1.78 : 1", ratio: 16.0/9.0, category: .cinema),
        .init(id: "flat", label: "Theatrical Flat · 1.85 : 1", ratio: 1.85, category: .cinema),
        .init(id: "imax-digital", label: "IMAX Digital Expanded · 1.90 : 1", ratio: 1.90, category: .cinema),
        .init(id: "univisium", label: "Univisium · 2.00 : 1", ratio: 2.0, category: .cinema),
        .init(id: "70mm", label: "70mm · 2.20 : 1", ratio: 2.20, category: .cinema),
        .init(id: "scope", label: "CinemaScope · 2.39 : 1", ratio: 2.39, category: .cinema),
        .init(id: "scope240", label: "Scope · 2.40 : 1", ratio: 2.40, category: .cinema),
        .init(id: "ultra", label: "Ultra Panavision · 2.76 : 1", ratio: 2.76, category: .cinema),
    ]
}

private struct Matrix3 {
    var m: [Double] // row-major 9
    static let identity = Matrix3(m: [1,0,0, 0,1,0, 0,0,1])

    static func * (lhs: Matrix3, rhs: Matrix3) -> Matrix3 {
        let l = lhs.m
        let rmat = rhs.m
        var out = [Double](repeating: 0, count: 9)
        out[0] = l[0]*rmat[0] + l[1]*rmat[3] + l[2]*rmat[6]
        out[1] = l[0]*rmat[1] + l[1]*rmat[4] + l[2]*rmat[7]
        out[2] = l[0]*rmat[2] + l[1]*rmat[5] + l[2]*rmat[8]
        out[3] = l[3]*rmat[0] + l[4]*rmat[3] + l[5]*rmat[6]
        out[4] = l[3]*rmat[1] + l[4]*rmat[4] + l[5]*rmat[7]
        out[5] = l[3]*rmat[2] + l[4]*rmat[5] + l[5]*rmat[8]
        out[6] = l[6]*rmat[0] + l[7]*rmat[3] + l[8]*rmat[6]
        out[7] = l[6]*rmat[1] + l[7]*rmat[4] + l[8]*rmat[7]
        out[8] = l[6]*rmat[2] + l[7]*rmat[5] + l[8]*rmat[8]
        return Matrix3(m: out)
    }

    func inverted() -> Matrix3? {
        let a = m[0], b = m[1], c = m[2]
        let d = m[3], e = m[4], f = m[5]
        let g = m[6], h = m[7], i = m[8]
        let A = e * i - f * h
        let B = -(d * i - f * g)
        let C = d * h - e * g
        let D = -(b * i - c * h)
        let E = a * i - c * g
        let F = -(a * h - b * g)
        let G = b * f - c * e
        let H = -(a * f - c * d)
        let I = a * e - b * d
        let det = a * A + b * B + c * C
        guard abs(det) > 1e-10 else { return nil }
        let q = 1.0 / det
        return Matrix3(m: [A*q, D*q, G*q, B*q, E*q, H*q, C*q, F*q, I*q])
    }

    func map(_ x: Double, _ y: Double) -> (Double, Double)? {
        let X=m[0]*x+m[1]*y+m[2], Y=m[3]*x+m[4]*y+m[5], W=m[6]*x+m[7]*y+m[8]
        guard abs(W) > 1e-9 else { return nil }
        return (X/W, Y/W)
    }
}

enum GeometryEngine {
    /// Map a tap on the *displayed* transformed/cropped image back into the original
    /// pre-geometry pixel domain. The forward display transform is exactly the one
    /// used in transformed(_:settings:); its inverse must be used for AI object picks.
    static func sourceNormalizedPoint(
        fromDisplay point: CGPoint,
        sourceWidth: Int,
        sourceHeight: Int,
        settings: GeometrySettings?
    ) -> CGPoint? {
        guard sourceWidth > 0, sourceHeight > 0,
              point.x.isFinite, point.y.isFinite,
              point.x >= 0, point.x <= 1, point.y >= 0, point.y <= 1 else { return nil }
        guard let settings else { return point }
        let crop = normalizedCrop(settings.crop)
        var effective = settings
        if settings.autoCrop {
            effective.scale = max(
                settings.scale,
                minimumScaleToCoverCrop(settings: settings, width: sourceWidth, height: sourceHeight)
            )
        }
        let fullW = sourceWidth, fullH = sourceHeight
        let cropX = Int((crop.x * Double(fullW)).rounded(.down))
        let cropY = Int((crop.y * Double(fullH)).rounded(.down))
        let cropW = max(1, min(fullW - cropX, Int((crop.width * Double(fullW)).rounded())))
        let cropH = max(1, min(fullH - cropY, Int((crop.height * Double(fullH)).rounded())))
        let pixelX = Double(cropX) + Double(point.x) * Double(max(0, cropW - 1))
        let pixelY = Double(cropY) + Double(point.y) * Double(max(0, cropH - 1))
        let aspect = Double(fullW) / Double(max(1, fullH))
        let nx = (pixelX / Double(max(1, fullW - 1)) - 0.5) * aspect
        let ny = pixelY / Double(max(1, fullH - 1)) - 0.5
        guard let inverse = forwardMatrix(settings: effective, width: fullW, height: fullH).inverted(),
              let mapped = inverse.map(nx, ny) else { return nil }
        let u = mapped.0 / aspect + 0.5
        let v = mapped.1 + 0.5
        guard u.isFinite, v.isFinite, u >= 0, u <= 1, v >= 0, v <= 1 else { return nil }
        return CGPoint(x: u, y: v)
    }

    static func applyAspectPreset(_ preset: CropAspectPreset, sourceWidth: Int, sourceHeight: Int, to settings: inout GeometrySettings) {
        settings.lastAspectPresetID = preset.id
        guard let r = preset.ratio else { return }
        let sourceRatio = Double(sourceWidth) / Double(max(1, sourceHeight))
        let target = r < 0 ? sourceRatio : r
        var crop = settings.crop
        let centerX = crop.x + crop.width * 0.5
        let centerY = crop.y + crop.height * 0.5
        let currentPixelRatio = (crop.width * Double(sourceWidth)) / max(1e-9, crop.height * Double(sourceHeight))
        if currentPixelRatio > target {
            crop.width = crop.height * target * Double(sourceHeight) / Double(sourceWidth)
        } else {
            crop.height = crop.width * Double(sourceWidth) / (target * Double(sourceHeight))
        }
        crop.x = centerX - crop.width * 0.5
        crop.y = centerY - crop.height * 0.5
        crop.clamp()
        settings.crop = crop
    }

    static func reset(_ settings: inout GeometrySettings) { settings = GeometrySettings() }

    static func transformed(_ input: PixelBufferF32, settings: GeometrySettings?) -> PixelBufferF32 {
        guard let settings else { return input }
        let requestedCrop = normalizedCrop(settings.crop)
        var effectiveSettings = settings
        if settings.autoCrop {
            // "Auto Fill Edges" preserves the photographer's crop and solves the minimum zoom
            // required to keep every crop corner inside the transformed source. The old
            // implementation only intersected rectangles, which could still leave black wedges.
            effectiveSettings.scale = max(
                settings.scale,
                minimumScaleToCoverCrop(settings: settings, width: input.width, height: input.height)
            )
        }
        let crop = requestedCrop
        let isIdentity = abs(effectiveSettings.rotationDegrees) < 1e-9
            && abs(effectiveSettings.verticalPerspective) < 1e-9
            && abs(effectiveSettings.horizontalPerspective) < 1e-9
            && abs(effectiveSettings.aspect) < 1e-9
            && abs(effectiveSettings.scale - 100) < 1e-9
            && abs(effectiveSettings.xOffset) < 1e-9 && abs(effectiveSettings.yOffset) < 1e-9
            && !effectiveSettings.flipHorizontal && !effectiveSettings.flipVertical
            && crop == NormalizedCropRect()
        if isIdentity { return input }

        let fullW = input.width, fullH = input.height
        guard fullW > 0, fullH > 0 else { return input }
        let cropX = Int((crop.x * Double(fullW)).rounded(.down))
        let cropY = Int((crop.y * Double(fullH)).rounded(.down))
        let cropW = max(1, min(fullW - cropX, Int((crop.width * Double(fullW)).rounded())))
        let cropH = max(1, min(fullH - cropY, Int((crop.height * Double(fullH)).rounded())))

        let matrix = Self.forwardMatrix(settings: effectiveSettings, width: fullW, height: fullH)
        guard let inverse = matrix.inverted() else { return input }
        var out = [Float](repeating: 0, count: cropW * cropH * 4)
        let aspect = Double(fullW) / Double(max(1, fullH))
        for oy in 0..<cropH {
            if (oy & 31) == 0, Task.isCancelled { return input }
            let py = cropY + oy
            let ny = Double(py) / Double(max(1, fullH - 1)) - 0.5
            for ox in 0..<cropW {
                let px = cropX + ox
                let nx = (Double(px) / Double(max(1, fullW - 1)) - 0.5) * aspect
                guard let mapped = inverse.map(nx, ny) else { continue }
                let su = mapped.0 / aspect + 0.5
                let sv = mapped.1 + 0.5
                let sx = su * Double(fullW - 1), sy = sv * Double(fullH - 1)
                let q = (oy * cropW + ox) * 4
                if sx >= 0, sx <= Double(fullW - 1), sy >= 0, sy <= Double(fullH - 1) {
                    sampleBilinear(input, x: sx, y: sy, into: &out, at: q)
                } else {
                    out[q+3] = 1
                }
            }
        }
        return PixelBufferF32(width: cropW, height: cropH, pixels: out)
    }

    static func minimumScaleToCoverCrop(settings: GeometrySettings, width: Int, height: Int) -> Double {
        guard width > 0, height > 0 else { return settings.scale }
        let crop = normalizedCrop(settings.crop)
        let aspect = Double(width) / Double(max(1, height))

        func cropIsCovered(at scale: Double) -> Bool {
            var candidate = settings
            candidate.scale = scale
            let matrix = Self.forwardMatrix(settings: candidate, width: width, height: height)
            guard let inverse = matrix.inverted() else { return false }
            let u0 = crop.x, u1 = crop.x + crop.width
            let v0 = crop.y, v1 = crop.y + crop.height
            // Homographies map straight edges to straight edges, so the four crop corners are
            // sufficient to prove the complete rectangular crop lies inside the convex source.
            for (u, v) in [(u0,v0),(u1,v0),(u1,v1),(u0,v1)] {
                let nx = (u - 0.5) * aspect
                let ny = v - 0.5
                guard let mapped = inverse.map(nx, ny) else { return false }
                let sourceU = mapped.0 / aspect + 0.5
                let sourceV = mapped.1 + 0.5
                if sourceU < -1e-6 || sourceU > 1.0 + 1e-6 || sourceV < -1e-6 || sourceV > 1.0 + 1e-6 {
                    return false
                }
            }
            return true
        }

        let starting = max(10.0, settings.scale)
        if cropIsCovered(at: starting) { return starting }

        var low = starting
        var high = max(200.0, starting)
        while high < 800.0 && !cropIsCovered(at: high) {
            low = high
            high *= 1.5
        }
        high = min(800.0, high)
        guard cropIsCovered(at: high) else { return high }

        for _ in 0..<30 {
            let mid = (low + high) * 0.5
            if cropIsCovered(at: mid) { high = mid } else { low = mid }
        }
        return high
    }

    private static func normalizedCrop(_ original: NormalizedCropRect) -> NormalizedCropRect {
        var c=original; c.clamp(); return c
    }

    private static func sampleBilinear(_ input: PixelBufferF32, x: Double, y: Double, into out: inout [Float], at q: Int) {
        let x0=max(0,min(input.width-1,Int(floor(x)))), y0=max(0,min(input.height-1,Int(floor(y))))
        let x1=min(input.width-1,x0+1), y1=min(input.height-1,y0+1)
        let tx=Float(x-Double(x0)), ty=Float(y-Double(y0))
        let i00=(y0*input.width+x0)*4, i10=(y0*input.width+x1)*4
        let i01=(y1*input.width+x0)*4, i11=(y1*input.width+x1)*4
        for c in 0..<4 {
            let a=input.pixels[i00+c]+(input.pixels[i10+c]-input.pixels[i00+c])*tx
            let b=input.pixels[i01+c]+(input.pixels[i11+c]-input.pixels[i01+c])*tx
            out[q+c]=a+(b-a)*ty
        }
    }
    private static func forwardMatrix(settings: GeometrySettings, width: Int, height: Int) -> Matrix3 {
        let angle = settings.rotationDegrees * .pi / 180
        let c = cos(angle), s = sin(angle)
        let flipX = settings.flipHorizontal ? -1.0 : 1.0
        let flipY = settings.flipVertical ? -1.0 : 1.0
        let aspectStretch = pow(2.0, settings.aspect / 200.0)
        let scale = max(0.1, settings.scale / 100.0)
        let pX = max(-100, min(100, settings.verticalPerspective)) * 0.0045
        let pY = max(-100, min(100, settings.horizontalPerspective)) * 0.0045
        let tx = settings.xOffset / 200.0
        let ty = -settings.yOffset / 200.0
        let F = Matrix3(m: [flipX,0,0, 0,flipY,0, 0,0,1])
        let R = Matrix3(m: [c,-s,0, s,c,0, 0,0,1])
        let A = Matrix3(m: [aspectStretch*scale,0,tx, 0,scale,ty, pX,pY,1])
        return A * R * F
    }

}

actor GeometryAutoAnalyzer {
    func analyze(cgImage: CGImage, mode: GeometryAutoMode) async throws -> GeometrySettings {
        try Task.checkCancellation()
        var result = GeometrySettings()
        result.autoMode = mode
        guard mode != .off && mode != .guided else { return result }

        if mode == .level || mode == .auto || mode == .full || mode == .vertical {
            let request = VNDetectHorizonRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage)
            try handler.perform([request])
            if let horizon = request.results?.first {
                result.rotationDegrees = -Double(horizon.angle) * 180.0 / .pi
            }
        }

        guard mode == .auto || mode == .vertical || mode == .full else { return result }
        let rectRequest = VNDetectRectanglesRequest()
        rectRequest.maximumObservations = 12
        rectRequest.minimumConfidence = 0.45
        rectRequest.minimumAspectRatio = 0.15
        rectRequest.maximumAspectRatio = 1.0
        let handler = VNImageRequestHandler(cgImage: cgImage)
        try handler.perform([rectRequest])
        guard let rect = rectRequest.results?.max(by: { $0.boundingBox.width*$0.boundingBox.height < $1.boundingBox.width*$1.boundingBox.height }) else {
            return result
        }

        let tl=rect.topLeft, tr=rect.topRight, bl=rect.bottomLeft, br=rect.bottomRight
        // Rectangle geometry gives a stable approximation for the Upright-style controls.
        // Values are deliberately bounded; photographers can refine them manually afterward.
        let leftLean = Double(tl.x - bl.x), rightLean = Double(tr.x - br.x)
        let topRise = Double(tr.y - tl.y), bottomRise = Double(br.y - bl.y)
        result.verticalPerspective = max(-100,min(100,(leftLean+rightLean)*240.0))
        if mode == .full || mode == .auto {
            result.horizontalPerspective = max(-100,min(100,(topRise+bottomRise)*180.0))
        }
        return result
    }
}
