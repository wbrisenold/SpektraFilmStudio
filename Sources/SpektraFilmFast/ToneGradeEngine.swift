import Foundation
import Dispatch

// Tone controls are intentionally traceable to concrete open-source implementations:
// - Exposure semantics and ACEScc transfer: Alcedo Studio (GPL-3.0), where Exposure adds EV / 17.52
//   to ACEScc channels.
// - Curve normalization and monotone Hermite tangents: Alcedo Studio's curve module.
// - Built-in preset node values: darktable rgbcurve.c (GPL-3.0-or-later).
// See IMPLEMENTATION_SOURCES.md for pinned source paths/revisions.

enum ToneCurvePresetGroup: String, CaseIterable, Identifiable, Sendable {
    case technical = "Technical"
    case filmResponse = "Film Response"
    case creative = "Creative"

    var id: String { rawValue }
}

enum ToneCurvePreset: String, CaseIterable, Identifiable, Sendable {
    // Sourced technical presets.
    case linear = "Linear"
    case compression = "Contrast Compression"
    case medium = "Medium Contrast"
    case high = "High Contrast"
    case gamma20 = "Gamma 2.0"
    case gamma05 = "Gamma 0.5"

    // Film-response presets. These are normalized master-curve interpretations of the
    // toe / straight-line / shoulder behavior used by filmr's open-source H-D curve model.
    // They are not claimed to be exact stock emulations; SpektraFilm's stock engine remains
    // responsible for actual film color/spectral behavior.
    case filmNegativeSoft = "Color Negative — Soft"
    case filmNegativeClassic = "Color Negative — Classic"
    case filmSlidePunch = "Slide Film — Punch"
    case filmBWClassic = "B&W Negative — Classic"

    // Original SpektraFilm creative recipes. These intentionally stay stock-neutral.
    case cinematicSoft = "Cinematic Soft"
    case cinematicPunch = "Cinematic Punch"
    case matteFade = "Matte Fade"
    case airy = "Airy"
    case dreamy = "Dreamy"
    case softHighlights = "Soft Highlight Roll-Off"
    case deepBlacks = "Deep Blacks"
    case noir = "Noir Contrast"
    case highKey = "High Key"
    case lowKey = "Low Key"
    case fadedPrint = "Faded Print"

    var id: String { rawValue }

    var group: ToneCurvePresetGroup {
        switch self {
        case .linear, .compression, .medium, .high, .gamma20, .gamma05:
            return .technical
        case .filmNegativeSoft, .filmNegativeClassic, .filmSlidePunch, .filmBWClassic:
            return .filmResponse
        case .cinematicSoft, .cinematicPunch, .matteFade, .airy, .dreamy,
             .softHighlights, .deepBlacks, .noir, .highKey, .lowKey, .fadedPrint:
            return .creative
        }
    }

    var summary: String {
        switch self {
        case .linear: return "Neutral point curve."
        case .compression: return "Compresses contrast while preserving the endpoints."
        case .medium: return "Moderate S-curve for a little more separation."
        case .high: return "Stronger S-curve for punchier contrast."
        case .gamma20: return "Dark gamma-style response."
        case .gamma05: return "Bright gamma-style response."
        case .filmNegativeSoft: return "Gentle film-like toe and shoulder with soft midtone contrast."
        case .filmNegativeClassic: return "Classic negative-style S-curve with a firmer straight-line section."
        case .filmSlidePunch: return "Steeper slide-film-style midtones with stronger toe and shoulder compression."
        case .filmBWClassic: return "Traditional high-separation black-and-white negative response."
        case .cinematicSoft: return "Subtle lifted shadows and smooth highlight compression."
        case .cinematicPunch: return "Deeper shadows and brighter upper mids without clipping the endpoints."
        case .matteFade: return "Lifts the black floor and softens the top end for a matte finish."
        case .airy: return "Raises shadows and midtones for a bright, open look."
        case .dreamy: return "Soft contrast with lifted low mids and gentle highlights."
        case .softHighlights: return "Mostly leaves shadows alone while rolling highlights down smoothly."
        case .deepBlacks: return "Adds weight to the dark end while keeping midtones controlled."
        case .noir: return "Strong shadow separation and a dramatic contrast curve."
        case .highKey: return "Pushes midtones brighter while keeping whites controlled."
        case .lowKey: return "Darkens the body of the image while preserving highlight separation."
        case .fadedPrint: return "Raised blacks with compressed highlights, similar to an aged print response."
        }
    }

