import Foundation
import CoreGraphics

struct StudioAnalysisPayload: Sendable {
    var overlayWidth: Int
    var overlayHeight: Int
    var overlayRGBA: [UInt8]
    var scopeWidth: Int
    var scopeHeight: Int
    var scopeRGBA: [UInt8]
    var skinMaskWidth: Int
    var skinMaskHeight: Int
    var skinMaskAlpha: [UInt8]
    var metrics: StudioAnalysisMetrics
}

actor StudioAnalysisEngine {
    static let skinReferenceDegrees = 123.0
    static let scopeSize = 256
    private let subjectMaskEngine = SubjectSkinMaskEngine()

    func analyze(
        output: PixelBufferF32,
        preferences: AppPreferences,
        maxLongEdge: Int
    ) async throws -> StudioAnalysisPayload {
        try Task.checkCancellation()

        let width = output.width
        let height = output.height
        guard width > 0, height > 0 else {
            return StudioAnalysisPayload(
                overlayWidth: 0, overlayHeight: 0, overlayRGBA: [],
                scopeWidth: 0, scopeHeight: 0, scopeRGBA: [],
                skinMaskWidth: 0, skinMaskHeight: 0, skinMaskAlpha: [],
                metrics: StudioAnalysisMetrics()
            )
        }

        let analysisStep = max(1, Int(ceil(Double(max(width, height)) / Double(max(320, maxLongEdge)))))
        let overlayWidth = (width + analysisStep - 1) / analysisStep
        let overlayHeight = (height + analysisStep - 1) / analysisStep
        let sampledPixels = max(1, overlayWidth * overlayHeight)

        let wantsSkinOverlay = preferences.skinCheckEnabled && (preferences.skinCheckMode == .overlay || preferences.skinCheckMode == .both)
        let wantsScope = preferences.skinCheckEnabled && (preferences.skinCheckMode == .scope || preferences.skinCheckMode == .both)
        let wantsSkinAnalysis = preferences.skinCheckEnabled || preferences.scopeMode == .skinVectorscope
        let wantsImageOverlay = preferences.clippingEnabled || wantsSkinOverlay
        var overlay = wantsImageOverlay ? [UInt8](repeating: 0, count: sampledPixels * 4) : []
        var skinMask = [UInt8](repeating: 0, count: sampledPixels)

        // Subject isolation is performed before skin color classification. This prevents warm
        // wood, walls, flowers and clothing from polluting the skin vectorscope in portrait and event work.
        let subjectMask: SubjectMaskPayload
        if wantsSkinAnalysis {
            subjectMask = try await subjectMaskEngine.subjectMask(from: output, width: overlayWidth, height: overlayHeight)
        } else {
            subjectMask = .empty(width: overlayWidth, height: overlayHeight)
        }

        let scopeSize = Self.scopeSize
        var density = [UInt32](repeating: 0, count: scopeSize * scopeSize)
        var skinDensity = [UInt32](repeating: 0, count: scopeSize * scopeSize)
        var skinDeviationByBin = [Double](repeating: 0, count: scopeSize * scopeSize)

        var highlightCount = 0
        var shadowCount = 0
        var hardHighlightCount = 0
        var hardShadowCount = 0
        var skinCount = 0
        var skinWeightSum = 0.0
        var skinWithinWeight = 0.0
        var skinMagentaWeight = 0.0
        var skinGreenWeight = 0.0
        var skinCbWeightedSum = 0.0
        var skinCrWeightedSum = 0.0

        let highlightRiskThreshold = Float(min(0.995, max(0.50, preferences.exposureHighlightRiskThreshold)))
        let shadowRiskThreshold = Float(min(0.25, max(0.001, preferences.exposureShadowRiskThreshold)))
        let highlightThreshold = Float(min(1.0, max(Double(highlightRiskThreshold), preferences.clippingHighlightThreshold)))
        let shadowThreshold = Float(min(Double(shadowRiskThreshold), max(0.0, preferences.clippingShadowThreshold)))
        let tolerance = min(45.0, max(1.0, preferences.skinToleranceDegrees))
        let baseSkinOpacity = min(0.85, max(0.05, preferences.skinOverlayOpacity))

        for oy in 0..<overlayHeight {
            if oy & 31 == 0 { try Task.checkCancellation() }
            let y = min(height - 1, oy * analysisStep)
            for ox in 0..<overlayWidth {
                let x = min(width - 1, ox * analysisStep)
                let sourceIndex = (y * width + x) * 4
                let overlayIndex = (oy * overlayWidth + ox) * 4
                let maskIndex = oy * overlayWidth + ox

                let outRRaw = output.pixels[sourceIndex]
                let outGRaw = output.pixels[sourceIndex + 1]
                let outBRaw = output.pixels[sourceIndex + 2]
                let outR = clamp01(outRRaw)
                let outG = clamp01(outGRaw)
                let outB = clamp01(outBRaw)

                // Diagnostics intentionally analyze only the final rendered image. This is the
                // post-WB, post-tone/curve, post-SpektraFilm, post-geometry buffer that the viewer
                // presents. Film stock/print contrast and every other visible edit therefore
                // participate in Exposure Warning and Skin analysis.
                let outputLuma = linearLuma(outRRaw, outGRaw, outBRaw)
                let outputPeak = max(outRRaw, max(outGRaw, outBRaw))
                let isHardHighlight = outputPeak >= highlightThreshold
                let isHardShadow = outputLuma <= shadowThreshold
                let isHighlightRisk = isHardHighlight || outputPeak >= highlightRiskThreshold
                let isShadowRisk = isHardShadow || outputLuma <= shadowRiskThreshold
                if isHighlightRisk { highlightCount += 1 }
                if isShadowRisk { shadowCount += 1 }
                if isHardHighlight { hardHighlightCount += 1 }
                if isHardShadow { hardShadowCount += 1 }

                let chroma = chromaPosition(r: outR, g: outG, b: outB)
                let deviation = angularDifferenceDegrees(chroma.angleDegrees, Self.skinReferenceDegrees)
                let personConfidence = Double(subjectMask.alpha(x: ox, y: oy)) / 255.0
                let insideFace = subjectMask.isInsideFace(x: ox, y: oy)
                let skin = OpenSourceSkinClassifier.classify(
                    linearR: outR, linearG: outG, linearB: outB, inFaceRegion: insideFace
                )
                let candidate = wantsSkinAnalysis
                    && personConfidence >= (insideFace ? 0.18 : 0.42)
                    && skin.matches
                    && chroma.luma > 0.015 && chroma.luma < 0.995
                    && chroma.radius > 0.012

                if candidate {
                    let alpha = UInt8(clamping: Int((max(0.30, min(1.0, skin.confidence * personConfidence)) * 255.0).rounded()))
                    skinMask[maskIndex] = alpha
                    skinCount += 1

                    // Confidence-weighted chroma centroid: strong subject/skin matches count more
                    // than weak edge pixels, while very low-chroma candidates are gently downweighted.
                    // This makes the global Too Green / On Target / Too Magenta result much more stable
                    // across hairlines, lips, shadows, mixed light and partially occluded faces.
                    let chromaWeight = 0.65 + 0.35 * min(1.0, Double(chroma.radius) / 0.18)
                    let weight = max(0.02, skin.confidence * personConfidence * chromaWeight)
                    skinWeightSum += weight
                    skinCbWeightedSum += Double(chroma.cbNormalized) * weight
                    skinCrWeightedSum += Double(chroma.crNormalized) * weight
                    if abs(deviation) <= tolerance { skinWithinWeight += weight }
                    else if deviation < 0 { skinMagentaWeight += weight }
                    else { skinGreenWeight += weight }
                }

                if preferences.clippingEnabled && isHardHighlight {
                    // Hard highlight clipping: strong red.
                    setRGBA(&overlay, overlayIndex, 236, 66, 74, 226)
                } else if preferences.clippingEnabled && isHardShadow {
                    // Hard shadow clipping/crush: strong blue.
                    setRGBA(&overlay, overlayIndex, 57, 91, 232, 226)
                } else if preferences.clippingEnabled && isHighlightRisk {
                    // Highlight risk before mathematical clipping.
                    setRGBA(&overlay, overlayIndex, 238, 156, 67, 132)
                } else if preferences.clippingEnabled && isShadowRisk {
                    // Shadow risk before mathematical zero. This catches visibly underexposed
                    // regions while there is still recoverable tonal information.
                    setRGBA(&overlay, overlayIndex, 68, 144, 205, 132)
                } else if wantsSkinOverlay && candidate {
                    // Restrained grading overlay: preserve facial detail and signal direction
                    // without the neon false-color blanket used by the old implementation.
                    let excess = max(0.0, abs(deviation) - tolerance)
                    let severity = min(1.0, excess / 28.0)
                    let alpha = UInt8(clamping: Int((baseSkinOpacity * (0.18 + 0.44 * severity) * 255.0).rounded()))
                    if deviation < -tolerance {
                        setRGBA(&overlay, overlayIndex, 196, 94, 120, max(alpha, 34)) // muted rose
                    } else if deviation > tolerance {
                        setRGBA(&overlay, overlayIndex, 74, 150, 142, max(alpha, 34)) // muted teal
                    } else {
                        setRGBA(&overlay, overlayIndex, 204, 158, 102, UInt8(clamping: Int(baseSkinOpacity * 52.0)))
                    }
                }

                if wantsScope {
                    let sx = Int(((chroma.cbNormalized * 0.5 + 0.5) * Float(scopeSize - 1)).rounded())
                    let sy = Int((((-chroma.crNormalized) * 0.5 + 0.5) * Float(scopeSize - 1)).rounded())
                    if sx >= 0 && sx < scopeSize && sy >= 0 && sy < scopeSize {
                        let si = sy * scopeSize + sx
                        density[si] &+= 1
                        if candidate {
                            skinDensity[si] &+= 1
                            skinDeviationByBin[si] += deviation
                        }
                    }
                }
            }
        }

        if wantsSkinOverlay {
            drawSkinBoundary(mask: skinMask, overlay: &overlay, width: overlayWidth, height: overlayHeight)
        }

        let scope = wantsScope ? makeScopeRGBA(
            density: density,
            skinDensity: skinDensity,
            skinDeviationByBin: skinDeviationByBin,
            tolerance: tolerance,
            size: scopeSize
        ) : []
        let centroidCb = skinWeightSum > 0 ? skinCbWeightedSum / skinWeightSum : 0.0
        let centroidCr = skinWeightSum > 0 ? skinCrWeightedSum / skinWeightSum : 0.0
        let centroidRadius = hypot(centroidCb, centroidCr)
        var centroidAngle = atan2(centroidCr, centroidCb) * 180.0 / .pi
        if centroidAngle < 0 { centroidAngle += 360.0 }
        let centroidDeviation = skinWeightSum > 0
            ? angularDifferenceDegrees(centroidAngle, Self.skinReferenceDegrees)
            : 0.0
        let weightedDenominator = max(1.0e-9, skinWeightSum)
        let metrics = StudioAnalysisMetrics(
            highlightPercent: Double(highlightCount) * 100.0 / Double(sampledPixels),
            shadowPercent: Double(shadowCount) * 100.0 / Double(sampledPixels),
            hardHighlightPercent: Double(hardHighlightCount) * 100.0 / Double(sampledPixels),
            hardShadowPercent: Double(hardShadowCount) * 100.0 / Double(sampledPixels),
            skinCandidatePercent: Double(skinCount) * 100.0 / Double(sampledPixels),
            skinMeanDeviationDegrees: centroidDeviation,
            skinWithinTolerancePercent: skinWithinWeight * 100.0 / weightedDenominator,
            skinMagentaPercent: skinMagentaWeight * 100.0 / weightedDenominator,
            skinGreenPercent: skinGreenWeight * 100.0 / weightedDenominator,
            skinMeanCbNormalized: centroidCb,
            skinMeanCrNormalized: centroidCr,
            skinMeanRadius: centroidRadius,
            skinMeasurementConfidencePercent: min(100.0, skinWeightSum * 100.0 / Double(max(1, skinCount))),
            sampledPixels: sampledPixels
        )

        return StudioAnalysisPayload(
            overlayWidth: wantsImageOverlay ? overlayWidth : 0,
            overlayHeight: wantsImageOverlay ? overlayHeight : 0,
            overlayRGBA: overlay,
            scopeWidth: wantsScope ? scopeSize : 0,
            scopeHeight: wantsScope ? scopeSize : 0,
            scopeRGBA: scope,
            skinMaskWidth: overlayWidth,
            skinMaskHeight: overlayHeight,
            skinMaskAlpha: skinMask,
            metrics: metrics
        )
    }

    private struct ChromaPosition {
        var cbNormalized: Float
        var crNormalized: Float
        var radius: Float
        var angleDegrees: Double
        var luma: Float
    }

    private func chromaPosition(r: Float, g: Float, b: Float) -> ChromaPosition {
        let kr: Float = 0.2126, kb: Float = 0.0722, kg: Float = 0.7152
        let y = kr * r + kg * g + kb * b
        let cb = (b - y) / (2.0 * (1.0 - kb))
        let cr = (r - y) / (2.0 * (1.0 - kr))
        let cbn = max(-1.0, min(1.0, cb * 2.0))
        let crn = max(-1.0, min(1.0, cr * 2.0))
        let radius = sqrt(cbn * cbn + crn * crn)
        var angle = atan2(Double(crn), Double(cbn)) * 180.0 / .pi
        if angle < 0 { angle += 360.0 }
        return ChromaPosition(cbNormalized: cbn, crNormalized: crn, radius: radius, angleDegrees: angle, luma: y)
    }

    private func linearLuma(_ r: Float, _ g: Float, _ b: Float) -> Float { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    private func angularDifferenceDegrees(_ lhs: Double, _ rhs: Double) -> Double {
        var delta = lhs - rhs
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }
        return delta
    }

    private func drawSkinBoundary(mask: [UInt8], overlay: inout [UInt8], width: Int, height: Int) {
        guard width > 2, height > 2, overlay.count == width * height * 4 else { return }
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                guard mask[i] > 80 else { continue }
                let edge = mask[i - 1] <= 80 || mask[i + 1] <= 80 || mask[i - width] <= 80 || mask[i + width] <= 80
                if edge {
                    let p = i * 4
                    // Soft champagne outline that reads as a professional mask edge.
                    blendRGBA(&overlay, p, 220, 190, 146, 92)
                }
            }
        }
    }

    private func makeScopeRGBA(
        density: [UInt32], skinDensity: [UInt32], skinDeviationByBin: [Double],
        tolerance: Double, size: Int
    ) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: size * size * 4)
        let maximum = max(1, density.max() ?? 1)
        let logMax = log1p(Double(maximum))
        for i in density.indices where density[i] > 0 {
            let normalized = log1p(Double(density[i])) / logMax
            let alpha = UInt8(clamping: Int((34.0 + normalized * 176.0).rounded()))
            let p = i * 4
            if skinDensity[i] > 0 {
                let d = skinDeviationByBin[i] / Double(skinDensity[i])
                if d < -tolerance { out[p] = 196; out[p+1] = 94; out[p+2] = 120 }
                else if d > tolerance { out[p] = 74; out[p+1] = 150; out[p+2] = 142 }
                else { out[p] = 220; out[p+1] = 176; out[p+2] = 112 }
                out[p+3] = max(alpha, 118)
            } else {
                out[p] = 154; out[p+1] = 174; out[p+2] = 196; out[p+3] = alpha
            }
        }
        return out
    }

    private func clamp01(_ value: Float) -> Float { max(0, min(1, value)) }

    private func setRGBA(_ bytes: inout [UInt8], _ p: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) {
        guard p + 3 < bytes.count else { return }
        bytes[p] = r; bytes[p+1] = g; bytes[p+2] = b; bytes[p+3] = a
    }

    private func blendRGBA(_ bytes: inout [UInt8], _ p: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) {
        guard p + 3 < bytes.count else { return }
        let af = Double(a) / 255.0, inv = 1.0 - af
        bytes[p] = UInt8(clamping: Int(Double(bytes[p]) * inv + Double(r) * af))
        bytes[p+1] = UInt8(clamping: Int(Double(bytes[p+1]) * inv + Double(g) * af))
        bytes[p+2] = UInt8(clamping: Int(Double(bytes[p+2]) * inv + Double(b) * af))
        bytes[p+3] = max(bytes[p+3], a)
    }
}

extension CGImage {
    static func fromRGBA8(width: Int, height: Int, bytes: [UInt8], colorSpace: CGColorSpace? = nil) -> CGImage? {
        guard width > 0, height > 0, bytes.count == width * height * 4,
              let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        let space = colorSpace ?? (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
