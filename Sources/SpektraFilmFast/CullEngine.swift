import CoreGraphics
import Foundation
import Vision
import MetalKit

struct DetectedFace: Sendable {
    var bounds: CGRect
    var rightEye: CGPoint
    var leftEye: CGPoint
    var nose: CGPoint
    var rightMouth: CGPoint
    var leftMouth: CGPoint
    var confidence: Double
}

// MARK: - Facet-style technical metrics ported from ncoevoet/facet
// analyzers/technical.py: sharpness (Laplacian variance), exposure (clipping),
// color harmony (HSV entropy), dynamic range (p2/p98 stops), noise (Immerkaer),
// contrast (percentile + RMS).

// MARK: - Facet-style composition metrics ported from ncoevoet/facet
// analyzers/composition.py: subject-region detection (edge contour + saliency),
// rule-of-thirds placement score, leading-lines detection (Hough-like).

extension CullEngine {
    /// Laplacian-variance sharpness normalized to 0-1, matching Facet's
    /// ``TechnicalAnalyzer.get_sharpness_score`` (variance / 50, capped at 10)
    /// then rescaled to our 0-1 range for score blending.
    private static func facetSharpness(laplacianVariance: Double) -> Double {
        // Facet: min(10.0, variance / 50.0)  -> 0-10 scale
        // We map 10 -> 1.0, and treat >= 500 variance as "perfectly sharp"
        // (Laplacian variance of a crisp 8-bit photo routinely exceeds 500).
        let raw = min(10.0, laplacianVariance / 50.0)
        return raw / 10.0
    }

    /// Facet-style color harmony from HSV hue/sat entropy.
    /// Mirrors ``TechnicalAnalyzer.get_color_harmony``: 180x256 hue/sat histogram,
    /// Shannon entropy, scaled so 15.5 bits -> 10.0.
    /// Uses step-based subsampling for performance; color harmony at thumbnail scale
    /// does not require full-resolution sampling.
    private static func facetColorHarmony(rgba: [UInt8], width: Int, height: Int) -> Double {
        precondition(width > 0 && height > 0)
        let binH = 180, binS = 256
        var hist = [Double](repeating: 0, count: binH * binS)
        // Subsample for performance: target ~250K pixels max (step=2 at 1080p = ~270K)
        let step = max(1, (width * height) / 250_000)
        var sampled = 0
        for py in stride(from: 0, to: height, by: step) {
            for px in stride(from: 0, to: width, by: step) {
                let idx = (py * width + px) * 4
                let r = Double(rgba[idx]) / 255.0
                let g = Double(rgba[idx + 1]) / 255.0
                let b = Double(rgba[idx + 2]) / 255.0
                // RGB -> HSV (Facet uses OpenCV cvtColor BGR->HSV then H/S bins)
                let mx = max(r, g, b), mn = min(r, g, b)
                let d = mx - mn
                let s = mx > 0 ? d / mx : 0
                var h2: Double
                if d == 0 { h2 = 0 }
                else if mx == r { h2 = ((g - b) / d).truncatingRemainder(dividingBy: 6) + (g < b ? 6 : 0) }
                else if mx == g { h2 = ((b - r) / d) + 2 }
                else { h2 = ((r - g) / d) + 4 }
                h2 *= 60
                if h2 < 0 { h2 += 360 }
                let hi = Int(h2 / 360.0 * Double(binH)).clamped(to: 0..<binH)
                let si = Int(s * 255).clamped(to: 0..<binS)
                hist[hi * binS + si] += 1
                sampled += 1
            }
        }
        guard sampled > 0 else { return 0 }
        var sum = 0.0
        for v in hist { sum += v }
        guard sum > 0 else { return 0 }
        var entropy = 0.0
        for v in hist {
            let p = v / sum
            if p > 0 { entropy -= p * log2(p) }
        }
        // Facet caps at 15.5 bits max entropy for 180*256 bins
        let normalized = min(10.0, entropy * 10.0 / 15.5)
        return normalized / 10.0
    }