    var points: [ToneCurvePoint] {
        switch self {
        case .linear:
            let x = [0.0, 0.08, 0.17, 0.50, 0.83, 0.92, 1.0]
            return x.map { ToneCurvePoint(x: $0, y: $0) }
        case .compression:
            return [
                .init(x: 0.000000, y: 0.000000),
                .init(x: 0.003862, y: 0.007782),
                .init(x: 0.076613, y: 0.156182),
                .init(x: 0.169355, y: 0.290352),
                .init(x: 0.774194, y: 0.773852),
                .init(x: 1.000000, y: 1.000000),
            ]
        case .medium:
            let x = [0.0, 0.08, 0.17, 0.50, 0.83, 0.92, 1.0]
            let y = [0.0, 0.06, 0.14, 0.50, 0.86, 0.94, 1.0]
            return zip(x, y).map { ToneCurvePoint(x: $0.0, y: $0.1) }
        case .high:
            let x = [0.0, 0.08, 0.17, 0.50, 0.83, 0.92, 1.0]
            let y = [0.0, 0.04, 0.11, 0.50, 0.89, 0.96, 1.0]
            return zip(x, y).map { ToneCurvePoint(x: $0.0, y: $0.1) }
        case .gamma20:
            let x = [0.0, 0.08, 0.17, 0.50, 0.83, 0.92, 1.0]
            return x.map { ToneCurvePoint(x: $0, y: $0 * $0) }
        case .gamma05:
            let x = [0.0, 0.08, 0.17, 0.50, 0.83, 0.92, 1.0]
            return x.map { ToneCurvePoint(x: $0, y: sqrt($0)) }

        case .filmNegativeSoft:
            return points(
                x: [0, 0.08, 0.17, 0.33, 0.50, 0.67, 0.83, 0.92, 1],
                y: [0, 0.0585, 0.1357, 0.3001, 0.50, 0.6999, 0.8643, 0.9415, 1]
            )
        case .filmNegativeClassic:
            return points(
                x: [0, 0.08, 0.17, 0.33, 0.50, 0.67, 0.83, 0.92, 1],
                y: [0, 0.0433, 0.1084, 0.2724, 0.50, 0.7276, 0.8916, 0.9567, 1]
            )
        case .filmSlidePunch:
            return points(
                x: [0, 0.08, 0.17, 0.33, 0.50, 0.67, 0.83, 0.92, 1],
                y: [0, 0.0222, 0.0648, 0.2166, 0.50, 0.7834, 0.9352, 0.9778, 1]
            )
        case .filmBWClassic:
            return points(
                x: [0, 0.08, 0.17, 0.33, 0.50, 0.67, 0.83, 0.92, 1],
                y: [0, 0.0334, 0.0890, 0.2498, 0.50, 0.7502, 0.9110, 0.9666, 1]
            )

        case .cinematicSoft:
            return points(x: [0, 0.08, 0.20, 0.50, 0.80, 0.94, 1], y: [0.025, 0.085, 0.19, 0.50, 0.80, 0.92, 0.985])
        case .cinematicPunch:
            return points(x: [0, 0.08, 0.20, 0.50, 0.80, 0.94, 1], y: [0, 0.045, 0.13, 0.50, 0.88, 0.97, 1])
        case .matteFade:
            return points(x: [0, 0.08, 0.20, 0.50, 0.80, 0.94, 1], y: [0.065, 0.105, 0.21, 0.50, 0.79, 0.91, 0.965])
        case .airy:
            return points(x: [0, 0.08, 0.20, 0.50, 0.80, 0.94, 1], y: [0.025, 0.12, 0.27, 0.59, 0.84, 0.95, 1])
        case .dreamy:
            return points(x: [0, 0.10, 0.24, 0.50, 0.78, 0.92, 1], y: [0.045, 0.13, 0.29, 0.55, 0.80, 0.91, 0.975])
        case .softHighlights:
            return points(x: [0, 0.20, 0.50, 0.72, 0.86, 0.95, 1], y: [0, 0.20, 0.50, 0.71, 0.82, 0.91, 0.965])
        case .deepBlacks:
            return points(x: [0, 0.06, 0.15, 0.35, 0.60, 0.85, 1], y: [0, 0.025, 0.085, 0.31, 0.60, 0.87, 1])
        case .noir:
            return points(x: [0, 0.08, 0.20, 0.50, 0.78, 0.92, 1], y: [0, 0.025, 0.105, 0.47, 0.88, 0.975, 1])
        case .highKey:
            return points(x: [0, 0.08, 0.20, 0.50, 0.78, 0.92, 1], y: [0.035, 0.13, 0.29, 0.64, 0.86, 0.95, 1])
        case .lowKey:
            return points(x: [0, 0.08, 0.20, 0.50, 0.78, 0.92, 1], y: [0, 0.035, 0.12, 0.39, 0.70, 0.88, 1])
        case .fadedPrint:
            return points(x: [0, 0.08, 0.20, 0.50, 0.80, 0.94, 1], y: [0.085, 0.12, 0.22, 0.50, 0.77, 0.88, 0.94])
        }
    }

