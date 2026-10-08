import Foundation
import CoreGraphics
import Vision

struct DetectedFace: Sendable {
    var bounds: CGRect
    var rightEye: CGPoint
    var leftEye: CGPoint
    var nose: CGPoint
    var rightMouth: CGPoint
    var leftMouth: CGPoint
    var confidence: Double
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
            if focus >= 0.72 { reasons.append("Strong subject focus") }
            else if focus < 0.32 { reasons.append("Soft focus") }
            if metrics.highlightClip > 0.025 { reasons.append("Heavy highlight clipping") }
            if metrics.shadowClip > 0.20 { reasons.append("Deep shadow clipping") }
            if face.count > 0 { reasons.append("\(face.count) face\(face.count == 1 ? "" : "s") detected") }
            if face.possibleBlink { reasons.append("Possible blink") }
            if let faceCaptureQuality, face.count > 0 {
                reasons.append(faceCaptureQuality >= 0.65 ? "Strong Vision face capture" :
                    (faceCaptureQuality < 0.35 ? "Weak Vision face capture" : "Moderate Vision face capture"))
            }
            if let aestheticScore {
                reasons.append(aestheticScore >= 0.30 ? "Strong aesthetic composition" :
                    (aestheticScore < -0.30 ? "Lower aesthetic model score" : "Moderate aesthetic model score"))
            }
            if metrics.noise > 0.42 { reasons.append("High fine-detail noise") }
            if reasons.isEmpty { reasons.append("Balanced technical quality") }

            let recommendation: CullRecommendation
            if score >= 76, !face.possibleBlink { recommendation = .keep }
            else if score < 44 || (face.count > 0 && face.sharpness < 0.18) { recommendation = .reject }
            else { recommendation = .review }

            let record = CullAnalysisRecord(
                score: score,
                recommendation: recommendation,
                sharpness: metrics.sharpness,
                faceSharpness: face.sharpness,
                exposureQuality: exposure,
                highlightClipPercent: metrics.highlightClip * 100,
                shadowClipPercent: metrics.shadowClip * 100,
                noiseEstimate: metrics.noise,
                faceCount: face.count,
                possibleBlink: face.possibleBlink,
                perceptualHash: hash,
                stackID: nil,
                stackRank: nil,
                stackCount: nil,
                faceCaptureQuality: faceCaptureQuality,
                aestheticScore: aestheticScore,
                reasons: reasons,
                analyzedAt: Date()
            )
            return Result(record: record)
        }.value
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
        guard w > 2, h > 2 else { return BasicMetrics(sharpness: 0, highlightClip: 0, shadowClip: 0, noise: 0, contrast: 0) }
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
        guard samples > 0 else { return BasicMetrics(sharpness: 0, highlightClip: 0, shadowClip: 0, noise: 0, contrast: 0) }
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
              let result = request.results?.first else { return nil }
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
                    faces.append(DetectedFace(
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

    private nonisolated static func eyeRegionDetail(_ payload: ThumbnailPayload, center: CGPoint, radius: Double) -> Double {
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