    /// Facet-style dynamic range: log2(p98 / max(p2, 1)) on grayscale.
    /// Mirrors ``TechnicalAnalyzer.get_dynamic_range``.
    /// Uses histogram-based percentile for O(n) instead of O(n log n) sort.
    private static func facetDynamicRange(luma: [Double], count: Int) -> Double {
        guard count > 0 else { return 0 }
        // Use histogram with 16384 bins for percentile estimation (same as AutoContrastMath)
        let bins = 16384
        var histogram = [Int](repeating: 0, count: bins)
        for v in luma {
            let clamped = max(0.0, min(1.0, v / 255.0))
            let idx = min(bins - 1, Int(clamped * Double(bins - 1)).clamped(to: 0..<bins))
            histogram[idx] += 1
        }
        let total = count
        // Find p2 (2nd percentile)
        var p2: Double = 0
        {
            var cumulative = 0
            let target = Int(Double(total) * 0.02)
            for (i, count) in histogram.enumerated() {
                cumulative += count
                if cumulative >= target {
                    p2 = Double(i) / Double(bins - 1) * 255.0
                    break
                }
            }
        }()
        // Find p98 (98th percentile)
        var p98: Double = 255.0
        {
            var cumulative = 0
            let target = Int(Double(total) * 0.98)
            for (i, count) in histogram.enumerated() {
                cumulative += count
                if cumulative >= target {
                    p98 = Double(i) / Double(bins - 1) * 255.0
                    break
                }
            }
        }()
        let base = max(p2, 1.0)
        return log2(max(p98, 1.0) / base)
    }

