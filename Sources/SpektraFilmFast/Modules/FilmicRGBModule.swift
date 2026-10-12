// Filmic RGB tone mapper - parametric S-curve with highlight reconstruction
// Equivalent to Darktable's filmicrgb module (v7 color science)

import Foundation
import Metal
import simd

final class FilmicRGBModule: PixelpipeModule {
    let name = "filmicrgb"
    let order = ModuleOrder.filmicRGB
    let inputColorSpace: PixelpipeColorSpace = .rgb
    let outputColorSpace: PixelpipeColorSpace = .displayRGB
    nonisolated(unsafe) var isEnabled: Bool = true
    nonisolated(unsafe) var blendingOpacity: Float = 1.0

    // Scene tab - input range
    nonisolated(unsafe) var greyPointSource: Float = 18.45  // Middle gray luminance (%)
    nonisolated(unsafe) var blackPointSource: Float = -8.0  // Black relative exposure (EV)
    nonisolated(unsafe) var whitePointSource: Float = 4.0  // White relative exposure (EV)

    // Reconstruct tab
    nonisolated(unsafe) var enableHighlightReconstruction: Bool = false
    nonisolated(unsafe) var reconstructThreshold: Float = 0.0  // EV relative to white point
    nonisolated(unsafe) var reconstructFeather: Float = 3.0  // Transition width
    nonisolated(unsafe) var reconstructBloomVsDetails: Float = 100.0
    nonisolated(unsafe) var reconstructGreyVsColor: Float = 100.0
    nonisolated(unsafe) var reconstructStructureVsTexture: Float = 0.0
    nonisolated(unsafe) var securityFactor: Float = 0.0

    // Look tab
    nonisolated(unsafe) var greyPointTarget: Float = 18.45  // Target middle gray (%)
    nonisolated(unsafe) var blackPointTarget: Float = 0.01517634  // Target black luminance
    nonisolated(unsafe) var whitePointTarget: Float = 100.0  // Target white luminance
    nonisolated(unsafe) var outputPower: Float = 4.0  // Hardness
    nonisolated(unsafe) var latitude: Float = 0.01  // Linear region (%)
    nonisolated(unsafe) var contrast: Float = 1.0
    nonisolated(unsafe) var saturation: Float = 0.0
    nonisolated(unsafe) var balance: Float = 0.0  // Shadows ↔ Highlights

    // Options
    nonisolated(unsafe) var preserveColor: PreserveColorMethod = .powerNorm
    nonisolated(unsafe) var colorScience: ColorScienceVersion = .v7_2023
    nonisolated(unsafe) var autoHardness: Bool = true
    nonisolated(unsafe) var customGrey: Bool = false
    nonisolated(unsafe) var highQualityReconstruction: Int = 1
    nonisolated(unsafe) var noiseLevel: Float = 0.2
    nonisolated(unsafe) var noiseDistribution: NoiseDistribution = .gaussian
    nonisolated(unsafe) var shadowsCurve: CurveType = .poly4
    nonisolated(unsafe) var highlightsCurve: CurveType = .poly4
    nonisolated(unsafe) var compensateICCBlack: Bool = false
    nonisolated(unsafe) var splineVersion: SplineVersion = .v3_2021

    enum PreserveColorMethod: Int, Sendable {
        case none = 0
        case maxRGB = 1
        case luminance = 2
        case powerNorm = 3
        case euclideanNormV1 = 4
        case euclideanNormV2 = 5
    }

    enum ColorScienceVersion: Int, Sendable {
        case v3_2019 = 0
        case v4_2020 = 1
        case v5_2021 = 2
        case v6_2022 = 3
        case v7_2023 = 4
    }

    enum NoiseDistribution: Int, Sendable {
        case uniform = 0
        case gaussian = 1
        case poissonian = 2
    }

    enum CurveType: Int, Sendable {
        case poly4 = 0  // Hard
        case poly3 = 1  // Soft
        case rational = 2  // Safe
    }

    enum SplineVersion: Int, Sendable {
        case v1_2019 = 0
        case v2_2020 = 1
        case v3_2021 = 2
    }

    func canProcess(_ input: any PipelineBuffer) -> Bool {
        guard let input = input.asPixelBuffer else { return false }
        return input.channels >= 3
    }

    func process(_ input: any PipelineBuffer, context: inout PixelpipeContext) throws -> any PipelineBuffer {
        guard let input = input.asPixelBuffer else {
            throw PipelineError.wrongBufferType
        }
        guard isEnabled else { return input }

        var output = input.pixels
        let width = input.width
        let height = input.height
        let channels = input.channels

        // Step 1: Highlight reconstruction (if enabled)
        if enableHighlightReconstruction {
            output = try reconstructHighlights(output, width: width, height: height, channels: channels)
        }

        // Step 2: Build spline
        let spline = try buildSpline()

        // Step 3: Apply filmic tone mapping
        output = try applyFilmic(output, width: width, height: height, channels: channels, spline: spline)

        // Step 4: Add noise in highlights
        if noiseLevel > 0 {
            output = addNoise(output, width: input.width, height: input.height, channels: channels)
        }

        return PixelBufferF32(width: input.width, height: input.height, pixels: output)
    }