    private func points(x: [Double], y: [Double]) -> [ToneCurvePoint] {
        zip(x, y).map { ToneCurvePoint(x: $0.0, y: $0.1) }
    }
}

enum ToneCurveMath {
    static let epsilon = 1.0e-6
    static let minimumPointSpacing = 1.0e-3
    static let maximumControlPoints = 12

    struct HermiteCache: Sendable {
        var h: [Double]
        var m: [Double]
    }

    static func normalize(_ input: [ToneCurvePoint]) -> [ToneCurvePoint] {
        var points = input.compactMap { point -> ToneCurvePoint? in
            guard point.x.isFinite, point.y.isFinite else { return nil }
            return ToneCurvePoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
        }
        if points.isEmpty { return ToneCurvePreset.linear.points }

        points.sort {
            if abs($0.x - $1.x) <= epsilon { return $0.y < $1.y }
            return $0.x < $1.x
        }

        var deduped: [ToneCurvePoint] = []
        for point in points {
            if deduped.isEmpty || abs(point.x - deduped[deduped.count - 1].x) > epsilon {
                deduped.append(point)
            } else {
                deduped[deduped.count - 1].y = point.y
            }
        }
        guard deduped.count >= 2,
              deduped.last!.x - deduped.first!.x > minimumPointSpacing else {
            return ToneCurvePreset.linear.points
        }

        var normalized: [ToneCurvePoint] = [deduped[0]]
        if deduped.count > 2 {
            for point in deduped.dropFirst().dropLast() {
                guard point.x > normalized.last!.x + minimumPointSpacing,
                      point.x < deduped.last!.x - minimumPointSpacing else { continue }
                normalized.append(point)
                if normalized.count >= maximumControlPoints - 1 { break }
            }
        }
        normalized.append(deduped.last!)
        return normalized
    }

    static func buildCache(_ points: [ToneCurvePoint]) -> HermiteCache {
        let n = points.count
        guard n > 0 else { return HermiteCache(h: [], m: []) }
        guard n > 1 else { return HermiteCache(h: [], m: [0]) }

        var h = [Double](repeating: 0, count: n - 1)
        var delta = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            let dx = points[i + 1].x - points[i].x
            h[i] = dx
            if abs(dx) > epsilon { delta[i] = (points[i + 1].y - points[i].y) / dx }
        }

        var m = [Double](repeating: 0, count: n)
        m[0] = delta[0]
        m[n - 1] = delta[n - 2]
        if n > 2 {
            for i in 1..<(n - 1) {
                if delta[i - 1] * delta[i] <= 0 {
                    m[i] = 0
                    continue
                }
                let w1 = 2 * h[i] + h[i - 1]
                let w2 = h[i] + 2 * h[i - 1]
                let denom = w1 / delta[i - 1] + w2 / delta[i]
                m[i] = (w1 + w2 > 0 && abs(denom) > epsilon) ? (w1 + w2) / denom : 0
            }
        }
        return HermiteCache(h: h, m: m)
    }

    static func evaluate(_ value: Double, points source: [ToneCurvePoint], cache supplied: HermiteCache? = nil) -> Double {
        let points = normalize(source)
        guard points.count >= 2 else { return value }
        let cache = supplied ?? buildCache(points)

        // Alcedo's runtime extrapolates outside the endpoint range. Preserve that behavior so
        // extended-range/negative image values are not clipped merely by enabling a curve.
        if value <= points[0].x {
            let dx = max(points[1].x - points[0].x, epsilon)
            return points[0].y + (value - points[0].x) * (points[1].y - points[0].y) / dx
        }
        if value >= points[points.count - 1].x {
            let a = points.count - 2, b = points.count - 1
            let dx = max(points[b].x - points[a].x, epsilon)
            return points[a].y + (value - points[a].x) * (points[b].y - points[a].y) / dx
        }

        var index = points.count - 2
        for i in 0..<(points.count - 1) where value < points[i + 1].x {
            index = i
            break
        }
        guard index < cache.h.count, index + 1 < cache.m.count else { return value }
        let dx = cache.h[index]
        guard abs(dx) > epsilon else { return points[index].y }
        let t = (value - points[index].x) / dx
        let h00 = 2*t*t*t - 3*t*t + 1
        let h10 = t*t*t - 2*t*t + t
        let h01 = -2*t*t*t + 3*t*t
        let h11 = t*t*t - t*t
        return h00 * points[index].y + h10 * dx * cache.m[index]
             + h01 * points[index + 1].y + h11 * dx * cache.m[index + 1]
    }
}

private enum AlcedoACEScc {
    static let a = 9.72
    static let b = 17.52
    static let offset = 0.0000152587890625
    static let transition = 0.000030517578125
    static let floor = (-16.0 + a) / b
    static let threshold = (-15.0 + a) / b

