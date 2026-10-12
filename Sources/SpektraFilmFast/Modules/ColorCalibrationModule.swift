// Color Calibration module - CAT chromatic adaptation + channel mixer
// Equivalent to Darktable's colorcalibration module

import Foundation
import Metal
import simd

final class ColorCalibrationModule: PixelpipeModule {
    let name = "colorcalibration"
    let order = ModuleOrder.colorCalibration
    let inputColorSpace: PixelpipeColorSpace = .rgb
    let outputColorSpace: PixelpipeColorSpace = .rgb
    nonisolated(unsafe) var isEnabled: Bool = true
    nonisolated(unsafe) var blendingOpacity: Float = 1.0

    // CAT (Chromatic Adaptation Transform) parameters
    nonisolated(unsafe) var catMethod: CATMethod = .bradford
    nonisolated(unsafe) var illuminant: Illuminant = .d65
    nonisolated(unsafe) var adaptationMode: AdaptationMode = .full

    // Channel mixer (after CAT)
    nonisolated(unsafe) var mixerR: SIMD3<Float> = SIMD3<Float>(1, 0, 0)
    nonisolated(unsafe) var mixerG: SIMD3<Float> = SIMD3<Float>(0, 1, 0)
    nonisolated(unsafe) var mixerB: SIMD3<Float> = SIMD3<Float>(0, 0, 1)

    // Brightness/colorfulness/gamma
    nonisolated(unsafe) var brightness: Float = 0.0
    nonisolated(unsafe) var colorfulness: Float = 0.0
    nonisolated(unsafe) var gamma: Float = 1.0

    // Gray mixer (monochrome)
    nonisolated(unsafe) var grayMixer: SIMD3<Float> = SIMD3<Float>(0.2126, 0.7152, 0.0722)
    nonisolated(unsafe) var useGrayMixer: Bool = false

    // Gamut handling
    nonisolated(unsafe) var clipNegativeRGB: Bool = true
    nonisolated(unsafe) var gamutCompression: Float = 0.0

    enum CATMethod: String, Sendable {
        case bradford = "bradford"
        case vonKries = "vonkries"
        case xyz = "xyz"
        case cat02 = "cat02"
        case cat16 = "cat16"
        case sharp = "sharp"
        case none = "none"
    }

    enum Illuminant: String, Sendable {
        case d65 = "d65"
        case d50 = "d50"
        case d55 = "d55"
        case a = "a"
        case b = "b"
        case c = "c"
        case e = "e"
        case pipeline = "pipeline"
    }

    enum AdaptationMode: String, Sendable {
        case full = "full"
        case cameraReference = "camera_reference"
        case none = "none"
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

        // Step 1: Chromatic adaptation (CAT)
        if adaptationMode != .none {
            output = try applyCAT(output, width: width, height: height, channels: channels, context: context)
        }

        // Step 2: Channel mixer
        output = applyChannelMixer(output, width: width, height: height, channels: channels)

        // Step 3: Brightness/colorfulness/gamma
        output = applyBrightnessColorfulness(output, width: width, height: height, channels: channels)

        // Step 4: Gray mixer
        if useGrayMixer {
            output = applyGrayMixer(output, width: width, height: height, channels: channels)
        }

        // Step 5: Gamut handling
        if clipNegativeRGB || gamutCompression > 0 {
            output = handleGamut(output, width: width, height: height, channels: channels)
        }

        return PixelBufferF32(width: input.width, height: input.height, pixels: output)
    }

    private func applyCAT(
        _ pixels: [Float], width: Int, height: Int, channels: Int, context: PixelpipeContext
    ) throws -> [Float] {
        var output = pixels
        let count = width * height

        // Get CAT matrix for illuminant adaptation
        let catMatrix = getCATMatrix(from: .d65, to: illuminant, method: catMethod)

        for i in 0..<count {
            let base = i * channels
            let rgb = SIMD3<Float>(pixels[base], pixels[base + 1], pixels[base + 2])

            // Apply CAT
            let adapted = catMatrix * rgb

            output[base] = max(0, adapted.x)
            output[base + 1] = max(0, adapted.y)
            output[base + 2] = max(0, adapted.z)
        }

        return output
    }