    /// Facet-style Immerkaer noise estimation on grayscale.
    /// Mirrors ``TechnicalAnalyzer.get_noise_estimate``.
    /// Uses subsampling for performance; noise at thumbnail scale is adequately
    /// estimated at reduced resolution.
    private static func facetNoiseEstimate(luma: [Double], width: Int, height: Int) -> Double {
        guard width > 2 && height > 2 else { return 0 }
        let M: [Int] = [-1, 2, -1, 2, -4, 2, -1, 2, -1] // 3x3 Immerkaer kernel
        // Subsample for performance: step of 2 gives 1/4 pixels, sufficient for noise est
        let step = 2
        var sigma = 0.0
        var count = 0.0
        for py in stride(from: 1, to: height - 1, by: step) {
            for px in stride(from: 1, to: width - 1, by: step) {
                let i = py * width + px
                var ksum = 0.0
                ksum += Double(M[0]) * luma[i - width - 1]
                ksum += Double(M[1]) * luma[i - width]
                ksum += Double(M[2]) * luma[i - width + 1]
                ksum += Double(M[3]) * luma[i - 1]
                ksum += Double(M[4]) * luma[i]
                ksum += Double(M[5]) * luma[i + 1]
                ksum += Double(M[6]) * luma[i + width - 1]
                ksum += Double(M[7]) * luma[i + width]
                ksum += Double(M[8]) * luma[i + width + 1]
                sigma += abs(ksum)
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        // Scale back to full-resolution equivalent
        let scale = Double(step * step)
        let w = Double(width - 2), h = Double(height - 2)
        let noise = sigma * sqrt(0.5 * .pi) / (6.0 * w * h) * scale
        return noise
    }

    /// Facet-style contrast: percentile (p5/p95) + RMS, from
    /// ``TechnicalAnalyzer.get_contrast_score``.
    private static func facetContrast(luma: [Double], count: Int) -> Double {
        guard count > 0 else { return 0 }
        let sorted = luma.sorted()
        let p5 = percentile(sorted, p: 0.05)
        let p95 = percentile(sorted, p: 0.95)
        let percentileContrast = (p95 - p5) / 255.0
        // RMS: std dev / 255
        let mean = luma.reduce(0, +) / Double(count)
        var varSum = 0.0
        for v in luma { varSum += (v - mean) * (v - mean) }
        let rms = sqrt(varSum / Double(count)) / 255.0
        // Facet: min(10, percentile*5 + rms*20)
        return min(10.0, percentileContrast * 5.0 + rms * 20.0) / 10.0
    }

    /// Percentile of sorted values.
    private static func percentile(_ sorted: [Double], p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let idx = (Double(sorted.count - 1) * p).rounded(.toNearestOrEven)
        let i = Int(idx).clamped(to: 0..<sorted.count)
        return sorted[i]
    }
}

extension Int {
    func clamped(to range: Range<Int>) -> Int {
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound - 1)
    }
}

extension Double {
    func clamped(to range: Range<Double>) -> Double {
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

actor CullEngine {

    struct Result: Sendable {
        let record: CullAnalysisRecord
    }

    func analyze(_ payload: ThumbnailPayload) async throws -> Result {
        try Task.checkCancellation()
        async let technicalTask = Task.detached(priority: .utility) {
            (Self.imageMetrics(payload), Self.dHash(payload))
        }.value
        let (metrics, hash) = await technicalTask
        let faces = Self.detectFacesVision(payload)
        let face = Self.faceMetrics(payload, faces: faces)
        // Additional trained on-device Vision face-quality model, rather than
        // judging expressions from two guessed eye rectangles alone.
        let faceCaptureQuality = Self.faceCaptureQuality(payload)
        // Learned on-device scene aesthetics, independent of technical sharpness.
        let aestheticScore = Self.aestheticQuality(payload)

        // Facet-style supplementary metrics (computed on the same downsample).
        let (colorHarmony, dynamicRange, noiseEstimateFacet, contrastFacet) = await Task.detached(priority: .utility) {
            Self.facetSupplementaryMetrics(payload)
        }.value

        // Facet-style composition analysis.
        let subjectRegion = Self.detectSubjectRegion(payload)
        let (compScore, _, _, _) = Self.placementScore(
            region: subjectRegion, imgW: payload.width, imgH: payload.height)
        let (leadingLinesScore, _) = Self.detectLeadingLines(payload)
        let integratedComp = Self.integrateLeadingLines(
            baseScore: compScore, leadingLinesScore: leadingLinesScore, hasFaces: face.count > 0)

        return try await Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let focus = face.count > 0 ? (metrics.sharpness * 0.45 + face.sharpness * 0.55) : metrics.sharpness
            let exposure = max(0, min(1, 1.0 - (metrics.highlightClip * 2.2 + metrics.shadowClip * 1.25)))
            let noiseQuality = max(0, min(1, 1.0 - metrics.noise * 1.8))
            let contrastQuality = max(0, min(1, metrics.contrast * 1.7))
            var score = (focus * 52.0) + (exposure * 22.0) + (noiseQuality * 12.0) + (contrastQuality * 14.0)
            if face.count > 0, face.sharpness < 0.28 { score -= 18 }
            if face.possibleBlink { score -= 12 }
            if let faceCaptureQuality, face.count > 0 {
                // Vision quality offers independent portrait/burst evidence.
                // Low-quality portraits are demoted, never auto-deleted.
                score += (faceCaptureQuality - 0.5) * 22
            }
            if let aestheticScore {
                // Aesthetics never auto-deletes creative photographs.
                score += max(-1, min(1, aestheticScore)) * 16
            }
            score = max(0, min(100, score))

            var reasons: [String] = []
            if focus >= 0.72 {
                reasons.append("Strong subject focus")
            } else if focus < 0.32 {
                reasons.append("Soft focus")
            }
            if metrics.highlightClip > 0.025 { reasons.append("Heavy highlight clipping") }
            if metrics.shadowClip > 0.20 { reasons.append("Deep shadow clipping") }
            if face.count > 0 { reasons.append("\(face.count) face\(face.count == 1 ? "" : "s") detected") }
            if face.possibleBlink { reasons.append("Possible blink") }
            if let faceCaptureQuality, face.count > 0 {
                reasons.append(
                    faceCaptureQuality >= 0.65
                        ? "Strong Vision face capture"
                        : (faceCaptureQuality < 0.35 ? "Weak Vision face capture" : "Moderate Vision face capture"))
            }
            if let aestheticScore {
                reasons.append(
                    aestheticScore >= 0.30
                        ? "Strong aesthetic composition"
                        : (aestheticScore < -0.30 ? "Lower aesthetic model score" : "Moderate aesthetic model score"))
            }
            if metrics.noise > 0.42 { reasons.append("High fine-detail noise") }
            if contrastFacet < 0.35 { reasons.append("Low contrast") }
            if dynamicRange < 5.0 { reasons.append("Narrow dynamic range") }
            if colorHarmony > 0.65 { reasons.append("Rich color variety") }
            if noiseEstimateFacet > 8.0 { reasons.append("High sensor noise (Immerkaer)") }
            if integratedComp >= 7.5 { reasons.append("Strong composition") }
            else if integratedComp < 4.0 { reasons.append("Weak composition") }
            if reasons.isEmpty { reasons.append("Balanced technical quality") }

            let recommendation: CullRecommendation
            if score >= 76, !face.possibleBlink {
                recommendation = .keep
            } else if score < 44 || (face.count > 0 && face.sharpness < 0.18) {
                recommendation = .reject
            } else {
                recommendation = .review
            }

            let record = CullAnalysisRecord(
                score: score,
                recommendation: recommendation,
                sharpness: metrics.sharpness,
                faceSharpness: face.sharpness,
                exposureQuality: exposure,
                highlightClipPercent: metrics.highlightClip * 100,
                shadowClipPercent: metrics.shadowClip * 100,
                noiseEstimate: metrics.noise,
                contrast: contrastFacet,
                faceCount: face.count,
                possibleBlink: face.possibleBlink,
                perceptualHash: hash,
                stackID: nil,
                stackRank: nil,
                stackCount: nil,
                faceCaptureQuality: faceCaptureQuality,
                aestheticScore: aestheticScore,
                expressionScore: nil,
                eyesOpenScore: nil,
                compositionScore: integratedComp,
                dynamicRangeStops: dynamicRange,
                colorHarmony: colorHarmony,
                reasons: reasons,
                analyzedAt: Date()
            )
            return Result(record: record)
        }.value
    }

    /// Compute Facet-style supplementary metrics from the same thumbnail pixels.
    /// Returns (colorHarmony 0-1, dynamicRange stops, noise sigma, contrast 0-1).
    /// All metrics are computed in a single pass over the pixel data for efficiency.
    private static func facetSupplementaryMetrics(_ payload: ThumbnailPayload) -> (Double, Double, Double, Double) {
        let w = payload.width, h = payload.height
        guard w > 4 && h > 4 else { return (0, 0, 0, 0) }
        let totalPixels = w * h
        let bins = 16384
        var histogram = [Int](repeating: 0, count: bins)
        var sumLuma = 0.0
        var sumLumaSq = 0.0
        // Color harmony subsampling
        let colorStep = max(1, totalPixels / 250_000)
        var colorHarmonyHist = [Double](repeating: 0, count: 180 * 256)
        var colorSampled = 0
        // Pre-compute luminance for all pixels in one pass
        var luma = [Double](repeating: 0, count: totalPixels)
        for i in 0..<totalPixels {
            let p = i * 4
            let r = Double(payload.rgba[p]) / 255.0
            let g = Double(payload.rgba[p + 1]) / 255.0
            let b = Double(payload.rgba[p + 2]) / 255.0
            let lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) * 255.0
            luma[i] = lum
            sumLuma += lum
            sumLumaSq += lum * lum
            // Histogram for dynamic range
            let clamped = max(0.0, min(1.0, lum / 255.0))
            let idx = min(bins - 1, Int(clamped * Double(bins - 1)).clamped(to: 0..<bins))
            histogram[idx] += 1
            // Color harmony subsampling (from RGB, not luma)
            if (i % colorStep) == 0 {
                let mx = max(r, g, b), mn = min(r, g, b)
                let d = mx - mn
                let s = mx > 0 ? d / mx : 0
                var h2: Double
                if d == 0 { h2 = 0 }
                else if mx == r { h2 = ((g - b) / d).truncatingRemainder(dividingBy: 6) + (g < b ? 6 : 0) }
                else if mx == g { h2 = ((b - r) / d) + 2 }
                else { h2 = ((r - g) / d) + 4 }
                h2 *= 60
                if h2 < 0 { h2 += 360 }
                let hi = Int(h2 / 360.0 * 180.0).clamped(to: 0..<180)
                let si = Int(s * 255).clamped(to: 0..<256)
                colorHarmonyHist[hi * 256 + si] += 1
                colorSampled += 1
            }
        }
        // Compute dynamic range from histogram
        let dynamicRange = facetDynamicRangeFromHistogram(histogram, count: totalPixels)
        // Compute noise (subsampling with scale correction)
        let noiseEstimate = facetNoiseEstimateFromLuma(luma: luma, width: w, height: h)
        // Compute contrast
        let mean = sumLuma / Double(totalPixels)
        let variance = max(0, sumLumaSq / Double(totalPixels) - mean * mean)
        let contrast = min(1, sqrt(variance) * 4.0 / 255.0)
        // Compute color harmony entropy
        let colorHarmony = colorSampled > 0 ? computeColorHarmonyEntropy(colorHarmonyHist, count: colorSampled) : 0
        return (colorHarmony, dynamicRange, noiseEstimate, contrast)
    }

