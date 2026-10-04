import Foundation

extension PixelBufferF32 {
    /// Robust automatic WB for the developed linear working image. This is intentionally
    /// conservative: it searches for low-saturation, non-clipped neutrals, uses medians of
    /// log channel ratios to reject colored outliers, and falls back to weighted gray-world
    /// only when the frame contains too few neutral candidates.
    func applyingAutoWhiteBalance() -> PixelBufferF32 {
        guard width > 0, height > 0, pixels.count == width * height * 4 else { return self }

        let pixelCount = width * height
        let targetSamples = 80_000
        let sampleStride = max(1, Int((Double(pixelCount) / Double(targetSamples)).squareRoot().rounded(.down)))

        var redRatios: [Double] = []
        var blueRatios: [Double] = []
        redRatios.reserveCapacity(12_000)
        blueRatios.reserveCapacity(12_000)

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
            let red = exp(Self.robustMedian(redRatios))
            let blue = exp(Self.robustMedian(blueRatios))
            gains = Self.normalizedWBGains(red: red, green: 1.0, blue: blue)
        } else if fallbackWeight > 1.0e-6, fallbackR > 1.0e-6, fallbackG > 1.0e-6, fallbackB > 1.0e-6 {
            let avgR = fallbackR / fallbackWeight
            let avgG = fallbackG / fallbackWeight
            let avgB = fallbackB / fallbackWeight
            gains = Self.normalizedWBGains(red: avgG / avgR, green: 1.0, blue: avgG / avgB)
        } else {
            return self
        }

        var output = pixels
        output.withUnsafeMutableBufferPointer { values in
            for p in stride(from: 0, to: values.count, by: 4) {
                values[p] = Float(Double(values[p]) * gains.0)
                values[p + 1] = Float(Double(values[p + 1]) * gains.1)
                values[p + 2] = Float(Double(values[p + 2]) * gains.2)
            }
        }
        return PixelBufferF32(width: width, height: height, pixels: output)
    }

    private static func robustMedian(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        // Trim the outer 10% before taking the median. Median already rejects outliers;
        // trimming also prevents pathological saturated/color-patch frames dominating ties.
        let trim = sorted.count / 10
        let lo = min(trim, sorted.count - 1)
        let hi = max(lo + 1, sorted.count - trim)
        let kept = Array(sorted[lo..<hi])
        let mid = kept.count / 2
        if kept.count % 2 == 0 { return (kept[mid - 1] + kept[mid]) * 0.5 }
        return kept[mid]
    }

    private static func normalizedWBGains(red: Double, green: Double, blue: Double) -> (Double, Double, Double) {
        // Keep auto WB stable and believable even on frames with no true neutral object.
        let r = min(2.5, max(0.40, red))
        let g = min(2.5, max(0.40, green))
        let b = min(2.5, max(0.40, blue))
        let norm = pow(r * g * b, 1.0 / 3.0)
        guard norm.isFinite, norm > 1.0e-9 else { return (1, 1, 1) }
        return (r / norm, g / norm, b / norm)
    }
}
