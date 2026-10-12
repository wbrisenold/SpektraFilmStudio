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
        let wbMode = context.rawSettings.whiteBalanceMode

        if wbMode == .asShot {
            return rawInput
        }

        guard let metadata = context.metadata else { return rawInput }
        let wbCoeffs = metadata.wbCoeffs
        guard wbCoeffs.count == 4 else { return rawInput }

        var output = rawInput
        let filters = rawInput.filters
        let xtrans = rawInput.xtrans
        let count = rawInput.count

        guard rawInput.width > 0 else { return rawInput }

        // Simple sequential processing
        for idx in 0..<count {
            let y = idx / rawInput.width
            let x = idx % rawInput.width

            let channel: Int
            if filters == 9 {
                channel = Int(xtrans?[y % 6][x % 6] ?? 0)
            } else {
                channel = Int((filters >> ((y & 1) * 2 + (x & 1)) * 2) & 3)
            }

            let gain = wbCoeffs[min(channel, wbCoeffs.count - 1)] / wbCoeffs[1]
            output.pixels[idx] *= gain
        }

        return output
    }
}