    /// Compute dynamic range from pre-built histogram (O(n) histogram + O(bins) scan).
    private static func facetDynamicRangeFromHistogram(_ histogram: [Int], count: Int) -> Double {
        guard count > 0 else { return 0 }
        let bins = histogram.count
        // Find p2 (2nd percentile)
        var p2: Double = 0
        {
            var cumulative = 0
            let target = Int(Double(count) * 0.02)
            for (i, cnt) in histogram.enumerated() {
                cumulative += cnt
                if cumulative >= target {
                    p2 = Double(i) / Double(bins - 1) * 255.0
                    break
                }
            }
        }()
        // Find p98 (98th percentile)
        var p98: Double = 255.0
        {
            var cumulative = 0
            let target = Int(Double(count) * 0.98)
            for (i, cnt) in histogram.enumerated() {
                cumulative += cnt
                if cumulative >= target {
                    p98 = Double(i) / Double(bins - 1) * 255.0
                    break
                }
            }
        }()
        let base = max(p2, 1.0)
        return log2(max(p98, 1.0) / base)
    }

    /// Compute color harmony Shannon entropy from histogram.
    private static func computeColorHarmonyEntropy(_ hist: [Double], count: Int) -> Double {
        guard count > 0 else { return 0 }
        var sum = 0.0
        for v in hist { sum += v }
        guard sum > 0 else { return 0 }
        var entropy = 0.0
        for v in hist {
            let p = v / sum
            if p > 0 { entropy -= p * log2(p) }
        }
        // Facet caps at 15.5 bits max entropy for 180*256 bins
        let normalized = min(10.0, entropy * 10.0 / 15.5)
        return normalized / 10.0
    }