    static func encode(_ value: Double) -> Double {
        if value < 0 { return floor + value }
        if value < transition { return (log2(offset + value * 0.5) + a) / b }
        return (log2(value) + a) / b
    }

    static func decode(_ value: Double) -> Double {
        if value < floor { return value - floor }
        if value <= threshold { return (pow(2, value * b - a) - offset) * 2 }
        return pow(2, value * b - a)
    }
}

private enum SourcedToneMath {
    private struct SharedCurve {
        var x = [0.0, 0.25, 0.75, 1.0]
        var y = [0.0, 0.25, 0.75, 1.0]
        var h = [0.25, 0.50, 0.25]
        var m = [1.0, 1.0, 1.0, 1.0]
    }

    static func applyLinearTone(
        r: Double, g: Double, b: Double,
        contrast: Double, shadows: Double, highlights: Double
    ) -> (Double, Double, Double) {
        var rr = r, gg = g, bb = b

        // Alcedo's current contrast design uses an S-shaped stops-from-18%-grey response with
        // slope = 2^(contrast/100) and a 2.5-stop width. This Rec.2020 implementation keeps
        // that sourced lightness behavior while preserving the app's existing working space.
        if abs(contrast) > 1e-9 {
            let y = 0.2627 * rr + 0.6780 * gg + 0.0593 * bb
            if y > 1e-9 {
                let slope = pow(2.0, max(-100, min(100, contrast)) / 100.0)
                let width = 2.5
                let shape = tanh(log2(y / 0.18) / width)
                let gain = pow(2.0, (slope - 1.0) * width * shape)
                let mappedY = y * gain
                let chromaScale = sqrt(slope) * min(gain, 1.0)
                rr = mappedY + (rr - y) * chromaScale
                gg = mappedY + (gg - y) * chromaScale
                bb = mappedY + (bb - y) * chromaScale
            }
        }

        if abs(shadows) > 1e-9 || abs(highlights) > 1e-9 {
            let sourceY = 0.2126 * rr + 0.7152 * gg + 0.0722 * bb
            let curve = makeSharedCurve(shadows: shadows, highlights: highlights)
            let mappedY = evaluate(sourceY, curve: curve)
            let dr = rr - sourceY, dg = gg - sourceY, db = bb - sourceY
            var scale = 1.0
            if dr < 0 { scale = min(scale, mappedY / max(-dr, 1e-12)) }
            if dg < 0 { scale = min(scale, mappedY / max(-dg, 1e-12)) }
            if db < 0 { scale = min(scale, mappedY / max(-db, 1e-12)) }
            scale = max(0, min(1, scale))
            rr = mappedY + dr * scale
            gg = mappedY + dg * scale
            bb = mappedY + db * scale
        }

        return (rr, gg, bb)
    }

    private static func makeSharedCurve(shadows: Double, highlights: Double) -> SharedCurve {
        var curve = SharedCurve()
        let shadowControl = max(-1, min(1, shadows / 100.0))
        // Alcedo's published Highlights path scales the slider 1.5x before building the shared curve.
        let highlightControl = max(-1, min(1, highlights * 1.5 / 100.0))
        curve.y[1] = max(0.02, min(0.73, 0.25 + shadowControl * 0.10))
        let highlightPull = highlightControl * 0.40
        curve.y[3] = max(0.85, min(1.30, 1.0 - highlightPull))
        curve.y[2] = max(0.65, min(1.0, 0.75 + highlightPull * 0.20))
        computeTangents(&curve)
        return curve
    }

    private static func computeTangents(_ curve: inout SharedCurve) {
        var d = [Double](repeating: 0, count: 3)
        for i in 0..<3 {
            d[i] = abs(curve.h[i]) > 1e-8 ? (curve.y[i+1] - curve.y[i]) / curve.h[i] : 0
        }
        curve.m[0] = d[0]
        curve.m[3] = d[2]
        for i in 1..<3 {
            curve.m[i] = d[i-1] * d[i] <= 0 ? 0 : 0.5 * (d[i-1] + d[i])
        }
        for i in 0..<3 {
            if abs(d[i]) <= 1e-8 {
                curve.m[i] = 0; curve.m[i+1] = 0
                continue
            }
            let a = curve.m[i] / d[i]
            let b = curve.m[i+1] / d[i]
            let sum = a*a + b*b
            if sum > 9 {
                let tau = 3 / sqrt(sum)
                curve.m[i] = tau * a * d[i]
                curve.m[i+1] = tau * b * d[i]
            }
        }
        for i in 0..<4 { curve.m[i] = max(0.05, min(2.85, curve.m[i])) }
    }