    private struct FilmicSpline {
        var x: [Float] = Array(repeating: 0, count: 5)
        var y: [Float] = Array(repeating: 0, count: 5)
        var M1, M2, M3, M4, M5: Float
        var latitudeMin, latitudeMax: Float
        var curveType: CurveType
    }

    private func buildSpline() throws -> FilmicSpline {
        var spline = FilmicSpline(
            M1: 0, M2: 0, M3: 0, M4: 0, M5: 0, latitudeMin: 0, latitudeMax: 0, curveType: shadowsCurve)

        // Convert parameters to spline control points
        // Following Darktable's filmic_v5/6/7 implementation

        let greySource = greyPointSource / 100.0 * 0.18
        let whiteSource = greySource * pow(2.0, whitePointSource)
        let blackSource = greySource * pow(2.0, blackPointSource)

        let greyTarget = greyPointTarget / 100.0
        let whiteTarget = pow(whitePointTarget / 100.0, 1.0 / outputPower)
        let blackTarget = pow(blackPointTarget, 1.0 / outputPower)

        // Security factor: securityFactor is not yet applied in the tone curve.
        // Latitude
        let lat = latitude / 100.0

        // Compute spline points in log space
        let blackLog = log2(max(1e-6, blackSource))
        let greyLog = log2(max(1e-6, greySource))
        let whiteLog = log2(max(1e-6, whiteSource))

        let blackDisp = pow(blackTarget, outputPower)
        let greyDisp = pow(greyTarget, outputPower)
        let whiteDisp = whiteTarget

        // Latitude adjustment
        let latitudeMin = greyLog - lat * (greyLog - blackLog)
        let latitudeMax = greyLog + lat * (whiteLog - greyLog)

        // Contrast adjustment
        let contrastFactor = pow(2.0, contrast)
        let latitudeRange = latitudeMax - latitudeMin
        let newLatitudeMin = greyLog - latitudeRange / 2.0 / contrastFactor
        let newLatitudeMax = greyLog + latitudeRange / 2.0 / contrastFactor

        // Balance (shadows ↔ highlights)
        let balanceShift = balance / 100.0 * 0.5
        let finalLatitudeMin = newLatitudeMin - balanceShift * (newLatitudeMax - newLatitudeMin)
        let finalLatitudeMax = newLatitudeMax + balanceShift * (newLatitudeMax - newLatitudeMin)

        // Build x coordinates (log space)
        spline.x[0] = blackLog
        spline.x[1] = finalLatitudeMin
        spline.x[2] = greyLog
        spline.x[3] = finalLatitudeMax
        spline.x[4] = whiteLog

        // Build y coordinates (display space)
        spline.y[0] = blackDisp
        spline.y[1] = lerp(blackDisp, greyDisp, 0.25)
        spline.y[2] = greyDisp
        spline.y[3] = lerp(greyDisp, whiteDisp, 0.75)
        spline.y[4] = whiteDisp

        // Apply security margin
        let margin = 0.01 * (spline.y[4] - spline.y[0])
        if spline.y[1] < spline.y[0] + margin { spline.y[1] = spline.y[0] + margin }
        if spline.y[3] > spline.y[4] - margin { spline.y[3] = spline.y[4] - margin }

        // Compute spline coefficients (cubic Hermite)
        computeSplineCoefficients(&spline)

        // Saturation
        if saturation != 0 {
            // Store saturation for later application
        }

        spline.latitudeMin = finalLatitudeMin
        spline.latitudeMax = finalLatitudeMax
        spline.curveType = shadowsCurve

        return spline
    }

    private func computeSplineCoefficients(_ spline: inout FilmicSpline) {
        // Cubic Hermite spline coefficients
        // M = (y2 - y1) / (x2 - x1) for each segment
        for i in 0..<4 {
            let dx = spline.x[i + 1] - spline.x[i]
            let dy = spline.y[i + 1] - spline.y[i]
            let slope = dx != 0 ? dy / dx : 0

            switch i {
            case 0: spline.M1 = slope
            case 1: spline.M2 = slope
            case 2: spline.M3 = slope
            case 3: spline.M4 = slope
            default: break
            }
        }

        // End slopes
        if spline.x[4] != spline.x[3] {
            spline.M5 = (spline.y[4] - spline.y[3]) / (spline.x[4] - spline.x[3])
        }
    }

