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
        guard rawInput.width > 0, !blackLevels.isEmpty else { return rawInput }

        // Simple sequential processing
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
            let scale = 1.0 / max(1, whitePoint - black)
            let value = output.pixels[idx]
            output.pixels[idx] = max(0, (value - black) * scale)
        }

        return output
    }
}
