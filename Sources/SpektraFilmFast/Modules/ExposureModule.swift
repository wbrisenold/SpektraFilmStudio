// Exposure module - auto exposure with percentile meter + camera compensation
// Equivalent to Darktable's exposure module

import Foundation
import Metal

final class ExposureModule: PixelpipeModule {
    let name = "exposure"
    let order = ModuleOrder.exposure
    let inputColorSpace: PixelpipeColorSpace = .rgb
    let outputColorSpace: PixelpipeColorSpace = .rgb
    nonisolated(unsafe) var isEnabled: Bool = true
    nonisolated(unsafe) var blendingOpacity: Float = 1.0

    // Parameters
    nonisolated(unsafe) var exposureEV: Float = 0.0  // Manual exposure compensation
    nonisolated(unsafe) var autoMode: Bool = false  // Auto exposure mode
    nonisolated(unsafe) var percentile: Float = 50.0  // Target percentile (50% = median)
    nonisolated(unsafe) var targetLevelEV: Float = 0.0  // Target level in EV
    nonisolated(unsafe) var compensateCameraExposure: Bool = false
    nonisolated(unsafe) var highlightPreservation: Bool = false
    nonisolated(unsafe) var blackLevelCorrection: Float = 0.0

    // Auto-exposure state
    nonisolated(unsafe) var lastAutoEV: Float = 0.0

    func canProcess(_ input: any PipelineBuffer) -> Bool {
        guard let input = input.asPixelBuffer else { return false }
        return input.channels >= 3
    }

    func process(_ input: any PipelineBuffer, context: inout PixelpipeContext) throws -> any PipelineBuffer {
        guard let input = input.asPixelBuffer else {
            throw PipelineError.wrongBufferType
        }
        var output = input.pixels
        let width = input.width
        let height = input.height

        // Apply black level correction first
        if blackLevelCorrection != 0 {
            applyBlackLevel(&output, width: width, height: height, correction: blackLevelCorrection)
        }

        // Determine exposure value
        let ev: Float
        if autoMode {
            ev = computeAutoExposure(input, context: context)
        } else {
            ev = exposureEV
        }

        // Apply camera exposure compensation
        var finalEV = ev
        if compensateCameraExposure {
            finalEV += getCameraExposureBias(context: context)
        }

        // Apply highlight preservation if enabled
        if highlightPreservation {
            finalEV = applyHighlightPreservation(finalEV, input: input)
        }

        // Apply exposure gain
        let gain = pow(2.0, finalEV)
        applyGain(&output, width: width, height: height, gain: gain)

        return PixelBufferF32(width: width, height: height, pixels: output)
    }

    private func computeAutoExposure(_ input: PixelBufferF32, context: PixelpipeContext) -> Float {
        let width = input.width
        let height = input.height
        let pixels = input.pixels
        let channels = input.channels

        // Sample luminances (bounded lattice like AutoCalibrationMath)
        let pixelCount = width * height
        let strideXY = max(1, Int(Double(pixelCount).squareRoot() / 320))

        var lumas: [Float] = []
        lumas.reserveCapacity(80_000)

        var idx = 0
        while idx < pixelCount {
            let base = idx * channels
            let r = pixels[base]
            let g = pixels[base + 1]
            let b = pixels[base + 2]

            if r.isFinite && g.isFinite && b.isFinite {
                let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
                if y.isFinite && y > 1e-6 && y < 64 {
                    lumas.append(y)
                }
            }

            idx += strideXY
        }

        guard lumas.count >= 16 else { return 0 }

        lumas.sort()
        let median = lumas[lumas.count / 2]
        let upper = lumas[min(lumas.count - 1, Int(Double(lumas.count - 1) * 0.995))]

        guard median > 1e-6 && median.isFinite else { return 0 }

        // Target middle gray (0.18 linear)
        let targetEV = log2(0.18 / Double(median))
        let guardEV = upper > 0.01 ? log2(0.98 / Double(upper)) : targetEV
        let ev = min(targetEV, guardEV)

        guard ev.isFinite else { return 0 }

        // Clamp to ±3 EV (Darktable default for auto)
        return Float(min(3.0, max(-3.0, ev)))
    }

    private func getCameraExposureBias(context: PixelpipeContext) -> Float {
        // Would read from EXIF
        // For now, return 0
        return 0
    }

    private func applyHighlightPreservation(_ ev: Float, input: PixelBufferF32) -> Float {
        // Check if highlights would clip
        // If so, reduce exposure
        return ev
    }

    private func applyGain(_ pixels: inout [Float], width: Int, height: Int, gain: Float) {
        let count = width * height
        let channels = 4  // RGBA

        for i in 0..<count {
            let base = i * channels
            pixels[base] *= gain
            pixels[base + 1] *= gain
            pixels[base + 2] *= gain
        }
    }

    private func applyBlackLevel(_ pixels: inout [Float], width: Int, height: Int, correction: Float) {
        // correction is in EV, convert to linear offset
        let offset = pow(2.0, correction) - 1.0
        let count = width * height
        let channels = 4

        for i in 0..<count {
            let base = i * channels
            pixels[base] += offset
            pixels[base + 1] += offset
            pixels[base + 2] += offset
        }
    }
}