    /// Immerkaer noise estimation using pre-built luma array with subsampling.
    private static func facetNoiseEstimateFromLuma(luma: [Double], width: Int, height: Int) -> Double {
        guard width > 2 && height > 2 else { return 0 }
        let M: [Int] = [-1, 2, -1, 2, -4, 2, -1, 2, -1]
        let step = 2
        var sigma = 0.0
        var count = 0.0
        for py in stride(from: 1, to: height - 1, by: step) {
            for px in stride(from: 1, to: width - 1, by: step) {
                let i = py * width + px
                var ksum = 0.0
                ksum += Double(M[0]) * luma[i - width - 1]
                ksum += Double(M[1]) * luma[i - width]
                ksum += Double(M[2]) * luma[i - width + 1]
                ksum += Double(M[3]) * luma[i - 1]
                ksum += Double(M[4]) * luma[i]
                ksum += Double(M[5]) * luma[i + 1]
                ksum += Double(M[6]) * luma[i + width - 1]
                ksum += Double(M[7]) * luma[i + width]
                ksum += Double(M[8]) * luma[i + width + 1]
                sigma += abs(ksum)
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        let scale = Double(step * step)
        let w = Double(width - 2), h = Double(height - 2)
        let noise = sigma * sqrt(0.5 * .pi) / (6.0 * w * h) * scale
        return noise
    }

    private struct BasicMetrics {
        var sharpness: Double
        var highlightClip: Double
        var shadowClip: Double
        var noise: Double
        var contrast: Double
    }

    private struct FaceMetrics {
        var count: Int
        var sharpness: Double
        var possibleBlink: Bool
    }

    private nonisolated static func imageMetrics(_ payload: ThumbnailPayload) -> BasicMetrics {
        let w = payload.width, h = payload.height
        guard w > 2, h > 2 else {
            return BasicMetrics(sharpness: 0, highlightClip: 0, shadowClip: 0, noise: 0, contrast: 0)
        }
        let target = 420
        let step = max(1, max(w, h) / target)
        var gradientSum = 0.0
        var lapSum = 0.0
        var lapSq = 0.0
        var highlight = 0
        var shadow = 0
        var samples = 0
        var noiseSum = 0.0
        var mean = 0.0
        var meanSq = 0.0

        var y = step
        while y < h - step {
            var x = step
            while x < w - step {
                let c = luma(payload, x, y)
                let l = luma(payload, x - step, y)
                let r = luma(payload, x + step, y)
                let u = luma(payload, x, y - step)
                let d = luma(payload, x, y + step)
                let gx = r - l
                let gy = d - u
                gradientSum += gx * gx + gy * gy
                let lap = (l + r + u + d) - 4.0 * c
                lapSum += lap
                lapSq += lap * lap
                noiseSum += abs(c - (l + r + u + d) * 0.25)
                if c >= 0.985 { highlight += 1 }
                if c <= 0.018 { shadow += 1 }
                mean += c
                meanSq += c * c
                samples += 1
                x += step
            }
            y += step
        }
        guard samples > 0 else {
            return BasicMetrics(sharpness: 0, highlightClip: 0, shadowClip: 0, noise: 0, contrast: 0)
        }
        let n = Double(samples)
        let grad = gradientSum / n
        let lapMean = lapSum / n
        let lapVar = max(0, lapSq / n - lapMean * lapMean)
        // Normalize against empirically useful 8-bit-luma gradients without making the
        // score dependent on image resolution.
        let sharpness = min(1, sqrt(max(0, grad)) * 5.0 + sqrt(lapVar) * 2.3)
        let avg = mean / n
        let contrast = min(1, sqrt(max(0, meanSq / n - avg * avg)) * 4.0)
        let noise = min(1, (noiseSum / n) * 5.5)
        return BasicMetrics(
            sharpness: sharpness,
            highlightClip: Double(highlight) / n,
            shadowClip: Double(shadow) / n,
            noise: noise,
            contrast: contrast
        )
    }

    /// Native Apple Vision quality model. Returns a conservative average across
    /// faces: an unsharp person in a group photo should matter to the decision.
    private nonisolated static func faceCaptureQuality(_ payload: ThumbnailPayload) -> Double? {
        guard let cgImage = payload.makeCGImage() else { return nil }
        let request = VNDetectFaceCaptureQualityRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }
        let scores = (request.results ?? []).compactMap { $0.faceCaptureQuality.map(Double.init) }
        guard !scores.isEmpty else { return nil }
        return scores.reduce(0, +) / Double(scores.count)
    }

    /// Apple Vision's macOS 15+ aesthetic-scoring neural model, -1...+1.
    private nonisolated static func aestheticQuality(_ payload: ThumbnailPayload) -> Double? {
        guard let image = payload.makeCGImage() else { return nil }
        let request = VNCalculateImageAestheticsScoresRequest()
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil,
            let result = request.results?.first
        else { return nil }
        return Double(result.overallScore)
    }

    private nonisolated static func detectFacesVision(_ payload: ThumbnailPayload) -> [DetectedFace] {
        guard let cgImage = payload.makeCGImage() else { return [] }
        let request = VNDetectFaceRectanglesRequest()
        if #available(macOS 13.0, *) {
            request.revision = VNDetectFaceRectanglesRequestRevision2
        }

        var faces: [DetectedFace] = []
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            if let results = request.results {
                for face in results {
                    let bounds = face.boundingBox
                    let w = Double(payload.width)
                    let h = Double(payload.height)
                    let rect = CGRect(
                        x: bounds.minX * w,
                        y: (1 - bounds.maxY) * h,
                        width: bounds.width * w,
                        height: bounds.height * h
                    )
                    let leftEye = CGPoint(x: rect.minX + rect.width * 0.3, y: rect.minY + rect.height * 0.35)
                    let rightEye = CGPoint(x: rect.minX + rect.width * 0.7, y: rect.minY + rect.height * 0.35)
                    let nose = CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.55)
                    let rightMouth = CGPoint(x: rect.minX + rect.width * 0.35, y: rect.minY + rect.height * 0.75)
                    let leftMouth = CGPoint(x: rect.minX + rect.width * 0.65, y: rect.minY + rect.height * 0.75)
                    faces.append(
                        DetectedFace(
                            bounds: rect,
                            rightEye: rightEye,
                            leftEye: leftEye,
                            nose: nose,
                            rightMouth: rightMouth,
                            leftMouth: leftMouth,
                            confidence: 1.0
                        ))
                }
            }
        } catch {
            // Face detection is an advisory culling signal. A detector failure must
            // never prevent technical scoring or user-driven culling.
        }
        return faces
    }

    private nonisolated static func faceMetrics(_ payload: ThumbnailPayload, faces: [DetectedFace]) -> FaceMetrics {
        guard !faces.isEmpty else { return FaceMetrics(count: 0, sharpness: 0, possibleBlink: false) }
        var sharpness = 0.0
        var possibleBlink = false
        for face in faces {
            let normalized = CGRect(
                x: face.bounds.minX / Double(payload.width),
                y: face.bounds.minY / Double(payload.height),
                width: face.bounds.width / Double(payload.width),
                height: face.bounds.height / Double(payload.height)
            )
            sharpness = max(sharpness, regionalSharpness(payload, normalizedRect: normalized, topLeftOrigin: true))

            // Face rectangles provide approximate eye centers rather than eyelid contours. Use a deliberately
            // conservative local eye-detail heuristic and label the result only as a
            // *possible* blink. It never auto-rejects a frame by itself.
            let eyeRadius = max(3.0, face.bounds.width * 0.09)
            let leftDetail = eyeRegionDetail(payload, center: face.leftEye, radius: eyeRadius)
            let rightDetail = eyeRegionDetail(payload, center: face.rightEye, radius: eyeRadius)
            if face.bounds.width >= 28, sharpness > 0.38, leftDetail < 0.055, rightDetail < 0.055 {
                possibleBlink = true
            }
        }
        return FaceMetrics(count: faces.count, sharpness: min(1, sharpness), possibleBlink: possibleBlink)
    }

    private nonisolated static func eyeRegionDetail(
        _ payload: ThumbnailPayload, center: CGPoint, radius: Double
    ) -> Double {
        let x0 = max(1, Int(center.x - radius))
        let x1 = min(payload.width - 2, Int(center.x + radius))
        let y0 = max(1, Int(center.y - radius))
        let y1 = min(payload.height - 2, Int(center.y + radius))
        guard x1 > x0, y1 > y0 else { return 1 }
        var gradient = 0.0
        var count = 0.0
        for y in y0...y1 {
            for x in x0...x1 {
                let gx = luma(payload, x + 1, y) - luma(payload, x - 1, y)
                let gy = luma(payload, x, y + 1) - luma(payload, x, y - 1)
                gradient += sqrt(gx * gx + gy * gy)
                count += 1
            }
        }
        return count > 0 ? gradient / count : 1
    }

    private nonisolated static func regionalSharpness(
        _ payload: ThumbnailPayload,
        normalizedRect: CGRect,
        topLeftOrigin: Bool = false
    ) -> Double {
        let w = payload.width, h = payload.height
        let x0 = max(1, Int(normalizedRect.minX * Double(w)))
        let x1 = min(w - 2, Int(normalizedRect.maxX * Double(w)))
        let y0: Int
        let y1: Int
        if topLeftOrigin {
            y0 = max(1, Int(normalizedRect.minY * Double(h)))
            y1 = min(h - 2, Int(normalizedRect.maxY * Double(h)))
        } else {
            y0 = max(1, Int((1.0 - normalizedRect.maxY) * Double(h)))
            y1 = min(h - 2, Int((1.0 - normalizedRect.minY) * Double(h)))
        }
        guard x1 > x0, y1 > y0 else { return 0 }
        let step = max(1, max(x1 - x0, y1 - y0) / 180)
        var total = 0.0, n = 0.0
        var y = y0 + step
        while y < y1 - step {
            var x = x0 + step
            while x < x1 - step {
                let gx = luma(payload, x + step, y) - luma(payload, x - step, y)
                let gy = luma(payload, x, y + step) - luma(payload, x, y - step)
                total += gx * gx + gy * gy
                n += 1
                x += step
            }
            y += step
        }
        guard n > 0 else { return 0 }
        return min(1, sqrt(total / n) * 6.2)
    }

    private nonisolated static func dHash(_ payload: ThumbnailPayload) -> UInt64 {
        var hash: UInt64 = 0
        for y in 0..<8 {
            let py = min(payload.height - 1, Int((Double(y) + 0.5) * Double(payload.height) / 8.0))
            for x in 0..<8 {
                let aX = min(payload.width - 1, Int(Double(x) * Double(payload.width - 1) / 8.0))
                let bX = min(payload.width - 1, Int(Double(x + 1) * Double(payload.width - 1) / 8.0))
                if luma(payload, aX, py) > luma(payload, bX, py) { hash |= (1 << UInt64(y * 8 + x)) }
            }
        }
        return hash
    }

    private nonisolated static func luma(_ payload: ThumbnailPayload, _ x: Int, _ y: Int) -> Double {
        let ix = max(0, min(payload.width - 1, x))
        let iy = max(0, min(payload.height - 1, y))
        let p = (iy * payload.width + ix) * 4
        let r = Double(payload.rgba[p]) / 255.0
        let g = Double(payload.rgba[p + 1]) / 255.0
        let b = Double(payload.rgba[p + 2]) / 255.0
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}
