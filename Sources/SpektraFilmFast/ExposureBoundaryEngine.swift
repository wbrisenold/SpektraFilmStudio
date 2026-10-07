import Foundation

/// Final-display Auto Contrast guard. Measures the film-rendered SDR signal using the
/// exact same canonical linear-sRGB conversion as the clipping diagnostics, then
/// uses a gentle luminance gain to approach (but not cross) configured thresholds.
/// Never runs for manual grades; both scene and film Auto Contrast are opt-in.
/// Unsupported output spaces and non-display roles are left untouched.
enum ExposureBoundaryEngine {
    static func apply(_ input: PixelBufferF32, look: RenderLook, preferences: AppPreferences) -> PixelBufferF32 {
        guard (look.tone?.autoContrast ?? false) || (look.filmTone?.autoContrast ?? false),
              input.width > 0, input.height > 0, input.pixels.count >= 4,
              SkinToneReference.outputRoleIndex(look) == 0 else { return input }
        let space = SkinToneReference.outputSpaceIndex(look)
        guard [14, 15, 16, 17, 18, 22, 23, 24, 25].contains(space) else { return input }

        // Subsample at most ~40k pixels and reject isolated hot/dead pixels with
        // asymmetric quantiles. The statistics are *recomputed per photo*.
        let count = input.width * input.height
        let stridePixels = max(1, count / 40_000)
        var lumas: [Float] = []
        lumas.reserveCapacity(min(count, 40_001))
        for i in stride(from: 0, to: count, by: stridePixels) {
            let p = i * 4
            guard let linear = SkinToneReference.canonicalLinearSRGBUnclamped(
                r: input.pixels[p], g: input.pixels[p+1], b: input.pixels[p+2], look: look
            ) else { return input }
            let y = 0.2126 * linear.0 + 0.7152 * linear.1 + 0.0722 * linear.2
            if y.isFinite { lumas.append(y) }
        }
        guard lumas.count >= 32 else { return input }
        lumas.sort()
        let highIndex = min(lumas.count - 1, Int(Double(lumas.count - 1) * 0.998))
        let lowIndex = min(highIndex, Int(Double(lumas.count - 1) * 0.002))
        let low = Double(lumas[lowIndex])
        let high = Double(lumas[highIndex])
        guard high > low + 0.0001 else { return input }

        // Safety margin below the hard clipping lines. The visual risk warning
        // threshold is deliberately crossed by near-white content before hard clip.
        let targetHigh = max(0.90, min(0.994, preferences.clippingHighlightThreshold - 0.008))
        let targetLow = max(0.001, min(0.015, preferences.clippingShadowThreshold * 8.0))
        guard targetHigh > targetLow else { return input }
        let scale = (targetHigh - targetLow) / (high - low)
        // Avoid over-amplifying noise on extreme low-contrast frames.
        guard scale.isFinite, scale >= 0.20, scale <= 12.0 else { return input }

        var output = input.pixels
        for p in stride(from: 0, to: output.count, by: 4) {
            let native = (Double(output[p]), Double(output[p+1]), Double(output[p+2]))
            let linear = (decode(native.0, space), decode(native.1, space), decode(native.2, space))
            let y = 0.2126 * linear.0 + 0.7152 * linear.1 + 0.0722 * linear.2
            if !y.isFinite { continue }
            var desired = targetLow + (y - low) * scale
            // Compress statistical outliers rather than injecting hard clipping.
            if desired > targetHigh {
                let headroom = max(0.0001, 1.0 - targetHigh)
                desired = targetHigh + headroom * (1 - exp(-(desired - targetHigh) / headroom))
            } else if desired < targetLow {
                desired = max(0, targetLow * exp((desired - targetLow) / max(0.001, targetLow)))
            }
            // Add a neutral offset for pure black, while retaining a pixel's channel
            // ratios elsewhere. Limit negative/over-range values safely.
            let adjusted: (Double, Double, Double)
            if y > 1e-9 {
                let gain = max(0, min(16, desired / y))
                adjusted = (linear.0 * gain, linear.1 * gain, linear.2 * gain)
            } else {
                adjusted = (linear.0 + desired, linear.1 + desired, linear.2 + desired)
            }
            output[p] = Float(encode(adjusted.0, space))
            output[p+1] = Float(encode(adjusted.1, space))
            output[p+2] = Float(encode(adjusted.2, space))
            // Preserve alpha.
        }
        return PixelBufferF32(width: input.width, height: input.height, pixels: output)
    }

    private static func decode(_ x: Double, _ space: Int) -> Double {
        let sign = x < 0 ? -1.0 : 1.0
        let a = abs(x)
        switch space {
        case 14, 15, 16: return x
        case 17, 18:
            return sign * (a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4))
        case 22: return sign * pow(a, 2.2)
        case 23: return sign * pow(a, 2.6)
        case 24: return sign * pow(a, 2.2)
        case 25: return sign * pow(a, 2.4)
        default: return x
        }
    }

    private static func encode(_ x: Double, _ space: Int) -> Double {
        let sign = x < 0 ? -1.0 : 1.0
        let a = abs(x)
        switch space {
        case 14, 15, 16: return x
        case 17, 18:
            return sign * (a <= 0.0031308 ? 12.92 * a : 1.055 * pow(a, 1.0 / 2.4) - 0.055)
        case 22: return sign * pow(a, 1.0 / 2.2)
        case 23: return sign * pow(a, 1.0 / 2.6)
        case 24: return sign * pow(a, 1.0 / 2.2)
        case 25: return sign * pow(a, 1.0 / 2.4)
        default: return x
        }
    }
}
