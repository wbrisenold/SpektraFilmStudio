import Foundation

/// Review filters use the saved, explainable cull measurements. They never delete files.
enum CullReviewFilter: String, CaseIterable, Identifiable {
    case all = "All Photos"
    case best = "Suggested Best"
    case aesthetics = "Strong Aesthetics"
    case faces = "Has Faces"
    case sharpFaces = "Sharp Faces"
    case possibleBlink = "Possible Blinks"
    case soft = "Soft / Back Focus"
    case exposure = "Exposure Issues"
    case noise = "High Noise"
    case duplicates = "Burst / Duplicates"
    case unreviewed = "Unreviewed"
    var id: String { rawValue }

    func includes(_ image: ProjectImageRecord) -> Bool {
        let a = image.cullAnalysis
        switch self {
        case .all: return true
        case .best: return image.flag == .picked || (a?.recommendation == .keep && (a?.score ?? 0) >= 75)
        case .aesthetics: return (a?.aestheticScore ?? -1) >= 0.30
        case .faces: return (a?.faceCount ?? 0) > 0
        case .sharpFaces:
            return (a?.faceCount ?? 0) > 0 && (a?.faceSharpness ?? 0) >= 0.65 && !(a?.possibleBlink ?? false)
        case .possibleBlink: return a?.possibleBlink == true
        case .soft: return (a?.sharpness ?? 1) < 0.36 || ((a?.faceCount ?? 0) > 0 && (a?.faceSharpness ?? 1) < 0.38)
        case .exposure: return (a?.highlightClipPercent ?? 0) > 2.5 || (a?.shadowClipPercent ?? 0) > 20
        case .noise: return (a?.noiseEstimate ?? 0) > 0.42
        case .duplicates: return (a?.stackCount ?? 0) > 1
        case .unreviewed: return image.flag == .unflagged
        }
    }
}

/// Folder-local, non-destructive best-frame suggestions. This ranks only analyzed
/// photos, respects explicit rejects, and takes at most one per near-duplicate burst.
/// The final percentage is capped by the number of distinct groups.
struct CullBestPicksEngine {
    static func choose(_ images: [ProjectImageRecord], fraction: Double = 0.25) -> Set<UUID> {
        let eligible = images.filter { $0.flag != .rejected && $0.cullAnalysis != nil }
        guard !eligible.isEmpty else { return [] }
        let desired = max(1, Int(ceil(Double(eligible.count) * min(1, max(0.01, fraction)))))

        let ordered = eligible.sorted {
            let lhs = effectiveScore($0)
            let rhs = effectiveScore($1)
            if lhs != rhs { return lhs > rhs }
            return $0.id.uuidString < $1.id.uuidString
        }

        // First pass: one candidate per analyzed burst; preserve diverse moments.
        var winners: [ProjectImageRecord] = []
        for candidate in ordered {
            let overlaps = winners.contains { other in
                if let stack = candidate.cullAnalysis?.stackID,
                    stack == other.cullAnalysis?.stackID
                {
                    return true
                }
                guard let a = candidate.captureDate, let b = other.captureDate,
                    abs(a.timeIntervalSince(b)) <= 4.0,
                    let h1 = candidate.cullAnalysis?.perceptualHash,
                    let h2 = other.cullAnalysis?.perceptualHash
                else { return false }
                return (h1 ^ h2).nonzeroBitCount <= 16
            }
            if !overlaps { winners.append(candidate) }
            if winners.count >= desired { break }
        }
        return Set(winners.map(\.id))
    }

    /// Facet-style burst-cull scoring weights (from ncoevoet/facet processing/burst_score.py).
    /// Defaults: aggregate 0.4, aesthetic 0.25, sharpness 0.2, blink 0.15, eyes 0.0, expression 0.0.
    private static let burstWeights = (aggregate: 0.4, aesthetic: 0.25, sharpness: 0.2, blink: 0.15, eyes: 0.0, expression: 0.0)

    static func effectiveScore(_ image: ProjectImageRecord) -> Double {
        guard let cull = image.cullAnalysis else { return 0 }
        let w = burstWeights
        // Facet burst_score: aggregate is the base cull score (0-100);
        // we normalize to 0-10 to match Facet's convention.
        let aggregateNorm = cull.score / 10.0
        let aestheticNorm = (cull.aestheticScore ?? 0) / 10.0  // Vision gives -1..1; roughly 0-10 scale
        let sharpnessNorm = min(10.0, cull.sharpness * 10.0)
        let blinkScore = cull.possibleBlink ? 0 : 10.0

        var score = aggregateNorm * w.aggregate
                  + aestheticNorm * w.aesthetic
                  + sharpnessNorm * w.sharpness
                  + blinkScore * w.blink

        // Per-face signals (Facet eyes_open / expression) — only if available.
        if cull.faceCount > 0 {
            if let eyes = cull.eyesOpenScore { score += eyes * w.eyes }
            if let expr = cull.expressionScore { score += expr * w.expression }
            // Additional factors already in CullAnalysisRecord.score:
            // face sharpness, Vision face quality, possible blink penalty.
            score += cull.faceSharpness * 13
            if let quality = cull.faceCaptureQuality { score += (quality - 0.5) * 18 }
            if cull.possibleBlink { score -= 22 }
        }
        score -= max(0, cull.highlightClipPercent - 1) * 0.8
        score -= max(0, cull.shadowClipPercent - 10) * 0.15
        // Composition bonus from Facet-style analysis.
        if let comp = cull.compositionScore { score += comp * 0.5 }
        // Dynamic range bonus.
        if let dr = cull.dynamicRangeStops { score += dr * 0.3 }
        // Color harmony bonus.
        if let ch = cull.colorHarmony { score += ch * 5.0 }
        if image.flag == .picked { score += 5 }  // do not override photographer judgment
        return score
    }
}
