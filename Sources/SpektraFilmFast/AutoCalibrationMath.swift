import Foundation

/// One-shot auto calibration helpers. Darktable's iop/exposure.c percentile
/// meter and channelmixerrgb auto-WB run once per explicit user action (or
/// once at gesture begin), never inside a per-frame render.
enum AutoCalibrationMath {
    /// Develop-stage auto exposure in EV, targeting mid-gray ≈ 0.18 linear.
    /// Sampled from the already-developed linear working buffer (same domain
    /// as StudioImportCalibrationEstimator). Clamped to ±3 EV so one button
    /// press cannot slam the RAW exposure slider to its ±5 EV edge.
    static func developExposureEV(pixels: [Float]) -> Double {
        guard pixels.count >= 4 else { return 0 }
        // Bounded lattice like StudioImportCalibrationEstimator (~320px long edge).
        let pixelCount = pixels.count / 4
        let strideXY = max(1, Int(Double(pixelCount).squareRoot() / 320))
        var lumas: [Double] = []
        lumas.reserveCapacity(80000)
        var p = 0
        while p + 2 < pixels.count {
            let r = Double(pixels[p])
            let g = Double(pixels[p + 1])
            let b = Double(pixels[p + 2])
            if r.isFinite, g.isFinite, b.isFinite {
                let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
                if y.isFinite, y > 1e-6, y < 64 {
                    lumas.append(y)
                }
            }
            p += 4 * strideXY
        }
        guard lumas.count >= 16 else { return 0 }
        lumas.sort()
        let median = lumas[lumas.count / 2]
        let upper = lumas[min(lumas.count - 1, Int(Double(lumas.count - 1) * 0.995))]
        guard median > 1e-6, median.isFinite else { return 0 }
        let targetEV = log2(0.18 / median)
        let guardEV = upper > 0.01 ? log2(0.98 / upper) : targetEV
        let ev = min(targetEV, guardEV)
        guard ev.isFinite else { return 0 }
        return min(3.0, max(-3.0, ev))
    }

    /// Black/white placement for Auto Contrast. Same algorithm and domain as
    /// AutoContrastMath.bounds so the host grade and this one-shot button agree.
    static func resolveContrast(pixels: [Float]) -> (black: Double, white: Double)? {
        AutoContrastMath.bounds(pixels)
    }

    /// RGB gains that neutralize a color cast, same solver as
    /// PixelBufferF32.applyingAutoWhiteBalance() but without mutating pixels.
    /// UI layer converts gains to temperature/tint; raw layer may apply gains.
    static func whiteBalanceGains(
        width: Int, height: Int, pixels: [Float],
    ) -> (r: Double, g: Double, b: Double)? {
        guard width > 0, height > 0, pixels.count == width * height * 4 else { return nil }

        let pixelCount = width * height
        let targetSamples = 80000
        let sampleStride = max(1, Int((Double(pixelCount) / Double(targetSamples)).squareRoot().rounded(.down)))

        var redRatios: [Double] = []
        var blueRatios: [Double] = []
        redRatios.reserveCapacity(12000)
        blueRatios.reserveCapacity(12000)

        var fallbackR = 0.0, fallbackG = 0.0, fallbackB = 0.0, fallbackWeight = 0.0

        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let i = (y * width + x) * 4
                let r = max(0.0, Double(pixels[i]))
                let g = max(0.0, Double(pixels[i + 1]))
                let b = max(0.0, Double(pixels[i + 2]))
                let maxC = max(r, max(g, b))
                let minC = min(r, min(g, b))
                let luma = 0.2627 * r + 0.6780 * g + 0.0593 * b
                if luma > 0.025, luma < 0.88, maxC > 1.0e-6 {
                    let saturation = (maxC - minC) / maxC
                    let weight = max(0.0, 1.0 - min(1.0, saturation / 0.55))
                    fallbackR += r * weight
                    fallbackG += g * weight
                    fallbackB += b * weight
                    fallbackWeight += weight

                    if saturation < 0.20, r > 1.0e-6, g > 1.0e-6, b > 1.0e-6 {
                        redRatios.append(log(g / r))
                        blueRatios.append(log(g / b))
                    }
                }
                x += sampleStride
            }
            y += sampleStride
        }

        let gains: (Double, Double, Double)
        if redRatios.count >= 96, blueRatios.count >= 96 {
            let red = exp(robustMedian(redRatios))
            let blue = exp(robustMedian(blueRatios))
            gains = normalizedWBGains(red: red, green: 1.0, blue: blue)
        } else if fallbackWeight > 1.0e-6, fallbackR > 1.0e-6, fallbackG > 1.0e-6, fallbackB > 1.0e-6 {
            let avgR = fallbackR / fallbackWeight
            let avgG = fallbackG / fallbackWeight
            let avgB = fallbackB / fallbackWeight
            gains = normalizedWBGains(red: avgG / avgR, green: 1.0, blue: avgG / avgB)
        } else {
            return nil
        }
        guard gains.0.isFinite, gains.1.isFinite, gains.2.isFinite else { return nil }
        return gains
    }

    /// Neutralizing gains → camera-space temperature/tint offsets from the as-shot base.
    /// Convention matches SkinWB: positive mired → cooler, positive tint → magenta.
    static func whiteBalanceOffsets(
        gains: (r: Double, g: Double, b: Double),
    ) -> (mired: Double, tint: Double) {
        // Warm cast (blue gain above red gain) → positive mired (cooler result).
        let logBR = log(max(1.0e-6, gains.b) / max(1.0e-6, gains.r))
        // Green cast (red/blue gains above green gain) → positive tint (magenta result).
        let logGM = log(max(1.0e-6, sqrt(max(1.0e-12, gains.r * gains.b))) / max(1.0e-6, gains.g))
        // Empirical scales so a mild cast lands in a usable slider range.
        return (max(-80, min(80, logBR * 80)), max(-60, min(60, logGM * 60)))
    }

    private static func robustMedian(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let trim = sorted.count / 10
        let lo = min(trim, sorted.count - 1)
        let hi = max(lo + 1, sorted.count - trim)
        let kept = Array(sorted[lo ..< hi])
        let mid = kept.count / 2
        if kept.count % 2 == 0 {
            return (kept[mid - 1] + kept[mid]) * 0.5
        }
        return kept[mid]
    }

    private static func normalizedWBGains(red: Double, green: Double, blue: Double) -> (Double, Double, Double) {
        let r = min(2.5, max(0.40, red))
        let g = min(2.5, max(0.40, green))
        let b = min(2.5, max(0.40, blue))
        let norm = pow(r * g * b, 1.0 / 3.0)
        guard norm.isFinite, norm > 1.0e-9 else { return (1, 1, 1) }
        return (r / norm, g / norm, b / norm)
    }
}