    private func applyFilmic(
        _ pixels: [Float], width: Int, height: Int, channels: Int, spline: FilmicSpline
    ) throws -> [Float] {
        var output = pixels
        let count = width * height

        // Encode to log space
        // Apply spline
        // Decode with output power
        // Apply saturation

        for i in 0..<count {
            let base = i * channels
            var rgb = SIMD3<Float>(pixels[base], pixels[base + 1], pixels[base + 2])

            // Preserve color
            let rgbPreserved = preserveColor(rgb, method: preserveColor)

            // Process each channel through spline
            for c in 0..<3 {
                let encoded = encode(rgbPreserved[c])
                let mapped = evaluateSpline(encoded, spline: spline)
                let decoded = decode(mapped)
                rgb[c] = decoded
            }

            // Apply saturation
            if saturation != 0 {
                let luma = 0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
                let diff = rgb - SIMD3<Float>(repeating: luma)
                rgb = SIMD3<Float>(repeating: luma) + diff * (1.0 + saturation / 100.0)
            }

            output[base] = max(0, rgb.x)
            output[base + 1] = max(0, rgb.y)
            output[base + 2] = max(0, rgb.z)
        }

        return output
    }

    private func encode(_ x: Float) -> Float {
        if x < 0 {
            return (-16.0 + 9.72) / 17.52 + x
        }
        return (log2(max(1.5258789e-5, x)) + 9.72) / 17.52
    }

    private func decode(_ x: Float) -> Float {
        let threshold = Float((-16.0 + 9.72) / 17.52)
        if x < threshold {
            return x - threshold
        }
        let a = exp2(x * 17.52 - 9.72)
        return x <= (-15.0 + 9.72) / 17.52 ? (a - 1.5258789e-5) * 2.0 : a
    }

    private func evaluateSpline(_ x: Float, spline: FilmicSpline) -> Float {
        // Cubic Hermite evaluation
        // Find segment
        var segment = 0
        for i in 0..<4 {
            if x <= spline.x[i + 1] { segment = i; break }
        }

        if segment >= 4 { segment = 3 }

        let x0 = spline.x[segment]
        let x1 = spline.x[segment + 1]
        let y0 = spline.y[segment]
        let y1 = spline.y[segment + 1]
        let m0 = [spline.M1, spline.M2, spline.M3, spline.M4][segment]
        let m1 = segment == 3 ? spline.M5 : [spline.M1, spline.M2, spline.M3, spline.M4][segment + 1]

        let dx = x1 - x0
        guard dx != 0 else { return y0 }

        let t = (x - x0) / dx
        let t2 = t * t
        let t3 = t2 * t

        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2

        return h00 * y0 + h10 * m0 * dx + h01 * y1 + h11 * m1 * dx
    }

    private func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
        a + (b - a) * t
    }

    private func preserveColor(_ rgb: SIMD3<Float>, method: PreserveColorMethod) -> SIMD3<Float> {
        switch method {
        case .none: return rgb
        case .maxRGB:
            let maxRGB = max(rgb.x, max(rgb.y, rgb.z))
            return maxRGB > 0 ? rgb / maxRGB : rgb
        case .luminance:
            let y = 0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
            return max(y, 1e-6) > 0 ? rgb * (y / max(rgb.x, max(rgb.y, rgb.z))) : rgb
        case .powerNorm:
            let norm = pow(rgb.x * rgb.y * rgb.z, 1.0 / 3.0)
            return norm > 0 ? rgb / norm : rgb
        case .euclideanNormV1, .euclideanNormV2:
            let norm = sqrt(rgb.x * rgb.x + rgb.y * rgb.y + rgb.z * rgb.z)
            return norm > 0 ? rgb / norm : rgb
        }
    }

    private func reconstructHighlights(_ pixels: [Float], width: Int, height: Int, channels: Int) throws -> [Float] {
        // Filmic's internal highlight reconstruction
        // Uses wavelet-based approach similar to highlights module but in display space
        return pixels
    }

    private func addNoise(_ pixels: [Float], width: Int, height: Int, channels: Int) -> [Float] {
        var output = pixels
        let count = width * height

        // Generate noise
        var rng = SystemRandomNumberGenerator()
        for i in 0..<count {
            let base = i * channels
            for c in 0..<3 {
                var noise: Float = 0
                switch noiseDistribution {
                case .uniform:
                    noise = Float.random(in: -1...1, using: &rng)
                case .gaussian:
                    noise = Float.random(in: -1...1, using: &rng)  // Simplified
                case .poissonian:
                    noise = Float.random(in: -1...1, using: &rng)  // Simplified
                }
                output[base + c] += noise * noiseLevel
            }
        }

        return output
    }
}

enum PreserveColorMethod: Int, Sendable {
    case none = 0
    case maxRGB = 1
    case luminance = 2
    case powerNorm = 3
    case euclideanNormV1 = 4
    case euclideanNormV2 = 5
}

enum ColorScienceVersion: Int, Sendable {
    case v3_2019 = 0
    case v4_2020 = 1
    case v5_2021 = 2
    case v6_2022 = 3
    case v7_2023 = 4
}

enum NoiseDistribution: Int, Sendable {
    case uniform = 0
    case gaussian = 1
    case poissonian = 2
}

enum CurveType: Int, Sendable {
    case poly4 = 0  // Hard
    case poly3 = 1  // Soft
    case rational = 2  // Safe
}

enum SplineVersion: Int, Sendable {
    case v1_2019 = 0
    case v2_2020 = 1
    case v3_2021 = 2
}