    private static func evaluate(_ value: Double, curve: SharedCurve) -> Double {
        if value <= curve.x[0] { return curve.y[0] }
        if value >= curve.x[3] { return curve.y[3] + (value - curve.x[3]) * curve.m[3] }
        var index = 2
        for i in 0..<3 where value < curve.x[i+1] { index = i; break }
        let dx = curve.h[index]
        guard abs(dx) > 1e-8 else { return curve.y[index] }
        let t = (value - curve.x[index]) / dx
        let h00 = 2*t*t*t - 3*t*t + 1
        let h10 = t*t*t - 2*t*t + t
        let h01 = -2*t*t*t + 3*t*t
        let h11 = t*t*t - t*t
        return h00*curve.y[index] + h10*dx*curve.m[index]
             + h01*curve.y[index+1] + h11*dx*curve.m[index+1]
    }

    // RapidRAW v1.6.4 filmic Brightness: a rational luma reshape that favors midtones
    // and keeps the top end anchored instead of behaving like a second exposure multiplier.
    static func filmicBrightness(
        r: Double, g: Double, b: Double, value: Double
    ) -> (Double, Double, Double) {
        let amount = max(-1, min(1, value / 100.0))
        guard abs(amount) > 1e-12 else { return (r, g, b) }
        let originalLuma = 0.2126*r + 0.7152*g + 0.0722*b
        guard abs(originalLuma) > 1e-5 else { return (r, g, b) }

        let midtoneStrength = 1.2
        let topAnchor = 1.0
        let k = pow(2.0, -amount * midtoneStrength)
        let lumaAbs = abs(originalLuma)
        let shapedAbs: Double
        if lumaAbs <= topAnchor {
            let n = lumaAbs / topAnchor
            shapedAbs = (n / max(n + (1.0 - n) * k, 1e-12)) * topAnchor
        } else {
            shapedAbs = topAnchor + (lumaAbs - topAnchor) * k
        }
        let newLuma = originalLuma.sign == .minus ? -shapedAbs : shapedAbs
        let chroma = (r-originalLuma, g-originalLuma, b-originalLuma)
        let totalScale = shapedAbs / max(lumaAbs, 1e-12)
        let lumaWeight = min(2.0, max(0.0, shapedAbs)) * 0.5
        let dynamicExponent = 0.95 + (0.65 - 0.95) * lumaWeight
        let baseChromaScale = pow(max(totalScale, 1e-12), dynamicExponent)
        let rolloff = min(1.0, max(0.0, (1.05-shapedAbs) / max(1.05-originalLuma, 1e-4)))
        let mixAmount = min(1.0, abs(amount))
        let chromaScale = baseChromaScale * (1.0 + (rolloff-1.0) * mixAmount)
        return (
            newLuma + chroma.0 * chromaScale,
            newLuma + chroma.1 * chromaScale,
            newLuma + chroma.2 * chromaScale
        )
    }

    // Midtone luminance mask follows RapidRAW's open-source color-grading crossover model
    // (shadow crossover 0.1, highlight crossover 0.5, 0.2 feather). The control only changes
    // luminance, preserving the pixel's chroma around the original luma.
    static func midtones(
        r: Double, g: Double, b: Double, value: Double
    ) -> (Double, Double, Double) {
        let amount = max(-1, min(1, value / 100.0))
        guard abs(amount) > 1e-12 else { return (r, g, b) }
        let luma = max(0.0, 0.2126*r + 0.7152*g + 0.0722*b)
        let shadowMask = 1.0 - smoothstep(-0.1, 0.3, luma)
        let highlightMask = smoothstep(0.3, 0.7, luma)
        let midMask = max(0.0, 1.0 - shadowMask - highlightMask)
        guard midMask > 1e-9 else { return (r, g, b) }
        // Keep the adjustment photographic: +/-100 is roughly +/-1.25 EV at the mask peak.
        let gain = pow(2.0, amount * 1.25 * midMask)
        let targetLuma = luma * gain
        let delta = targetLuma - luma
        return (r + delta, g + delta, b + delta)
    }

    // Adapted from the negative/highlight-compression branch of RapidRAW's current
    // apply_highlights_adjustment. This is deliberately separate from Highlights: Recovery
    // only compresses the bright end and gently neutralizes severely over-range pixels.
    static func highlightRecovery(
        r: Double, g: Double, b: Double, value: Double
    ) -> (Double, Double, Double) {
        let amount = max(0, min(1, value / 100.0))
        guard amount > 1e-12 else { return (r, g, b) }
        let luma = max(0.0, 0.2126*r + 0.7152*g + 0.0722*b)
        let pivot = 0.10
        guard luma > pivot else { return (r, g, b) }
        let delta = max(luma - pivot, 0.0)
        let strength = amount * 2.2
        let compressed = delta / (1.0 + strength * (delta / (1.0 + delta * 0.35)))
        let recoveredBase = pivot + compressed
        let blend = smoothstep(pivot, pivot + 0.35, luma)
        let targetLuma = luma + (recoveredBase - luma) * blend
        let ratio = targetLuma / max(luma, 1e-12)
        var rr = r * ratio, gg = g * ratio, bb = b * ratio
        if luma > 1.0 {
            let blowout = smoothstep(1.0, 3.5, luma) * amount * 0.40
            rr += (targetLuma - rr) * blowout
            gg += (targetLuma - gg) * blowout
            bb += (targetLuma - bb) * blowout
        }
        return (rr, gg, bb)
    }

