import Foundation
import Accelerate

/// Pointer-rate visual feedback that never enters the native spectral renderer.
///
/// The exact Spektrafilm result is still the source of truth: this proxy exists only while
/// a continuous control is being manipulated. After an idle boundary AppModel replaces the
/// proxy with an exact normal-resolution Spektrafilm preview; export always uses the full-resolution
/// exact pipeline. Keeping the live path independent prevents an in-flight Metal command buffer
/// from becoming input latency.
enum InteractivePreviewProxy {
    private static let descriptorByName: [String: ParameterDescriptor] = Dictionary(
        uniqueKeysWithValues: BridgeCatalog.shared.parameters.map { ($0.name, $0) }
    )

    static func render(
        baseline: PixelBufferF32,
        baselineLook: RenderLook,
        targetLook: RenderLook,
        changedParameter: String?,
        rawField: RawInteractiveField?
    ) -> PixelBufferF32 {
        if let rawField {
            let before = baselineLook.raw
            let after = targetLook.raw
            switch rawField {
            case .temperature:
                let beforeMired = before.whiteBalanceMode == .custom
                    ? 1_000_000.0 / max(1667.0, min(50000.0, before.temperature))
                    : (before.temperatureOffsetMired ?? 0)
                let afterMired = after.whiteBalanceMode == .custom
                    ? 1_000_000.0 / max(1667.0, min(50000.0, after.temperature))
                    : (after.temperatureOffsetMired ?? 0)
                let delta = max(-120.0, min(120.0, afterMired - beforeMired))
                return baseline.pointTransform(channelStops: (delta / 115.0, 0, -delta / 115.0))
            case .tint:
                let beforeTint = before.whiteBalanceMode == .custom ? before.tint : (before.tintOffset ?? 0)
                let afterTint = after.whiteBalanceMode == .custom ? after.tint : (after.tintOffset ?? 0)
                let delta = max(-150.0, min(150.0, afterTint - beforeTint))
                return baseline.pointTransform(channelStops: (delta / 260.0, -delta / 170.0, delta / 260.0))
            }
        }

        if let name = changedParameter {
            let beforeTone = baselineLook.tone ?? ToneSettings()
            let afterTone = targetLook.tone ?? ToneSettings()
            switch name {
            case "hostExposure":
                return baseline.pointTransform(exposureStops: afterTone.exposureEV - beforeTone.exposureEV)
            case "hostContrast":
                return baseline.pointTransform(contrastDelta: (afterTone.contrast - beforeTone.contrast) / 125.0)
            case "hostHighlights":
                return baseline.pointTransform(highlightDelta: (afterTone.highlights - beforeTone.highlights) / 100.0)
            case "hostShadows":
                return baseline.pointTransform(shadowDelta: (afterTone.shadows - beforeTone.shadows) / 100.0)
            case "hostWhites":
                return baseline.pointTransform(highlightDelta: (afterTone.whites - beforeTone.whites) / 125.0)
            case "hostBlacks":
                return baseline.pointTransform(shadowDelta: (afterTone.blacks - beforeTone.blacks) / 125.0)
            case "hostToneCurve":
                // Pointer feedback only: estimate the visible curve change from the quarter,
                // middle, and three-quarter anchors. The queued native working-file render
                // replaces this frame as soon as it finishes.
                let sample = [0.25, 0.5, 0.75]
                let beforeCurve = sample.map { ToneCurveMath.evaluate($0, points: beforeTone.curvePoints) }
                let afterCurve = sample.map { ToneCurveMath.evaluate($0, points: afterTone.curvePoints) }
                let low = afterCurve[0] - beforeCurve[0]
                let mid = afterCurve[1] - beforeCurve[1]
                let high = afterCurve[2] - beforeCurve[2]
                return baseline.pointTransform(
                    exposureStops: mid * 1.5,
                    contrastDelta: (high - low) * 1.8,
                    shadowDelta: low * 1.5,
                    highlightDelta: high * 1.5
                )
            default:
                break
            }

            if name.hasPrefix("filmFeed.") {
                let beforeFilm = baselineLook.filmTone ?? ToneSettings()
                let afterFilm = targetLook.filmTone ?? ToneSettings()
                let key = String(name.dropFirst("filmFeed.".count))
                switch key {
                case "exposureEV":
                    return baseline.pointTransform(exposureStops: afterFilm.exposureEV - beforeFilm.exposureEV)
                case "brightness":
                    return baseline.pointTransform(exposureStops: (afterFilm.brightness - beforeFilm.brightness) / 125.0)
                case "contrast":
                    return baseline.pointTransform(contrastDelta: (afterFilm.contrast - beforeFilm.contrast) / 125.0)
                case "highlights":
                    return baseline.pointTransform(highlightDelta: (afterFilm.highlights - beforeFilm.highlights) / 100.0)
                case "shadows":
                    return baseline.pointTransform(shadowDelta: (afterFilm.shadows - beforeFilm.shadows) / 100.0)
                case "whites":
                    return baseline.pointTransform(highlightDelta: (afterFilm.whites - beforeFilm.whites) / 125.0)
                case "blacks":
                    return baseline.pointTransform(shadowDelta: (afterFilm.blacks - beforeFilm.blacks) / 125.0)
                case "highlightRecovery":
                    return baseline.pointTransform(highlightDelta: -(afterFilm.highlightRecovery - beforeFilm.highlightRecovery) / 135.0)
                case "shadowRecovery":
                    return baseline.pointTransform(shadowDelta: (afterFilm.shadowRecovery - beforeFilm.shadowRecovery) / 135.0)
                default:
                    break
                }
            }

            if name.hasPrefix("density.") {
                let beforeDensity = baselineLook.colorDensity ?? ColorDensitySettings()
                let afterDensity = targetLook.colorDensity ?? ColorDensitySettings()
                let beforeAverage = (beforeDensity.master + beforeDensity.red + beforeDensity.yellow + beforeDensity.green + beforeDensity.cyan + beforeDensity.blue + beforeDensity.magenta) / 7.0
                let afterAverage = (afterDensity.master + afterDensity.red + afterDensity.yellow + afterDensity.green + afterDensity.cyan + afterDensity.blue + afterDensity.magenta) / 7.0
                let d = afterAverage - beforeAverage
                return baseline.pointTransform(contrastDelta: d * 0.22, saturationDelta: d * 0.95)
            }
        }

        guard let name = changedParameter,
              let before = baselineLook.values[name],
              let after = targetLook.values[name],
              before != after else { return baseline }

        let descriptor = descriptorByName[name]
        let group = descriptor?.group ?? ""
        let delta = normalizedDelta(before: before, after: after, descriptor: descriptor)

        switch name {
        case "filmExposureEv", "printExposureEv", "hdrExposureEv":
            return baseline.pointTransform(exposureStops: scalar(after) - scalar(before))
        case "filmGamma", "printGamma":
            let b = max(0.05, scalar(before))
            let a = max(0.05, scalar(after))
            return baseline.pointTransform(gammaRatio: a / b)
        case "filterC":
            return baseline.pointTransform(channelStops: (-(scalar(after) - scalar(before)) / 60.0, 0, 0))
        case "filterMShift", "preflashMFilterShift":
            return baseline.pointTransform(channelStops: (0, -(scalar(after) - scalar(before)) / 45.0, 0))
        case "filterYShift", "preflashYFilterShift":
            return baseline.pointTransform(channelStops: (0, 0, -(scalar(after) - scalar(before)) / 45.0))
        case "printerLightR":
            return baseline.pointTransform(channelStops: ((scalar(after) - scalar(before)) / 12.0, 0, 0))
        case "printerLightG":
            return baseline.pointTransform(channelStops: (0, (scalar(after) - scalar(before)) / 12.0, 0))
        case "printerLightB":
            return baseline.pointTransform(channelStops: (0, 0, (scalar(after) - scalar(before)) / 12.0))
        case "scannerWhiteLevel", "scannerBlackLevel":
            return baseline.pointTransform(contrastDelta: delta * 0.65)
        case "scannerUnsharpAmount", "scannerUnsharpRadiusUm", "scannerMtf50LpMm":
            return baseline.localContrastProxy(amount: delta * 0.9)
        case "printShadowShape":
            return baseline.pointTransform(shadowDelta: delta * 0.8)
        case "printHighlightShape":
            return baseline.pointTransform(highlightDelta: delta * 0.8)
        case "enlargerScale", "enlargerOffsetXPercent", "enlargerOffsetYPercent":
            return baseline.geometryProxy(
                scale: targetLook.values["enlargerScale"]?.scalarValue ?? 1,
                baselineScale: baselineLook.values["enlargerScale"]?.scalarValue ?? 1,
                offsetX: targetLook.values["enlargerOffsetXPercent"]?.scalarValue ?? 0,
                baselineOffsetX: baselineLook.values["enlargerOffsetXPercent"]?.scalarValue ?? 0,
                offsetY: targetLook.values["enlargerOffsetYPercent"]?.scalarValue ?? 0,
                baselineOffsetY: baselineLook.values["enlargerOffsetYPercent"]?.scalarValue ?? 0
            )
        default:
            break
        }

        // Group-level proxies cover the remaining continuous controls. They are deliberately
        // conservative and only provide direction/amount feedback. Exact film/print physics
        // always replace them after idle and are the only pixels used for export.
        switch group {
        case "grain", "grainSynthesis":
            return baseline.grainProxy(amount: delta)
        case "halation":
            return baseline.halationProxy(amount: delta)
        case "diffusion":
            return baseline.diffusionProxy(amount: delta)
        case "scanner":
            return baseline.localContrastProxy(amount: delta * 0.6)
        case "dir":
            return baseline.pointTransform(contrastDelta: delta * 0.35, saturationDelta: delta * 0.35)
        case "film":
            return baseline.pointTransform(contrastDelta: delta * 0.25, saturationDelta: delta * 0.18)
        case "print":
            return baseline.pointTransform(contrastDelta: delta * 0.22, saturationDelta: delta * 0.12)
        case "filtering":
            return baseline.pointTransform(saturationDelta: delta * 0.2, warmthDelta: delta * 0.2)
        case "color":
            return baseline.pointTransform(exposureStops: delta * 0.35)
        default:
            return baseline.pointTransform(contrastDelta: delta * 0.15)
        }
    }

