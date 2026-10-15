import Foundation

/// Exposure-domain film-input shaping adapted from the radial exposure-band concept used by
/// darktable's GPLv3 tone equalizer. Corrections are computed in EV, converted to multiplicative
/// light gain, and applied immediately before the native SpektraFilm renderer.
///
/// The original native `filmExposureEv` remains the only global Film Stock Exposure EV control.
extension PixelBufferF32 {
    func referenceFilmExposureShape(_ settings: ToneSettings?) -> PixelBufferF32 {
        guard let settings else { return self }
        let hasManual =
            abs(settings.highlights) > 1e-9 || abs(settings.shadows) > 1e-9 || abs(settings.whites) > 1e-9
            || abs(settings.blacks) > 1e-9 || abs(settings.brightness) > 1e-9 || abs(settings.contrast) > 1e-9
            || settings.highlightRecovery > 1e-9 || settings.shadowRecovery > 1e-9
        guard hasManual || settings.autoContrast else { return self }
        guard width > 0, height > 0, pixels.count == width * height * 4 else { return self }

        var out = pixels
        // Auto contrast must meter exactly like the GPU: a 16384-bin histogram on
        // clamped linear Rec.709 luma. Metering in log2/EV with 2%/98% percentiles
        // is a different measurement, not a tolerance difference — it made the
        // fused-vs-staged parity gate fail at 0.26 relative error. Reusing
        // AutoContrastMath.bounds also means the two can never drift apart again.
        let autoMap: (low: Double, high: Double)?
        if settings.autoContrast, let metered = AutoContrastMath.bounds(pixels) {
            autoMap = (metered.black, metered.white)
        } else {
            autoMap = nil
        }
        // PERF-10: when autoMap is nil every write to `out` above is skipped, so
        // the loop only burns a full-frame copy + 7 exp() per pixel for nothing.
        // Early-return here is byte-identical to running it (verified: all
        // `out[p]` writes are inside `if let autoMap`).
        guard autoMap != nil else { return self }

        @inline(__always) func gaussian(_ ev: Double, _ center: Double, _ sigma: Double) -> Double {
            let d = (ev - center) / max(0.05, sigma)
            return exp(-0.5 * d * d)
        }
        @inline(__always) func amount(_ value: Double, _ maxEV: Double) -> Double {
            max(-1.0, min(1.0, value / 100.0)) * maxEV
        }

        for p in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[p]), g = Double(pixels[p + 1]), b = Double(pixels[p + 2])
            let luma = max(1e-8, 0.2126 * r + 0.7152 * g + 0.0722 * b)
            let ev = max(-12.0, min(4.0, log2(luma)))
            var correction = 0.0

            correction += gaussian(ev, -7.0, 1.10) * amount(settings.blacks, 2.0)
            correction += gaussian(ev, -4.5, 1.35) * amount(settings.shadows, 2.0)
            correction += gaussian(ev, -2.5, 2.20) * amount(settings.brightness, 1.5)
            correction += gaussian(ev, -1.25, 1.25) * amount(settings.highlights, 2.0)
            correction += gaussian(ev, -0.20, 0.85) * amount(settings.whites, 2.0)

            correction -= gaussian(ev, -0.65, 1.05) * min(1.0, max(0.0, settings.highlightRecovery / 100.0)) * 2.25
            correction += gaussian(ev, -5.7, 1.25) * min(1.0, max(0.0, settings.shadowRecovery / 100.0)) * 2.25

            let contrast = max(-1.0, min(1.0, settings.contrast / 100.0))
            if abs(contrast) > 1e-9 {
                correction += max(-1.0, min(1.0, (ev + 2.5) / 3.25)) * contrast * 1.35
            }

            correction = max(-2.5, min(2.5, correction))
            let gain = exp2(correction)

            if let autoMap {
                // Mirrors the shader stage in SpektraMetalRenderer.mm: linear Rec.709
                // luma stretched from [black, white] onto [0, 1] as an unclamped
                // multiplicative ratio, applied AFTER the manual grade. Folding it
                // into `correction` instead would let the +/-2.5 EV clamp above
                // silently alter the result and reintroduce the parity gap.
                let y = 0.2627 * r * gain + 0.6780 * g * gain + 0.0593 * b * gain
                let target = (y - autoMap.low) / (autoMap.high - autoMap.low)
                if y > 1e-9 {
                    let ratio = target / y
                    out[p] = Float(r * gain * ratio)
                    out[p + 1] = Float(g * gain * ratio)
                    out[p + 2] = Float(b * gain * ratio)
                } else if target <= 0 {
                    out[p] = 0
                    out[p + 1] = 0
                    out[p + 2] = 0
                } else {
                    out[p] = Float(r * gain)
                    out[p + 1] = Float(g * gain)
                    out[p + 2] = Float(b * gain)
                }
            }
        }
        return PixelBufferF32(width: width, height: height, pixels: out)
    }
}
