// Raw preparation module - applies black level subtraction and white point normalization
// Equivalent to Darktable's rawprepare module

import Foundation
import Metal

final class RawPrepareModule: PixelpipeModule {
    let name = "rawprepare"
    let order = ModuleOrder.rawPrepare
    let inputColorSpace: PixelpipeColorSpace = .raw
    let outputColorSpace: PixelpipeColorSpace = .raw
    nonisolated(unsafe) var isEnabled: Bool = true
    nonisolated(unsafe) var blendingOpacity: Float = 1.0

    func canProcess(_ input: any PipelineBuffer) -> Bool {
        input.asRawMosaic != nil
    }

    func process(_ input: any PipelineBuffer, context: inout PixelpipeContext) throws -> any PipelineBuffer {
        guard let rawInput = input.asRawMosaic else {
            throw PipelineError.wrongBufferType
        }
        var output = rawInput
        let blackLevels = rawInput.blackLevel
        let whitePoint = rawInput.whiteLevel
        let filters = rawInput.filters
        let xtrans = rawInput.xtrans

        let count = rawInput.count
        guard rawInput.width > 0, !blackLevels.isEmpty, whitePoint > 0 else { return rawInput }

        // The RawSpeedBridge now returns raw sensor-scale uint16 values as floats.
        // This module performs black level subtraction and white point normalization
        // EXACTLY ONCE. No other stage in the pipeline may repeat this operation.
        //
        // Contract:
        // - Input: raw sensor values (e.g. 0..16383 for 14-bit)
        // - Output: normalized [0,1+] scene-linear values, with headroom preserved
        // - Black is subtracted per-channel using the actual sensor black levels
        // - White point is the sensor saturation level (maximum non-clipped value)
        // - Values above 1.0 are preserved for highlight reconstruction
        // Use the maximum range across all channels for a stable scale factor.
        // Per-channel scaling would shift neutral colors.
        let maxBlack = (0..<min(blackLevels.count, 4)).map { blackLevels[$0] }.max() ?? blackLevels[0]
        let scale = 1.0 / max(1.0, whitePoint - maxBlack)

        for idx in 0..<count {
            let y = idx / rawInput.width
            let x = idx % rawInput.width

            let channel: Int
            if filters == 9 {  // X-Trans
                channel = Int(xtrans?[y % 6][x % 6] ?? 0)
            } else {  // Bayer
                channel = Int((filters >> ((y & 1) * 2 + (x & 1)) * 2) & 3)
            }

            let black = blackLevels[min(channel, blackLevels.count - 1)]
            let value = output.pixels[idx]
            // Subtract black, then normalize. Do NOT clamp to [0,1] — preserve
            // highlight headroom for the highlight reconstruction module.
            output.pixels[idx] = (value - black) * scale
        }

        return output
    }
}