    private static func scalar(_ value: ParameterValue) -> Double {
        switch value {
        case .scalar(let v): return v
        case .int(let v): return Double(v)
        case .bool(let v): return v ? 1 : 0
        case .vector2(let x, let y): return (x + y) * 0.5
        case .vector3(let x, let y, let z): return (x + y + z) / 3.0
        }
    }

    private static func vectorMagnitude(_ value: ParameterValue) -> Double {
        switch value {
        case .scalar(let v): return v
        case .int(let v): return Double(v)
        case .bool(let v): return v ? 1 : 0
        case .vector2(let x, let y): return hypot(x, y)
        case .vector3(let x, let y, let z): return sqrt(x*x + y*y + z*z)
        }
    }

    private static func normalizedDelta(
        before: ParameterValue,
        after: ParameterValue,
        descriptor: ParameterDescriptor?
    ) -> Double {
        let raw = vectorMagnitude(after) - vectorMagnitude(before)
        let span = max(0.0001, (descriptor?.maximum ?? 1) - (descriptor?.minimum ?? 0))
        return max(-1, min(1, raw / span * 4.0))
    }
}

private extension PixelBufferF32 {
    func pointTransform(
        exposureStops: Double = 0,
        channelStops: (Double, Double, Double) = (0, 0, 0),
        gammaRatio: Double = 1,
        contrastDelta: Double = 0,
        saturationDelta: Double = 0,
        warmthDelta: Double = 0,
        shadowDelta: Double = 0,
        highlightDelta: Double = 0
    ) -> PixelBufferF32 {
        var out = pixels
        let exposure = Float(pow(2.0, max(-4, min(4, exposureStops))))
        let gains = (
            Float(pow(2.0, max(-2, min(2, channelStops.0 + warmthDelta * 0.22)))),
            Float(pow(2.0, max(-2, min(2, channelStops.1)))),
            Float(pow(2.0, max(-2, min(2, channelStops.2 - warmthDelta * 0.22))))
        )
        let gamma = Float(max(0.25, min(4, gammaRatio)))
        let contrast = Float(max(-0.8, min(0.8, contrastDelta)))
        let saturation = Float(max(-0.8, min(0.8, saturationDelta)))
        let shadows = Float(max(-0.8, min(0.8, shadowDelta)))
        let highlights = Float(max(-0.8, min(0.8, highlightDelta)))

        let count = width * height
        for i in 0..<count {
            if (i & 4095) == 0, Task.isCancelled { return self }
            let p = i * 4
            var r = out[p] * exposure * gains.0
            var g = out[p + 1] * exposure * gains.1
            var b = out[p + 2] * exposure * gains.2

            if gamma != 1 {
                r = signedPow(r, gamma)
                g = signedPow(g, gamma)
                b = signedPow(b, gamma)
            }

            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            if saturation != 0 {
                let s = 1 + saturation
                r = y + (r - y) * s
                g = y + (g - y) * s
                b = y + (b - y) * s
            }
            if contrast != 0 {
                let c = 1 + contrast
                r = 0.5 + (r - 0.5) * c
                g = 0.5 + (g - 0.5) * c
                b = 0.5 + (b - 0.5) * c
            }
            if shadows != 0 || highlights != 0 {
                let yy = max(0, min(1, y))
                let shadowWeight = (1 - yy) * (1 - yy)
                let highlightWeight = yy * yy
                let lift = shadows * shadowWeight * 0.18 + highlights * highlightWeight * 0.18
                r += lift; g += lift; b += lift
            }
            out[p] = r
            out[p + 1] = g
            out[p + 2] = b
        }
        return PixelBufferF32(width: width, height: height, pixels: out)
    }