    private func getCATMatrix(from src: Illuminant, to dst: Illuminant, method: CATMethod) -> simd_float3x3 {
        // Bradford matrix (most common)
        let bradford = simd_float3x3(
            SIMD3<Float>(0.8951, 0.2664, -0.1614),
            SIMD3<Float>(-0.7502, 1.7135, 0.0367),
            SIMD3<Float>(0.0389, -0.0685, 1.0296)
        )

        // Inverse Bradford
        let bradfordInv = bradford.inverse

        // Source and destination white points (D65 -> D50 etc)
        let wpSrc = getWhitePoint(src)
        let wpDst = getWhitePoint(dst)

        // Scale factors
        let scale = SIMD3<Float>(wpDst.x / wpSrc.x, wpDst.y / wpSrc.y, wpDst.z / wpSrc.z)

        // Full CAT matrix: M_inv * diag(scale) * M
        let scaleMatrix = simd_float3x3(
            SIMD3<Float>(scale.x, 0, 0),
            SIMD3<Float>(0, scale.y, 0),
            SIMD3<Float>(0, 0, scale.z)
        )

        return bradfordInv * scaleMatrix * bradford
    }

    private func getWhitePoint(_ illum: Illuminant) -> SIMD3<Float> {
        switch illum {
        case .d65: return SIMD3<Float>(0.95047, 1.00000, 1.08883)
        case .d50: return SIMD3<Float>(0.96422, 1.00000, 0.82521)
        case .d55: return SIMD3<Float>(0.95682, 1.00000, 0.92149)
        case .a: return SIMD3<Float>(1.09850, 1.00000, 0.35585)
        case .b: return SIMD3<Float>(0.99072, 1.00000, 0.85223)
        case .c: return SIMD3<Float>(0.98074, 1.00000, 1.18232)
        case .e: return SIMD3<Float>(1.00000, 1.00000, 1.00000)
        case .pipeline: return SIMD3<Float>(0.96422, 1.00000, 0.82521)  // D50
        }
    }

    private func applyChannelMixer(_ pixels: [Float], width: Int, height: Int, channels: Int) -> [Float] {
        var output = pixels
        let count = width * height

        // Mixer matrix
        let mixer = simd_float3x3(
            mixerR, mixerG, mixerB
        )

        for i in 0..<count {
            let base = i * channels
            let rgb = SIMD3<Float>(pixels[base], pixels[base + 1], pixels[base + 2])
            let mixed = mixer * rgb

            output[base] = max(0, mixed.x)
            output[base + 1] = max(0, mixed.y)
            output[base + 2] = max(0, mixed.z)
        }

        return output
    }

    private func applyBrightnessColorfulness(_ pixels: [Float], width: Int, height: Int, channels: Int) -> [Float] {
        var output = pixels
        let count = width * height

        if brightness != 0 || colorfulness != 0 || gamma != 1.0 {
            for i in 0..<count {
                let base = i * channels
                var rgb = SIMD3<Float>(pixels[base], pixels[base + 1], pixels[base + 2])

                // Brightness (exposure-like)
                if brightness != 0 {
                    rgb *= pow(2.0, brightness)
                }

                // Colorfulness (saturation)
                if colorfulness != 0 {
                    let luma = 0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
                    let diff = rgb - SIMD3<Float>(repeating: luma)
                    rgb = SIMD3<Float>(repeating: luma) + diff * (1.0 + colorfulness)
                }

                // Gamma
                if gamma != 1.0 {
                    rgb = pow(max(rgb, SIMD3<Float>(repeating: 1e-6)), SIMD3<Float>(repeating: 1.0 / gamma))
                }

                output[base] = max(0, rgb.x)
                output[base + 1] = max(0, rgb.y)
                output[base + 2] = max(0, rgb.z)
            }
        }

        return output
    }

    private func applyGrayMixer(_ pixels: [Float], width: Int, height: Int, channels: Int) -> [Float] {
        var output = pixels
        let count = width * height

        for i in 0..<count {
            let base = i * channels
            let rgb = SIMD3<Float>(pixels[base], pixels[base + 1], pixels[base + 2])
            let gray = dot(rgb, grayMixer)

            output[base] = gray
            output[base + 1] = gray
            output[base + 2] = gray
        }

        return output
    }

    private func handleGamut(_ pixels: [Float], width: Int, height: Int, channels: Int) -> [Float] {
        var output = pixels
        let count = width * height

        for i in 0..<count {
            let base = i * channels
            var rgb = SIMD3<Float>(pixels[base], pixels[base + 1], pixels[base + 2])

            // Clip negative
            if clipNegativeRGB {
                rgb = max(rgb, SIMD3<Float>(repeating: 0))
            }

            // Gamut compression (simple scaling for now)
            if gamutCompression > 0 {
                let maxVal = max(rgb.x, max(rgb.y, rgb.z))
                if maxVal > 1.0 {
                    let scale = 1.0 + (maxVal - 1.0) * (1.0 - gamutCompression)
                    rgb /= scale
                }
            }

            output[base] = rgb.x
            output[base + 1] = rgb.y
            output[base + 2] = rgb.z
        }

        return output
    }
}
