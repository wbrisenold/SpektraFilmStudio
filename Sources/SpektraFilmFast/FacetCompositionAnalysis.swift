import CoreGraphics
import Foundation
import Vision
import ImageIO

// MARK: - Facet-style composition analysis ported from ncoevoet/facet
// analyzers/composition.py: subject-region detection (edge contour + saliency),
// rule-of-thirds placement score, leading-lines detection.

extension CullEngine {

    /// Detect a subject bounding box using edge-contour analysis.
    /// Ported from CompositionAnalyzer.detect_subject_region: finds the largest
    /// edge contour whose centroid is near a rule-of-thirds intersection.
    ///
    /// Operates on the raw rgba pixels at full thumbnail resolution using a
    /// central-difference Sobel-like gradient (no OpenCV dependency).
    static func detectSubjectRegion(
        _ payload: ThumbnailPayload
    ) -> CGRect? {
        let w = payload.width, h = payload.height
        guard w > 20 && h > 20 else { return nil }

        // Build grayscale luma.
        var gray = [Double](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let p = i * 4
            gray[i] = 0.2126 * Double(payload.rgba[p])
                    + 0.7152 * Double(payload.rgba[p + 1])
                    + 0.0722 * Double(payload.rgba[p + 2])
        }

        // Gradient magnitude via central differences.
        var gx = [Double](repeating: 0, count: w * h)
        var gy = [Double](repeating: 0, count: w * h)
        var mag = [Double](repeating: 0, count: w * h)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                gx[i] = gray[i + 1] - gray[i - 1]
                gy[i] = gray[i + w] - gray[i - w]
                mag[i] = sqrt(gx[i] * gx[i] + gy[i] * gy[i])
            }
        }

        // Simple threshold to get edge mask; use median-based adaptive threshold
        // like Facet's adaptive Canny (median * 0.5 / 1.5).
        let sortedMag = mag.filter { $0 > 0 }.sorted()
        let medianMag: Double
        if !sortedMag.isEmpty {
            medianMag = sortedMag[sortedMag.count / 2]
        } else {
            medianMag = 10.0
        }
        _ = max(0, medianMag * 0.5)
        let upper = min(255, medianMag * 1.5)

        // Edge mask: pixels above upper threshold are strong edges.
        var edgeMap = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) {
            edgeMap[i] = mag[i] > upper
        }

        // Find contours using simple connected-component on edge pixels.
        // Use a relaxed min area like Facet (0.01% of image).
        let minArea = Double(w * h) * 0.0001

        // BFS-based contour extraction (4-connected).
        var visited = [Bool](repeating: false, count: w * h)
        var bestContour: [Int] = []
        var bestScore = 0.0

        let thirdsX = [w / 3, 2 * w / 3]
        let thirdsY = [h / 3, 2 * h / 3]

        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                guard edgeMap[i] && !visited[i] else { continue }

                // BFS this contour.
                var contour = [Int]()
                var queue = [Int]()
                queue.append(i)
                visited[i] = true
                while !queue.isEmpty {
                    let cur = queue.removeLast()
                    contour.append(cur)
                    _ = cur % w
                    _ = cur / w
                    let nexts = [
                        cur - 1, cur + 1, cur - w, cur + w
                    ]
                    for ni in nexts {
                        let nx = ni % w
                        let ny = ni / w
                        guard nx >= 0 && nx < w && ny >= 0 && ny < h else { continue }
                        let ni2 = ny * w + nx
                        if edgeMap[ni2] && !visited[ni2] {
                            visited[ni2] = true
                            queue.append(ni2)
                        }
                    }
                }

                guard contour.count >= Int(minArea) else { continue }

                // Compute centroid via moments.
                var mx: Double = 0, my: Double = 0
                for idx in contour {
                    mx += Double(idx % w)
                    my += Double(idx / w)
                }
                let cxC = mx / Double(contour.count)
                let cyC = my / Double(contour.count)

                // Score: area + proximity to thirds lines.
                let areaScore = Double(contour.count) / Double(w * h)
                let dx = thirdsX.map { abs(cxC - Double($0)) }.min() ?? 999
                let dy = thirdsY.map { abs(cyC - Double($0)) }.min() ?? 999
                let thirdsBonus = max(0, 1 - (dx / Double(w) + dy / Double(h)))
                let score = areaScore * (1 + thirdsBonus)

                if score > bestScore {
                    bestScore = score
                    bestContour = contour
                }
            }
        }

        guard !bestContour.isEmpty else { return nil }

        // Compute bounding rect of best contour.
        var minX = w, minY = h, maxX = 0, maxY = 0
        for idx in bestContour {
            minX = min(minX, idx % w)
            minY = min(minY, idx / w)
            maxX = max(maxX, idx % w)
            maxY = max(maxY, idx / w)
        }
        return CGRect(x: Double(minX), y: Double(minY),
                      width: Double(maxX - minX), height: Double(maxY - minY))
    }

    /// Score a subject bounding box against rule-of-thirds and center composition.
    /// Ported from CompositionAnalyzer.get_placement_data.
    static func placementScore(
        region: CGRect?, imgW: Int, imgH: Int
    ) -> (score: Double, powerPoint: Double, lineScore: Double, centerScore: Double) {
        if let region = region {
            let cx = (region.minX + region.maxX) / 2 / Double(imgW)
            let cy = (region.minY + region.maxY) / 2 / Double(imgH)
            let thirds: [Double] = [1.0/3.0, 2.0/3.0]
            var powerPoints: [(Double, Double)] = []
            for t1 in thirds { for t2 in thirds { powerPoints.append((t1, t2)) } }
            let minPowerDist = powerPoints.map { pow(cx - $0.0, 2) + pow(cy - $0.1, 2) }.min() ?? 1.0
            let powerPointScore = max(0, 10 - sqrt(minPowerDist) * 25)

            let distX = thirds.map { abs(cx - $0) }.min() ?? 1
            let distY = thirds.map { abs(cy - $0) }.min() ?? 1
            let lineScore = max(0, 10 - (distX + distY) * 15)

            let distCx = abs(cx - 0.5)
            let distCy = abs(cy - 0.5)
            let centerScore = max(0, 10 - (distCx + distCy) * 10)

            // Weighted: power points weighted 2x, lines 1x (Facet defaults).
            let weightedThirds = (powerPointScore * 2 + lineScore * 1) / 3
            let final = max(weightedThirds, centerScore)
            return (final, powerPointScore, lineScore, centerScore)
        } else {
            // No subject detected — neutral center assumption.
            return (7.0, 5.0, 5.0, 7.0)
        }
    }

    /// Detect leading lines via Hough-like line accumulation on edge pixels.
    /// Ported from CompositionAnalyzer.detect_leading_lines: Canny edges → Hough
    /// line segments, scored by length and diagonal angle (15-75° bonus).
    static func detectLeadingLines(
        _ payload: ThumbnailPayload
    ) -> (score: Double, count: Int) {
        let w = payload.width, h = payload.height
        guard w > 30 && h > 30 else { return (0, 0) }

        // Build edge map (reuse gradient from subject detection — but do it here
        // for simplicity since this is a separate call path).
        var gray = [Double](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let p = i * 4
            gray[i] = 0.2126 * Double(payload.rgba[p])
                    + 0.7152 * Double(payload.rgba[p + 1])
                    + 0.0722 * Double(payload.rgba[p + 2])
        }
        var mag = [Double](repeating: 0, count: w * h)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let gx = gray[i + 1] - gray[i - 1]
                let gy = gray[i + w] - gray[i - w]
                mag[i] = sqrt(gx * gx + gy * gy)
            }
        }
        let sortedMag = mag.filter { $0 > 0 }.sorted()
        let medianMag: Double = sortedMag.isEmpty ? 10 : sortedMag[sortedMag.count / 2]
        _ = max(0, medianMag * 0.5)
        let upper = min(255, medianMag * 1.5)
        var edgeMap = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) { edgeMap[i] = mag[i] > upper }

        // Gaussian blur on edge map to reduce noise (3x3 uniform).
        var blurred = [Bool](repeating: false, count: w * h)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                var sum = 0
                for dy in -1...1 { for dx in -1...1 {
                    sum += edgeMap[(y + dy) * w + (x + dx)] ? 1 : 0
                } }
                blurred[y * w + x] = sum >= 3
            }
        }

        // Hough line accumulator: vote into angle/distance bins.
        // Use a simplified approach: for each edge pixel, vote for lines through it
        // at quantized angles, then find the strongest lines.
        let angleBins = 36 // 5° resolution
        let maxDist = Int(sqrt(Double(w * w + h * h)))
        var accumulator = [Int](repeating: 0, count: angleBins * (maxDist + 1))

        for y in 0..<h {
            for x in 0..<w where blurred[y * w + x] {
                for ai in 0..<angleBins {
                    let theta = Double(ai) * .pi / Double(angleBins)
                    let d = Double(x) * cos(theta) + Double(y) * sin(theta)
                    let di = Int(d + Double(maxDist) * 0.5)
                    guard di >= 0 && di <= maxDist else { continue }
                    accumulator[ai * (maxDist + 1) + di] += 1
                }
            }
        }

        // Find peaks in accumulator (lines with many votes).
        _ = Int(Double(min(w, h)) * 0.15)
        var foundLines = [(length: Double, angle: Double)]()

        for ai in 0..<angleBins {
            let theta = Double(ai) * .pi / Double(angleBins)
            for di in 0...maxDist {
                let votes = accumulator[ai * (maxDist + 1) + di]
                guard votes > 3 else { continue } // low threshold
                // Angle in degrees.
                let angleDeg = abs(theta * 180 / .pi)
                let normalizedAngle = min(angleDeg, 180 - angleDeg)
                foundLines.append((Double(votes), normalizedAngle))
            }
        }

        guard !foundLines.isEmpty else { return (0, 0) }

        // Score each line: length (votes) * angle bonus.
        var totalScore = 0.0
        let diagonal = sqrt(Double(w * w + h * h))
        for line in foundLines {
            let angleBonus = (15...75).contains(Int(line.angle)) ? 1.5 : 1.0
            let lengthScore = (line.length / diagonal) * 10 * angleBonus
            totalScore += lengthScore
        }

        let avgScore = min(10.0, totalScore / Double(foundLines.count) * 2)
        return (avgScore, foundLines.count)
    }

    /// Integrate leading lines bonus into composition score (landscape only).
    /// Ported from CompositionAnalyzer.integrate_leading_lines.
    static func integrateLeadingLines(
        baseScore: Double, leadingLinesScore: Double, hasFaces: Bool
    ) -> Double {
        if hasFaces { return baseScore }
        let bonus = min(2.0, leadingLinesScore / 5.0)
        return min(10.0, baseScore + bonus)
    }
}