    func diffusionProxy(amount: Double) -> PixelBufferF32 {
        let strength = Float(max(-1, min(1, amount)))
        guard abs(strength) > 0.0001 else { return self }
        let blurred = boxBlur3x3()
        var out = pixels
        let mix = min(0.75, abs(strength) * 0.75)
        for i in stride(from: 0, to: out.count, by: 4) {
            for c in 0..<3 {
                if strength >= 0 {
                    out[i + c] = out[i + c] * (1 - mix) + blurred.pixels[i + c] * mix
                } else {
                    out[i + c] = out[i + c] + (out[i + c] - blurred.pixels[i + c]) * mix
                }
            }
        }
        return PixelBufferF32(width: width, height: height, pixels: out)
    }

    func localContrastProxy(amount: Double) -> PixelBufferF32 {
        let strength = Float(max(-1, min(1, amount)))
        guard abs(strength) > 0.0001 else { return self }
        let blurred = boxBlur3x3()
        var out = pixels
        let gain = strength * 0.85
        for i in stride(from: 0, to: out.count, by: 4) {
            for c in 0..<3 { out[i + c] += (out[i + c] - blurred.pixels[i + c]) * gain }
        }
        return PixelBufferF32(width: width, height: height, pixels: out)
    }

    func halationProxy(amount: Double) -> PixelBufferF32 {
        let strength = Float(max(-1, min(1, amount)))
        guard abs(strength) > 0.0001 else { return self }
        let blurred = boxBlur3x3()
        var out = pixels
        for i in stride(from: 0, to: out.count, by: 4) {
            let r = pixels[i], g = pixels[i + 1], b = pixels[i + 2]
            let y = max(0, 0.2126 * r + 0.7152 * g + 0.0722 * b)
            let w = max(0, min(1, (y - 0.55) / 0.45)) * abs(strength) * 0.35
            if strength >= 0 {
                out[i] += blurred.pixels[i] * w * 1.25
                out[i + 1] += blurred.pixels[i + 1] * w * 0.45
                out[i + 2] += blurred.pixels[i + 2] * w * 0.18
            } else {
                out[i] -= blurred.pixels[i] * w
                out[i + 1] -= blurred.pixels[i + 1] * w * 0.35
            }
        }
        return PixelBufferF32(width: width, height: height, pixels: out)
    }

