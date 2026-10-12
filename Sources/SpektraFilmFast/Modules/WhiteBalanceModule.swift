// White Balance module - applies camera-space white balance
// Equivalent to Darktable's temperature/whitebalance module

import Foundation
import Metal

final class WhiteBalanceModule: PixelpipeModule {
    let name = "whitebalance"
    let order = ModuleOrder.whiteBalance
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

        // All WB modes (including as-shot) apply camera multipliers.
        // As-shot uses the camera's embedded WB coefficients; custom/auto
        // use adjusted coefficients from RawSettings.
        guard let metadata = context.metadata else { return rawInput }
        let wbCoeffs = metadata.wbCoeffs
        guard wbCoeffs.count == 4, wbCoeffs[1] > 0 else { return rawInput }

        // Compute per-channel gains.
        // For as-shot: use the camera's native multipliers directly.
        // For custom/auto: the coefficients have already been adjusted
        // by the caller (ImageDecoder) before entering the pixelpipe.
        let greenCoeff = wbCoeffs[1]
        let gains = wbCoeffs.map { $0 / greenCoeff }

        var output = rawInput
        let filters = rawInput.filters
        let xtrans = rawInput.xtrans
        let count = rawInput.count

        guard rawInput.width > 0 else { return rawInput }

        // Apply per-channel white balance gains.
        // Each CFA site gets multiplied by the gain for its color channel.
        for idx in 0..<count {
            let y = idx / rawInput.width
            let x = idx % rawInput.width

            let channel: Int
            if filters == 9 {  // X-Trans
                channel = Int(xtrans?[y % 6][x % 6] ?? 0)
            } else {  // Bayer
                channel = Int((filters >> ((y & 1) * 2 + (x & 1)) * 2) & 3)
            }

            let gain = gains[min(channel, gains.count - 1)]
            output.pixels[idx] *= gain
        }

        return output
    }
}
