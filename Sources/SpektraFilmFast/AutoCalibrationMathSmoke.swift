import Foundation

// Pre-existing --self-test harness: pure math only, no Metal, no photo fixtures.
enum AutoCalibrationMathSmoke {
    static func run() throws {
        func buffer(_ fill: (Int) -> Float, width: Int = 64, height: Int = 64) -> [Float] {
            var pixels = [Float](repeating: 1, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    let v = fill(y * width + x)
                    pixels[i] = v
                    pixels[i + 1] = v
                    pixels[i + 2] = v
                    pixels[i + 3] = 1
                }
            }
            return pixels
        }

        // Flat mid-gray (~0.18 linear Rec.709 luma) → near-zero auto exposure.
        let gray = buffer { _ in 0.18 }
        let grayEV = AutoCalibrationMath.developExposureEV(pixels: gray)
        guard grayEV.isFinite, abs(grayEV) < 0.35 else {
            throw RendererError.renderFailed("AUTO_EXPOSURE_MID_GRAY_FAIL: EV \(grayEV)")
        }

        // Dark frame → positive EV (brighten).
        let dark = buffer { _ in 0.02 }
        let darkEV = AutoCalibrationMath.developExposureEV(pixels: dark)
        guard darkEV.isFinite, darkEV > 0.5 else {
            throw RendererError.renderFailed("AUTO_EXPOSURE_DARK_FAIL: EV \(darkEV)")
        }

        // Blown frame → negative EV (darken).
        let blown = buffer { _ in 0.95 }
        let blownEV = AutoCalibrationMath.developExposureEV(pixels: blown)
        guard blownEV.isFinite, blownEV < -0.2 else {
            throw RendererError.renderFailed("AUTO_EXPOSURE_BLOWN_FAIL: EV \(blownEV)")
        }

        // Clamp keeps one click off the ±5 EV slider edge.
        let pitchBlack = buffer { _ in 0.0001 }
        let clampedEV = AutoCalibrationMath.developExposureEV(pixels: pitchBlack)
        guard clampedEV.isFinite, clampedEV <= 3.0, clampedEV >= -3.0 else {
            throw RendererError.renderFailed("AUTO_EXPOSURE_CLAMP_FAIL: EV \(clampedEV)")
        }

        // Idempotence: same buffer, same result.
        guard AutoCalibrationMath.developExposureEV(pixels: gray) == grayEV else {
            throw RendererError.renderFailed("AUTO_EXPOSURE_IDEMPOTENCE_FAIL")
        }

        // Known black/white ramp → resolveContrast within expected pair.
        var ramp = [Float](repeating: 1, count: 32 * 32 * 4)
        for y in 0..<32 {
            for x in 0..<32 {
                let i = (y * 32 + x) * 4
                let v = Float(x) / 31.0
                ramp[i] = v
                ramp[i + 1] = v
                ramp[i + 2] = v
            }
        }
        guard let bounds = AutoCalibrationMath.resolveContrast(pixels: ramp) else {
            throw RendererError.renderFailed("AUTO_CONTRAST_RAMP_FAIL: nil bounds")
        }
        guard bounds.black >= 0, bounds.white <= 1, bounds.white - bounds.black > 0.5,
            bounds.black < 0.15, bounds.white > 0.85
        else {
            throw RendererError.renderFailed("AUTO_CONTRAST_RAMP_FAIL: \(bounds)")
        }

        // AutoContrastMath.bounds parity on the same ramp.
        guard let expected = AutoContrastMath.bounds(ramp) else {
            throw RendererError.renderFailed("AUTO_CONTRAST_PARITY_FAIL: AutoContrastMath.bounds nil")
        }
        guard abs(bounds.black - expected.black) < 1e-9,
            abs(bounds.white - expected.white) < 1e-9
        else {
            throw RendererError.renderFailed("AUTO_CONTRAST_PARITY_FAIL: \(bounds) vs \(expected)")
        }

        // Neutral frame → gains near 1.
        let neutral = buffer { _ in 0.2 }
        guard let neutralGains = AutoCalibrationMath.whiteBalanceGains(width: 64, height: 64, pixels: neutral) else {
            throw RendererError.renderFailed("AUTO_WB_NEUTRAL_FAIL: nil gains")
        }
        guard abs(neutralGains.r - 1) < 0.05, abs(neutralGains.g - 1) < 0.05, abs(neutralGains.b - 1) < 0.05 else {
            throw RendererError.renderFailed("AUTO_WB_NEUTRAL_FAIL: \(neutralGains)")
        }