    func grainProxy(amount: Double) -> PixelBufferF32 {
        let strength = Float(max(-1, min(1, amount)))
        guard abs(strength) > 0.0001 else { return self }
        var out = pixels
        let amp = abs(strength) * 0.035
        let count = width * height
        for i in 0..<count {
            var x = UInt32(truncatingIfNeeded: i &* 747796405 &+ 2891336453)
            x ^= x >> 16; x &*= 2246822519; x ^= x >> 13; x &*= 3266489917; x ^= x >> 16
            let noise = (Float(x & 0xffff) / 65535.0 - 0.5) * 2 * amp
            let p = i * 4
            if strength >= 0 {
                out[p] += noise; out[p + 1] += noise; out[p + 2] += noise
            } else {
                out[p] = (out[p] + 0.5 * noise) * 0.998
                out[p + 1] = (out[p + 1] + 0.5 * noise) * 0.998
                out[p + 2] = (out[p + 2] + 0.5 * noise) * 0.998
            }
        }
        return PixelBufferF32(width: width, height: height, pixels: out)
    }

    func geometryProxy(
        scale: Double,
        baselineScale: Double,
        offsetX: Double,
        baselineOffsetX: Double,
        offsetY: Double,
        baselineOffsetY: Double
    ) -> PixelBufferF32 {
        let relativeScale = max(0.25, min(4, scale / max(0.0001, baselineScale)))
        let dx = (offsetX - baselineOffsetX) * Double(width) / 100.0
        let dy = (offsetY - baselineOffsetY) * Double(height) / 100.0
        var out = [Float](repeating: 0, count: pixels.count)
        let cx = Double(width - 1) * 0.5
        let cy = Double(height - 1) * 0.5
        for y in 0..<height {
            for x in 0..<width {
                let sx = (Double(x) - cx - dx) / relativeScale + cx
                let sy = (Double(y) - cy - dy) / relativeScale + cy
                let dst = (y * width + x) * 4
                guard sx >= 0, sy >= 0, sx < Double(width - 1), sy < Double(height - 1) else {
                    out[dst + 3] = 1
                    continue
                }
                let ix = Int(sx.rounded())
                let iy = Int(sy.rounded())
                let src = (iy * width + ix) * 4
                out[dst] = pixels[src]
                out[dst + 1] = pixels[src + 1]
                out[dst + 2] = pixels[src + 2]
                out[dst + 3] = pixels[src + 3]
            }
        }
        return PixelBufferF32(width: width, height: height, pixels: out)
    }