    // RapidRAW's rewritten shadow lift uses a perceptual 2.2-domain weighting so the recovery
    // fades away before the midtones. This standalone version intentionally only lifts shadows;
    // the existing Shadows control remains a broader creative tonal adjustment.
    static func shadowRecovery(
        r: Double, g: Double, b: Double, value: Double
    ) -> (Double, Double, Double) {
        let amount = max(0, min(1, value / 100.0))
        guard amount > 1e-12 else { return (r, g, b) }
        let luma = max(0.0, 0.2126*r + 0.7152*g + 0.0722*b)
        guard luma > 1e-6 else { return (r, g, b) }
        let t = pow(luma, 1.0/2.2)
        let lift = amount * t * pow(max(1.0-t, 0.0), 4.5)
        let curvedT = max(t + lift, 0.0)
        let targetLuma = pow(curvedT, 2.2)
        let ratio = targetLuma / max(luma, 1e-12)
        let desat = min(0.40, max(0.0, (ratio-1.0) * 0.15))
        let rr = r * ratio, gg = g * ratio, bb = b * ratio
        return (
            rr + (targetLuma-rr)*desat,
            gg + (targetLuma-gg)*desat,
            bb + (targetLuma-bb)*desat
        )
    }

    // Levels-style input-point remap. Positive Black Point deepens the floor; positive White
    // Point makes the bright end reach white sooner. Extrapolation is preserved for HDR/negative
    // values instead of clipping to 0...1.
    static func remapPoints(_ value: Double, blackPoint: Double, whitePoint: Double) -> Double {
        let black = max(-0.08, min(0.08, blackPoint * 0.0008))
        let white = 1.0 - max(-0.08, min(0.08, whitePoint * 0.0008))
        let width = max(0.10, white - black)
        return (value - black) / width
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
        let t = min(1.0, max(0.0, (x-edge0)/(edge1-edge0)))
        return t*t*(3.0-2.0*t)
    }

    static func whiteGain(_ value: Double) -> Double {
        let v = max(-100, min(100, value))
        // Current Alcedo source defines +White as 1 + value*0.005. The reciprocal branch is the
        // symmetric inverse for negative values, so both directions remain continuous at zero.
        return v >= 0 ? 1.0 + v * 0.005 : 1.0 / (1.0 + (-v) * 0.005)
    }

    static func blackOffset(_ value: Double) -> Double {
        max(-100, min(100, value)) * 0.001
    }
}

private enum PrimeraDensityMath {
    static func apply(_ rgb: (Double, Double, Double), settings: ColorDensitySettings?) -> (Double, Double, Double) {
        guard let settings, !settings.isIdentity else { return rgb }
        var r = rgb.0, g = rgb.1, b = rgb.2
        // PrimeraHue intentionally bypasses extended-range values.
        guard r >= 0, r <= 1, g >= 0, g <= 1, b >= 0, b <= 1 else { return rgb }

        let master = settings.master
        let rd = clampDensity(settings.red + master)
        let yd = clampDensity(settings.yellow + master)
        let gd = clampDensity(settings.green + master)
        let cd = clampDensity(settings.cyan + master)
        let bd = clampDensity(settings.blue + master)
        let md = clampDensity(settings.magenta + master)

        let before = 0.2126*r + 0.7152*g + 0.0722*b
        let rc = (1.0 + rd, 0.0 + rd, 0.0 + rd)
        let gc = (0.0 + gd, 1.0 + gd, 0.0 + gd)
        let bc = (0.0 + bd, 0.0 + bd, 1.0 + bd)
        let cc = (0.0 + cd, 1.0 + cd, 1.0 + cd)
        let mc = (1.0 + md, 0.0 + md, 1.0 + md)
        let yc = (1.0 + yd, 1.0 + yd, 0.0 + yd)
        (r, g, b) = tetraInterp(r: r, g: g, b: b, rc: rc, gc: gc, bc: bc, cc: cc, mc: mc, yc: yc)

        if settings.preserveLuma {
            let after = 0.2126*r + 0.7152*g + 0.0722*b
            if before > 0, after > 1e-12 {
                let ratio = before / after
                r *= ratio; g *= ratio; b *= ratio
            }
        }

        // PrimeraHue's default soft squeeze protects the 0...1 log-domain shoulder/toe.
        r = softSqueeze(r); g = softSqueeze(g); b = softSqueeze(b)
        return (r, g, b)
    }