        // Mild warm cast (R high, B low, sat < 0.20 neutral threshold).
        // Heavily saturated warm frames intentionally return nil (conservative solver).
        var warmPixels = buffer { _ in 0.2 }
        for i in stride(from: 0, to: warmPixels.count, by: 4) {
            warmPixels[i] = 0.22
            warmPixels[i + 1] = 0.20
            warmPixels[i + 2] = 0.17
        }
        guard let warmGains = AutoCalibrationMath.whiteBalanceGains(width: 64, height: 64, pixels: warmPixels) else {
            throw RendererError.renderFailed("AUTO_WB_WARM_FAIL: nil gains")
        }
        guard warmGains.r < warmGains.g, warmGains.b > warmGains.g, warmGains.r < 1.0, warmGains.b > 1.0 else {
            throw RendererError.renderFailed("AUTO_WB_WARM_FAIL: \(warmGains)")
        }

        // Idempotence on gains.
        guard let again = AutoCalibrationMath.whiteBalanceGains(width: 64, height: 64, pixels: warmPixels),
            abs(again.r - warmGains.r) < 1e-12, abs(again.b - warmGains.b) < 1e-12
        else {
            throw RendererError.renderFailed("AUTO_WB_IDEMPOTENCE_FAIL")
        }

        // Gains → temperature/tint offsets (Task 4): warm cast cools, green cast magentas.
        let neutralOffsets = AutoCalibrationMath.whiteBalanceOffsets(gains: neutralGains)
        guard abs(neutralOffsets.mired) < 5.0, abs(neutralOffsets.tint) < 5.0 else {
            throw RendererError.renderFailed("AUTO_WB_OFFSETS_NEUTRAL_FAIL: \(neutralOffsets)")
        }
        let warmOffsets = AutoCalibrationMath.whiteBalanceOffsets(gains: warmGains)
        guard warmOffsets.mired > 0.0, warmOffsets.mired <= 80.0 else {
            throw RendererError.renderFailed("AUTO_WB_OFFSETS_WARM_FAIL: \(warmOffsets)")
        }
        var greenPixels = buffer { _ in 0.2 }
        for i in stride(from: 0, to: greenPixels.count, by: 4) {
            greenPixels[i] = 0.17
            greenPixels[i + 1] = 0.22
            greenPixels[i + 2] = 0.20
        }
        if let greenGains = AutoCalibrationMath.whiteBalanceGains(width: 64, height: 64, pixels: greenPixels) {
            let greenOffsets = AutoCalibrationMath.whiteBalanceOffsets(gains: greenGains)
            guard greenOffsets.tint > 0.0, greenOffsets.tint <= 60.0 else {
                throw RendererError.renderFailed("AUTO_WB_OFFSETS_GREEN_FAIL: \(greenOffsets)")
            }
        }

        // Resolve-once fields (Task 2): pure helpers + Codable.
        var tone = ToneSettings()
        guard !tone.isAutoContrastResolved else {
            throw RendererError.renderFailed("AUTO_CONTRAST_RESOLVE_DEFAULT_FAIL")
        }
        if let resolvedBounds = AutoContrastMath.bounds(ramp) {
            tone = tone.applyingResolvedAutoContrast(black: resolvedBounds.black, white: resolvedBounds.white)
            guard tone.autoContrast, tone.isAutoContrastResolved,
                tone.resolvedAutoContrastBlack == resolvedBounds.black,
                tone.resolvedAutoContrastWhite == resolvedBounds.white
            else {
                throw RendererError.renderFailed("AUTO_CONTRAST_RESOLVE_APPLY_FAIL: \(tone)")
            }
            // Explicit AutoContrastMath.apply with the same bounds stays finite on the ramp.
            for p in stride(from: 0, to: ramp.count, by: 4) {
                let (r, g, b) = AutoContrastMath.apply(
                    r: Double(ramp[p]), g: Double(ramp[p + 1]), b: Double(ramp[p + 2]),
                    bounds: resolvedBounds
                )
                guard r.isFinite, g.isFinite, b.isFinite else {
                    throw RendererError.renderFailed("AUTO_CONTRAST_RESOLVE_APPLY_NONFINITE")
                }
            }
        }
        let cleared = tone.clearingAutoContrast()
        guard !cleared.autoContrast, !cleared.isAutoContrastResolved,
            cleared.resolvedAutoContrastBlack == nil, cleared.resolvedAutoContrastWhite == nil
        else {
            throw RendererError.renderFailed("AUTO_CONTRAST_RESOLVE_CLEAR_FAIL")
        }
        let toneRoundTrip = try JSONDecoder().decode(ToneSettings.self, from: JSONEncoder().encode(tone))
        guard toneRoundTrip.resolvedAutoContrastBlack == tone.resolvedAutoContrastBlack,
            toneRoundTrip.resolvedAutoContrastWhite == tone.resolvedAutoContrastWhite,
            toneRoundTrip.autoContrast == tone.autoContrast
        else {
            throw RendererError.renderFailed("AUTO_CONTRAST_RESOLVE_CODABLE_FAIL")
        }
        var raw = RawSettings()
        raw.autoExposureApplied = true
        raw.developExposureEV = 0.42
        let rawRoundTrip = try JSONDecoder().decode(RawSettings.self, from: JSONEncoder().encode(raw))
        guard rawRoundTrip.autoExposureApplied, abs(rawRoundTrip.developExposureEV - 0.42) < 1e-12 else {
            throw RendererError.renderFailed("AUTO_EXPOSURE_APPLIED_CODABLE_FAIL")
        }
        let rawLegacy = RawSettings()
        let rawLegacyRoundTrip = try JSONDecoder().decode(
            RawSettings.self,
            from: JSONEncoder().encode(rawLegacy)
        )
        guard !rawLegacyRoundTrip.autoExposureApplied else {
            throw RendererError.renderFailed("AUTO_EXPOSURE_APPLIED_DEFAULT_FAIL")
        }