    func boxBlur3x3() -> PixelBufferF32 {
        guard width > 2, height > 2, !Task.isCancelled else { return self }
        var out = [Float](repeating: 0, count: pixels.count)
        let kernel = [Float](repeating: 1.0 / 9.0, count: 9)
        let error: vImage_Error = pixels.withUnsafeBytes { sourceBytes in
            out.withUnsafeMutableBytes { destinationBytes in
                guard let sourceBase = sourceBytes.baseAddress,
                      let destinationBase = destinationBytes.baseAddress else {
                    return vImage_Error(kvImageNullPointerArgument)
                }
                var source = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: sourceBase),
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width * 4 * MemoryLayout<Float>.size
                )
                var destination = vImage_Buffer(
                    data: destinationBase,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width * 4 * MemoryLayout<Float>.size
                )
                return kernel.withUnsafeBufferPointer { weights in
                    vImageConvolve_ARGBFFFF(
                        &source,
                        &destination,
                        nil,
                        0,
                        0,
                        weights.baseAddress,
                        3,
                        3,
                        nil,
                        vImage_Flags(kvImageEdgeExtend)
                    )
                }
            }
        }
        guard error == kvImageNoError, !Task.isCancelled else { return self }
        return PixelBufferF32(width: width, height: height, pixels: out)
    }

    func signedPow(_ value: Float, _ exponent: Float) -> Float {
        if value < 0 { return -pow(-value, exponent) }
        return pow(value, exponent)
    }
}