    private static func clampDensity(_ value: Double) -> Double { max(-1, min(1, value)) }

    private static func tetraInterp(
        r: Double, g: Double, b: Double,
        rc: (Double,Double,Double), gc: (Double,Double,Double), bc: (Double,Double,Double),
        cc: (Double,Double,Double), mc: (Double,Double,Double), yc: (Double,Double,Double)
    ) -> (Double,Double,Double) {
        func add(_ a:(Double,Double,Double), _ b:(Double,Double,Double)) -> (Double,Double,Double) {
            (a.0+b.0,a.1+b.1,a.2+b.2)
        }
        func mul(_ s:Double, _ a:(Double,Double,Double)) -> (Double,Double,Double) {
            (s*a.0,s*a.1,s*a.2)
        }
        let one=(1.0,1.0,1.0)
        if r >= g && r >= b {
            if g >= b {
                return add(add(mul(r,rc), mul(g,(yc.0-rc.0,yc.1-rc.1,yc.2-rc.2))), mul(b,(one.0-yc.0,one.1-yc.1,one.2-yc.2)))
            }
            return add(add(mul(r,rc), mul(b,(mc.0-rc.0,mc.1-rc.1,mc.2-rc.2))), mul(g,(one.0-mc.0,one.1-mc.1,one.2-mc.2)))
        } else if g >= r && g >= b {
            if r >= b {
                return add(add(mul(g,gc), mul(r,(yc.0-gc.0,yc.1-gc.1,yc.2-gc.2))), mul(b,(one.0-yc.0,one.1-yc.1,one.2-yc.2)))
            }
            return add(add(mul(g,gc), mul(b,(cc.0-gc.0,cc.1-gc.1,cc.2-gc.2))), mul(r,(one.0-cc.0,one.1-cc.1,one.2-cc.2)))
        } else {
            if r >= g {
                return add(add(mul(b,bc), mul(r,(mc.0-bc.0,mc.1-bc.1,mc.2-bc.2))), mul(g,(one.0-mc.0,one.1-mc.1,one.2-mc.2)))
            }
            return add(add(mul(b,bc), mul(g,(cc.0-bc.0,cc.1-bc.1,cc.2-bc.2))), mul(r,(one.0-cc.0,one.1-cc.1,one.2-cc.2)))
        }
    }

    private static func softSqueeze(_ value: Double) -> Double {
        var v = value
        let knee = 0.9, range = 0.1
        if v > knee { v = knee + range * tanh((v-knee)/range) }
        let toe = 0.1
        if v < toe { v = toe * exp(v/toe - 1.0) }
        return v
    }
}


private enum AutoContrastMath {
    private static let bins = 16_384

    static func bounds(_ pixels: [Float]) -> (black: Double, white: Double)? {
        guard pixels.count >= 4 else { return nil }
        var histogram = [Int](repeating: 0, count: bins)

        for p in stride(from: 0, to: pixels.count, by: 4) {
            let r = max(0.0, min(1.0, Double(pixels[p])))
            let g = max(0.0, min(1.0, Double(pixels[p + 1])))
            let b = max(0.0, min(1.0, Double(pixels[p + 2])))
            let y = max(0.0, min(1.0, 0.2627 * r + 0.6780 * g + 0.0593 * b))
            let index = min(bins - 1, max(0, Int((y * Double(bins - 1)).rounded(.down))))
            histogram[index] += 1
        }

        // Ignore one-off bins the same way mature open Levels implementations avoid
        // letting a single hot/dead pixel define the whole photograph.
        let low = histogram.firstIndex(where: { $0 > 1 }) ?? histogram.firstIndex(where: { $0 > 0 })
        let high = histogram.lastIndex(where: { $0 > 1 }) ?? histogram.lastIndex(where: { $0 > 0 })
        guard let low, let high, high > low else { return nil }

        let black = Double(low) / Double(bins - 1)
        let white = Double(high) / Double(bins - 1)
        guard white - black > 1.0e-6 else { return nil }
        return (black, white)
    }

    static func apply(
        r: Double, g: Double, b: Double,
        bounds: (black: Double, white: Double)
    ) -> (Double, Double, Double) {
        let y = 0.2627 * r + 0.6780 * g + 0.0593 * b
        let width = bounds.white - bounds.black
        guard width > 1.0e-9 else { return (r, g, b) }

        let targetY = (y - bounds.black) / width
        if y <= 1.0e-9 {
            return targetY <= 0 ? (0, 0, 0) : (r, g, b)
        }

        let ratio = targetY / y
        return (r * ratio, g * ratio, b * ratio)
    }
}