        // GPU gates (Task 3): resolved auto is live-safe; unresolved is not.
        var look = RenderLook()
        look.raw.developExposureEV = 0.42
        look.raw.autoExposureApplied = true
        guard GPULiveFramePipeline.supports(look) else {
            throw RendererError.renderFailed("GPU_GATE_SUPPORTS_FAIL: resolved auto exposure should be supported")
        }
        look.tone = ToneSettings()
        look.tone?.autoContrast = true
        guard !GPULiveFramePipeline.supports(look) else {
            throw RendererError.renderFailed("GPU_GATE_SUPPORTS_FAIL: unresolved auto contrast should block")
        }
        if let bounds = AutoContrastMath.bounds(ramp) {
            look.tone = look.tone?.applyingResolvedAutoContrast(black: bounds.black, white: bounds.white)
            guard GPULiveFramePipeline.supports(look) else {
                throw RendererError.renderFailed("GPU_GATE_SUPPORTS_FAIL: resolved auto contrast should be supported")
            }
        }

        // Task 7: legacy look (auto flags only, resolved fields absent) decodes,
        // resolves once, blocks the GPU path until resolved, then round-trips.
        var legacyLook = RenderLook(flavor: .pro)
        legacyLook.tone = ToneSettings()
        legacyLook.tone?.autoContrast = true
        let decodedLegacy = try JSONDecoder().decode(
            RenderLook.self, from: JSONEncoder().encode(legacyLook)
        )
        guard decodedLegacy.tone?.autoContrast == true, decodedLegacy.tone?.isAutoContrastResolved != true else {
            throw RendererError.renderFailed("LEGACY_AUTO_DECODE_FAIL: \(String(describing: decodedLegacy.tone))")
        }
        guard !GPULiveFramePipeline.supports(decodedLegacy) else {
            throw RendererError.renderFailed(
                "LEGACY_AUTO_BLOCK_FAIL: unresolved legacy auto should block the live path")
        }
        var resolvedLook = decodedLegacy
        if let bounds = AutoContrastMath.bounds(ramp) {
            resolvedLook.tone = decodedLegacy.tone?.applyingResolvedAutoContrast(
                black: bounds.black, white: bounds.white
            )
        }
        resolvedLook.raw.autoExposureApplied = true
        guard GPULiveFramePipeline.supports(resolvedLook) else {
            throw RendererError.renderFailed("LEGACY_AUTO_RESOLVE_FAIL: resolved legacy auto should be live-safe")
        }
        let resolvedRoundTrip = try JSONDecoder().decode(
            RenderLook.self, from: JSONEncoder().encode(resolvedLook)
        )
        guard resolvedRoundTrip.tone?.autoContrast == true,
            resolvedRoundTrip.tone?.isAutoContrastResolved == true,
            resolvedRoundTrip.raw.autoExposureApplied
        else {
            throw RendererError.renderFailed("LEGACY_AUTO_CODABLE_FAIL: resolve lost the auto flag or bounds")
        }

        print("AUTO_CALIBRATION_SMOKE_PASS: exposure, contrast, WB pure math")
        print("AUTO_RESOLVE_ONCE_SMOKE_PASS: resolved bounds, clear, codable round-trips")
        print("AUTO_GPU_GATE_SMOKE_PASS: supports() accepts resolved, blocks unresolved")
        print("AUTO_WB_OFFSETS_SMOKE_PASS: gains map to mired/tint with sign and clamp")
        print("LEGACY_AUTO_RESOLVE_PASS: legacy look decodes, blocks, resolves, re-encodes")
    }
}
