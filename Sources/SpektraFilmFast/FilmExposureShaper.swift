import Foundation

/// Exposure-domain film-input shaping adapted from the radial exposure-band concept used by
/// darktable's GPLv3 tone equalizer. Corrections are computed in EV, converted to multiplicative
/// light gain, and applied immediately before the native SpektraFilm renderer.
///
/// The original native `filmExposureEv` remains the only global Film Stock Exposure EV control.
extension PixelBufferF32 {
    func applyingFilmExposureShape(_ settings: ToneSettings?) -> PixelBufferF32 {
        guard let settings else { return self }
        let hasManual = abs(settings.highlights) > 1e-9 || abs(settings.shadows) > 1e-9 ||
            abs(settings.whites) > 1e-9 || abs(settings.blacks) > 1e-9 ||
            abs(settings.brightness) > 1e-9 || abs(settings.contrast) > 1e-9 ||
            settings.highlightRecovery > 1e-9 || settings.shadowRecovery > 1e-9
        guard hasManual || settings.autoContrast else { return self }
        guard width > 0, height > 0, pixels.count == width * height * 4 else { return self }

        var out = pixels
        let autoMap: (low: Double, high: Double)?
        if settings.autoContrast {
            var samples: [Double] = []
            let step = max(1, Int(sqrt(Double(max(1, width * height / 4096)))))
            for y in stride(from: 0, to: height, by: step) {
                for x in stride(from: 0, to: width, by: step) {
                    let p = (y * width + x) * 4
                    let luma = max(1e-8, 0.2126 * Double(pixels[p]) + 0.7152 * Double(pixels[p+1]) + 0.0722 * Double(pixels[p+2]))
                    samples.append(log2(luma))
                }
            }
            if samples.count >= 16 {
                samples.sort()
                let lo = samples[Int(Double(samples.count - 1) * 0.02)]
                let hi = samples[Int(Double(samples.count - 1) * 0.98)]
                autoMap = hi - lo > 0.5 ? (lo, hi) : nil
            } else { autoMap = nil }
        } else { autoMap = nil }

        @inline(__always) func gaussian(_ ev: Double, _ center: Double, _ sigma: Double) -> Double {
            let d = (ev - center) / max(0.05, sigma)
            return exp(-0.5 * d * d)
        }
        @inline(__always) func amount(_ value: Double, _ maxEV: Double) -> Double {
            max(-1.0, min(1.0, value / 100.0)) * maxEV
        }

        for p in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[p]), g = Double(pixels[p+1]), b = Double(pixels[p+2])
            let luma = max(1e-8, 0.2126*r + 0.7152*g + 0.0722*b)
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

            if let autoMap {
                let t = max(0.0, min(1.0, (ev - autoMap.low) / (autoMap.high - autoMap.low)))
                let target = -7.0 + t * 6.8
                correction += max(-2.0, min(2.0, target - ev))
            }

            correction = max(-2.5, min(2.5, correction))
            let gain = exp2(correction)
            out[p] = Float(r * gain)
            out[p+1] = Float(g * gain)
            out[p+2] = Float(b * gain)
        }
        return PixelBufferF32(width: width, height: height, pixels: out)
    }
}