extension PixelBufferF32 {
    func applyingHostGrade(tone: ToneSettings?, density: ColorDensitySettings?) -> PixelBufferF32 {
        let tone = tone ?? ToneSettings()
        let points = ToneCurveMath.normalize(tone.curvePoints)
        let cache = ToneCurveMath.buildCache(points)
        let identityCurve = points.count == 2
            && abs(points[0].x) < 1e-9 && abs(points[0].y) < 1e-9
            && abs(points[1].x - 1) < 1e-9 && abs(points[1].y - 1) < 1e-9

        let autoContrastBounds = tone.autoContrast ? AutoContrastMath.bounds(pixels) : nil
        let exposureScale = pow(2.0, max(-10, min(10, tone.exposureEV)))
        let whiteGain = SourcedToneMath.whiteGain(tone.whites)
        let blackOffset = SourcedToneMath.blackOffset(tone.blacks)
        let toneIdentity = abs(tone.exposureEV) < 1e-12 && abs(tone.brightness) < 1e-12
            && abs(tone.contrast) < 1e-12 && abs(tone.midtones) < 1e-12
            && abs(tone.highlights) < 1e-12 && abs(tone.shadows) < 1e-12
            && abs(tone.highlightRecovery) < 1e-12 && abs(tone.shadowRecovery) < 1e-12
            && abs(tone.whites) < 1e-12 && abs(tone.blacks) < 1e-12
            && abs(tone.whitePoint) < 1e-12 && abs(tone.blackPoint) < 1e-12
            && !tone.autoContrast && identityCurve
        if toneIdentity && (density == nil || density!.isIdentity) { return self }

        var output = pixels
        let rowStride = width * 4
        output.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: height) { y in
                if Task.isCancelled { return }
                let rowStart = y * rowStride
                let rowEnd = min(rowStart + rowStride, buffer.count)
                for p in stride(from: rowStart, to: rowEnd, by: 4) {
                    var r = Double(buffer[p])
            var g = Double(buffer[p+1])
            var b = Double(buffer[p+2])
            if let autoContrastBounds {
                (r, g, b) = AutoContrastMath.apply(r: r, g: g, b: b, bounds: autoContrastBounds)
            }
            r *= exposureScale
            g *= exposureScale
            b *= exposureScale
            (r,g,b) = SourcedToneMath.filmicBrightness(r: r, g: g, b: b, value: tone.brightness)
            (r,g,b) = SourcedToneMath.midtones(r: r, g: g, b: b, value: tone.midtones)
            (r,g,b) = SourcedToneMath.applyLinearTone(
                r: r, g: g, b: b,
                contrast: tone.contrast, shadows: tone.shadows, highlights: tone.highlights
            )
            (r,g,b) = SourcedToneMath.highlightRecovery(r: r, g: g, b: b, value: tone.highlightRecovery)
            (r,g,b) = SourcedToneMath.shadowRecovery(r: r, g: g, b: b, value: tone.shadowRecovery)

            var er = AlcedoACEScc.encode(r)
            var eg = AlcedoACEScc.encode(g)
            var eb = AlcedoACEScc.encode(b)

            er = SourcedToneMath.remapPoints(er, blackPoint: tone.blackPoint, whitePoint: tone.whitePoint)
            eg = SourcedToneMath.remapPoints(eg, blackPoint: tone.blackPoint, whitePoint: tone.whitePoint)
            eb = SourcedToneMath.remapPoints(eb, blackPoint: tone.blackPoint, whitePoint: tone.whitePoint)

            er = er * whiteGain + blackOffset
            eg = eg * whiteGain + blackOffset
            eb = eb * whiteGain + blackOffset

            if !identityCurve {
                er = ToneCurveMath.evaluate(er, points: points, cache: cache)
                eg = ToneCurveMath.evaluate(eg, points: points, cache: cache)
                eb = ToneCurveMath.evaluate(eb, points: points, cache: cache)
            }

            (er,eg,eb) = PrimeraDensityMath.apply((er,eg,eb), settings: density)
                    buffer[p] = Float(AlcedoACEScc.decode(er))
                    buffer[p+1] = Float(AlcedoACEScc.decode(eg))
                    buffer[p+2] = Float(AlcedoACEScc.decode(eb))
                }
            }
        }
        if Task.isCancelled { return self }
        return PixelBufferF32(width: width, height: height, pixels: output)
    }

    // Compatibility wrapper for older call sites and project tests.
    func applyingToneGrade(_ settings: ToneSettings?) -> PixelBufferF32 {
        applyingHostGrade(tone: settings, density: nil)
    }
}
