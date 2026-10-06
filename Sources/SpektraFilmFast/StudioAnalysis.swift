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
    static let skinReferenceDegrees = SkinToneReference.referenceAngleDegrees
    static let scopeSize = 256
    private let subjectMaskEngine = SubjectSkinMaskEngine()


    // Independent Swift adaptation of darktable's final-view overexposure tests.
    private static func clippingFlags(
        r: Float,
        g: Float,
        b: Float,
        mode: ClippingPreviewMode,
        upper: Float,
        lower: Float
    ) -> (highlight: Bool, shadow: Bool) {
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let anyRGBUpper = r >= upper || g >= upper || b >= upper
        let allRGBLower = r <= lower && g <= lower && b <= lower
        let luminanceUpper = luminance >= upper
        let luminanceLower = luminance <= lower

        func saturationExceeded(_ channel: Float) -> Bool {
            let delta = channel - luminance
            let denom = max(1.0e-12, luminance * luminance + channel * channel)
            return sqrt((delta * delta) / denom) > upper
        }

        let saturationUpper =
            saturationExceeded(r) || saturationExceeded(g) || saturationExceeded(b)

        switch mode {
        case .anyRGB:
            return (anyRGBUpper, allRGBLower)
        case .luminance:
            return (luminanceUpper, luminanceLower)
        case .saturation:
            guard luminance < upper && luminance > lower else { return (false, false) }
            return (saturationUpper || anyRGBUpper, false)
        case .fullGamut:
            if luminanceUpper { return (true, false) }
            if luminanceLower { return (false, true) }
            if saturationUpper || anyRGBUpper { return (true, false) }
            if allRGBLower { return (false, true) }
            return (false, false)
        }
    }

    func analyze(
        output: PixelBufferF32,
        look: RenderLook,
        preferences: AppPreferences,
        maxLongEdge: Int,
        canonicalSkinMask: CanonicalSkinMaskPayload? = nil
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

        try SkinToneReference.validate(look)

        var diagnosticPixels = [Float](repeating: 0, count: sampledPixels * 4)
        var clippingLinearPixels = [Float](repeating: 0, count: sampledPixels * 4)
        for oy in 0..<overlayHeight {
            if oy & 31 == 0 { try Task.checkCancellation() }
            let y = min(height - 1, oy * analysisStep)
            for ox in 0..<overlayWidth {
                let x = min(width - 1, ox * analysisStep)
                let sourceIndex = (y * width + x) * 4
                let p = (oy * overlayWidth + ox) * 4
                guard let rgb = SkinToneReference.canonicalDisplayRGB(
                    r: output.pixels[sourceIndex],
                    g: output.pixels[sourceIndex + 1],
                    b: output.pixels[sourceIndex + 2],
                    look: look
                ),
                let linear = SkinToneReference.canonicalLinearSRGBUnclamped(
                    r: output.pixels[sourceIndex],
                    g: output.pixels[sourceIndex + 1],
                    b: output.pixels[sourceIndex + 2],
                    look: look
                ) else {
                    throw DiagnosticColorError.unsupportedOutputSpace(SkinToneReference.outputSpaceIndex(look))
                }
                diagnosticPixels[p] = rgb.0
                diagnosticPixels[p + 1] = rgb.1
                diagnosticPixels[p + 2] = rgb.2
                diagnosticPixels[p + 3] = 1
                clippingLinearPixels[p] = linear.0
                clippingLinearPixels[p + 1] = linear.1
                clippingLinearPixels[p + 2] = linear.2
                clippingLinearPixels[p + 3] = 1
            }
        }
        let diagnosticBuffer = PixelBufferF32(
            width: overlayWidth,
            height: overlayHeight,
            pixels: diagnosticPixels
        )

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
            subjectMask = try await subjectMaskEngine.subjectMask(from: diagnosticBuffer, width: overlayWidth, height: overlayHeight)
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
            for ox in 0..<overlayWidth {
                let overlayIndex = (oy * overlayWidth + ox) * 4
                let maskIndex = oy * overlayWidth + ox
                let diagnosticIndex = maskIndex * 4

                let outR = diagnosticBuffer.pixels[diagnosticIndex]
                let outG = diagnosticBuffer.pixels[diagnosticIndex + 1]
                let outB = diagnosticBuffer.pixels[diagnosticIndex + 2]

                let clipR = clippingLinearPixels[diagnosticIndex]
                let clipG = clippingLinearPixels[diagnosticIndex + 1]
                let clipB = clippingLinearPixels[diagnosticIndex + 2]
                let hardClip = Self.clippingFlags(
                    r: clipR,
                    g: clipG,
                    b: clipB,
                    mode: preferences.clippingPreviewMode,
                    upper: highlightThreshold,
                    lower: shadowThreshold
                )
                let isHardHighlight = hardClip.highlight
                let isHardShadow = hardClip.shadow

                // Preserve SpektraFilmFast's final-display early warning as a softer layer.
                let outputLuma = 0.2126 * outR + 0.7152 * outG + 0.0722 * outB
                let outputPeak = max(outR, max(outG, outB))
                let isHighlightRisk = isHardHighlight || outputPeak >= highlightRiskThreshold
                let isShadowRisk = isHardShadow || outputLuma <= shadowRiskThreshold
                if isHighlightRisk { highlightCount += 1 }
                if isShadowRisk { shadowCount += 1 }
                if isHardHighlight { hardHighlightCount += 1 }
                if isHardShadow { hardShadowCount += 1 }

                let chroma = chromaPosition(r: outR, g: outG, b: outB)
                let personConfidence = Double(subjectMask.alpha(x: ox, y: oy)) / 255.0
                let insideFace = subjectMask.isInsideFace(x: ox, y: oy)
                let skin = OpenSourceSkinClassifier.classify(
                    displayR: outR, displayG: outG, displayB: outB, inFaceRegion: insideFace
                )
                let candidate = wantsSkinAnalysis
                    && personConfidence >= (insideFace ? 0.18 : 0.42)
                    && skin.matches
                    && chroma.luma > 0.015 && chroma.luma < 0.995
                    && chroma.radius > 0.012

                if candidate {
                    let alpha = UInt8(clamping: Int((max(0.30, min(1.0, skin.confidence * personConfidence)) * 255.0).rounded()))
                    skinMask[maskIndex] = alpha
                }

                if preferences.clippingEnabled && isHardHighlight {
                    // darktable default look: solid red = over-clipped.
                    setRGBA(&overlay, overlayIndex, 255, 0, 0, 255)
                } else if preferences.clippingEnabled && isHardShadow {
                    // darktable default look: solid blue = under-clipped.
                    setRGBA(&overlay, overlayIndex, 0, 0, 255, 255)
                } else if preferences.clippingEnabled && isHighlightRisk {
                    setRGBA(&overlay, overlayIndex, 255, 0, 0, 92)
                } else if preferences.clippingEnabled && isShadowRisk {
                    setRGBA(&overlay, overlayIndex, 0, 0, 255, 92)
                }

                if wantsScope {
                    let sx = Int(((chroma.uNormalized * 0.5 + 0.5) * Float(scopeSize - 1)).rounded())
                    let sy = Int((((-chroma.vNormalized) * 0.5 + 0.5) * Float(scopeSize - 1)).rounded())
                    if sx >= 0 && sx < scopeSize && sy >= 0 && sy < scopeSize {
                        let si = sy * scopeSize + sx
                        density[si] &+= 1
                    }
                }
            }
        }

        if wantsSkinAnalysis {
            if let canonicalSkinMask {
                skinMask = canonicalSkinMask.resampled(width: overlayWidth, height: overlayHeight)
            } else {
                skinMask = refineSkinMask(
                    mask: skinMask,
                    diagnostic: diagnosticBuffer,
                    subjectMask: subjectMask,
                    width: overlayWidth,
                    height: overlayHeight
                )
            }

// The false-color overlay, percentages, centroid and skin vectorscope
              // must all use the SAME FINAL refined mask. A pre-refinement centroid
            // could previously report On Target while the visible skin overlay was
            // clearly split between green-side and magenta-side regions.
            skinCount = 0
            skinWeightSum = 0
            skinWithinWeight = 0
            skinMagentaWeight = 0
            skinGreenWeight = 0
            skinCbWeightedSum = 0
            skinCrWeightedSum = 0
            skinDensity = [UInt32](repeating: 0, count: scopeSize * scopeSize)
            skinDeviationByBin = [Double](repeating: 0, count: scopeSize * scopeSize)

            for i in 0..<sampledPixels {
                let maskStrength = Double(skinMask[i]) / 255.0
                guard maskStrength > 0.06 else { continue }

                let p = i * 4
                let r = diagnosticBuffer.pixels[p]
                let g = diagnosticBuffer.pixels[p + 1]
                let b = diagnosticBuffer.pixels[p + 2]
                let chroma = chromaPosition(r: r, g: g, b: b)

                guard chroma.luma > 0.01,
                      chroma.luma < 0.995,
                      chroma.radius > 0.008 else { continue }

                skinCount += 1
                let deviation = angularDifferenceDegrees(
                    chroma.angleDegrees,
                    Self.skinReferenceDegrees
                )
                let chromaWeight =
                    0.65 + 0.35 * min(1.0, Double(chroma.radius) / 0.18)
                let weight = max(0.01, maskStrength * chromaWeight)

                skinWeightSum += weight
                skinCbWeightedSum += Double(chroma.uNormalized) * weight
                skinCrWeightedSum += Double(chroma.vNormalized) * weight

                if abs(deviation) <= tolerance {
                    skinWithinWeight += weight
                } else if deviation < 0 {
                    skinMagentaWeight += weight
                } else {
                    skinGreenWeight += weight
                }

                if wantsScope {
                    let sx = Int(
                        ((chroma.uNormalized * 0.5 + 0.5) *
                         Float(scopeSize - 1)).rounded()
                    )
                    let sy = Int(
                        (((-chroma.vNormalized) * 0.5 + 0.5) *
                         Float(scopeSize - 1)).rounded()
                    )
                    if sx >= 0 && sx < scopeSize && sy >= 0 && sy < scopeSize {
                        let si = sy * scopeSize + sx
                        skinDensity[si] &+= 1
                        skinDeviationByBin[si] += deviation
                    }
                }
            }
        }

        if wantsSkinOverlay {
            paintSkinDirectionOverlay(
                mask: skinMask,
                diagnostic: diagnosticBuffer,
                overlay: &overlay,
                width: overlayWidth,
                height: overlayHeight,
                tolerance: tolerance,
                opacity: baseSkinOpacity,
                preserveExistingOverlay: preferences.clippingEnabled
            )
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

    private func chromaPosition(r: Float, g: Float, b: Float) -> SkinChromaPosition {
        SkinToneReference.position(displayR: r, displayG: g, displayB: b)
    }

    private func angularDifferenceDegrees(_ lhs: Double, _ rhs: Double) -> Double {
        SkinToneReference.angularDifferenceDegrees(lhs, rhs)
    }


    /// Primera Skin-inspired spatial pooling / soft-union for a cleaner, more robust mask.
    private func refineSkinMask(
        mask: [UInt8],
        diagnostic: PixelBufferF32,
        subjectMask: SubjectMaskPayload,
        width: Int,
        height: Int
    ) -> [UInt8] {
        guard width > 2, height > 2, mask.count == width * height else { return mask }
        var refined = mask
        let radius = max(1, min(3, max(width, height) / 500))
        let offsets = [
            (-radius, 0), (radius, 0), (0, -radius), (0, radius),
            (-radius, -radius), (radius, -radius), (-radius, radius), (radius, radius)
        ]
        let sigmaChroma = 0.060
        let inv2SigmaChroma2 = 1.0 / (2.0 * sigmaChroma * sigmaChroma)

        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let own = Double(mask[i]) / 255.0
                let person = Double(subjectMask.alpha(x: x, y: y)) / 255.0
                let inFace = subjectMask.isInsideFace(x: x, y: y)
                if person < (inFace ? 0.08 : 0.22) {
                    refined[i] = 0
                    continue
                }

                let p = i * 4
                let r = Double(diagnostic.pixels[p])
                let g = Double(diagnostic.pixels[p + 1])
                let b = Double(diagnostic.pixels[p + 2])
                let sum = r + g + b
                if sum < 0.01 {
                    refined[i] = mask[i]
                    continue
                }

                let gn = g / sum
                let dn = (r - b) / sum
                var weightedMask = own
                var weightSum = 1.0

                for (dx, dy) in offsets {
                    let sx = min(width - 1, max(0, x + dx))
                    let sy = min(height - 1, max(0, y + dy))
                    let si = sy * width + sx
                    let sp = si * 4
                    let sr = Double(diagnostic.pixels[sp])
                    let sg = Double(diagnostic.pixels[sp + 1])
                    let sb = Double(diagnostic.pixels[sp + 2])
                    let ssum = sr + sg + sb
                    if ssum < 0.01 { continue }

                    let sgn = sg / ssum
                    let sdn = (sr - sb) / ssum
                    let dgn = sgn - gn
                    let ddn = sdn - dn
                    let similarity = exp(-(dgn * dgn + ddn * ddn) * inv2SigmaChroma2)
                    let neighborPerson = Double(subjectMask.alpha(x: sx, y: sy)) / 255.0
                    let w = similarity * max(0.0, min(1.0, neighborPerson * 1.35))
                    weightSum += w
                    weightedMask += w * (Double(mask[si]) / 255.0)
                }

                let pooled = weightedMask / max(1.0e-9, weightSum)
                var union = 1.0 - (1.0 - own) * (1.0 - pooled)

                if own < 0.10 && pooled < (inFace ? 0.10 : 0.18) {
                    union = 0
                } else if inFace && pooled > 0.12 {
                    union = max(union, min(1.0, pooled * 1.15))
                }

                refined[i] = UInt8(clamping: Int((max(0.0, min(1.0, union)) * 255.0).rounded()))
            }
        }
        return refined
    }

    /// Local three-zone false-color readout:
    /// cyan/green = too green, gold = on target, magenta = too magenta.
    private func paintSkinDirectionOverlay(
        mask: [UInt8],
        diagnostic: PixelBufferF32,
        overlay: inout [UInt8],
        width: Int,
        height: Int,
        tolerance: Double,
        opacity: Double,
        preserveExistingOverlay: Bool
    ) {
        guard mask.count == width * height, overlay.count == width * height * 4 else { return }
        let visibleOpacity = max(0.38, min(0.90, opacity))

        for i in 0..<(width * height) {
            let strength = Double(mask[i]) / 255.0
            guard strength > 0.06 else { continue }

            let p = i * 4
            if preserveExistingOverlay && overlay[p + 3] > 0 { continue }

            let r = diagnostic.pixels[p]
            let g = diagnostic.pixels[p + 1]
            let b = diagnostic.pixels[p + 2]
            let chroma = chromaPosition(r: r, g: g, b: b)
            guard chroma.luma > 0.01, chroma.luma < 0.995, chroma.radius > 0.008 else { continue }

            let deviation = angularDifferenceDegrees(chroma.angleDegrees, Self.skinReferenceDegrees)
            let excess = max(0.0, abs(deviation) - tolerance)
            let severity = min(1.0, excess / max(10.0, tolerance * 1.75))

            let rr: UInt8
            let gg: UInt8
            let bb: UInt8
            let alphaScale: Double

            if deviation > tolerance {
                rr = 44; gg = 214; bb = 174
                alphaScale = 0.62 + 0.38 * severity
            } else if deviation < -tolerance {
                rr = 229; gg = 65; bb = 177
                alphaScale = 0.62 + 0.38 * severity
            } else {
                rr = 238; gg = 184; bb = 72
                alphaScale = 0.34
            }

            let alpha = UInt8(clamping: Int(
                (255.0 * visibleOpacity * alphaScale * sqrt(strength)).rounded()
            ))
            setRGBA(
                &overlay,
                p,
                rr, gg, bb,
                max(alpha, deviation > tolerance || deviation < -tolerance ? 74 : 36)
            )
        }
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
                    // Keep the edge subtle so the directional false color stays readable.
                    blendRGBA(&overlay, p, 255, 255, 255, 42)
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
                if d < -tolerance { out[p] = 229; out[p+1] = 65; out[p+2] = 177 }
                else if d > tolerance { out[p] = 44; out[p+1] = 214; out[p+2] = 174 }
                else { out[p] = 238; out[p+1] = 184; out[p+2] = 72 }
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
