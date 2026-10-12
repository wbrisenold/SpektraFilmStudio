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
    
    func canProcess(_ input: PixelBufferF32) -> Bool {
        return input.channels == 1
    }
    
    func process(_ input: PixelBufferF32, context: inout PixelpipeContext) throws -> PixelBufferF32 {
        guard let metadata = context.metadata else { return input }
        
        let width = input.width
        let height = input.height
        var output = input.pixels
        let blackLevels = metadata.rawBlackLevelSeparate
        let whitePoint = metadata.rawWhitePoint
        let filters = metadata.filters
        let xtrans = metadata.xtrans
        
        let count = width * height
        
        // Simple sequential processing
        for idx in 0..<count {
            let y = idx / width
            let x = idx % width
            
            let channel: Int
            if filters == 9 { // X-Trans
                channel = Int(xtrans[y % 6][x % 6])
            } else { // Bayer
                channel = Int((filters >> ((y & 1) * 2 + (x & 1)) * 2) & 3)
            }
            
            let black = blackLevels[channel]
            let scale = 1.0 / (whitePoint - black)
            let value = output[idx]
            output[idx] = max(0, (value - black) * scale)
        }
        
        return PixelBufferF32(width: width, height: height, pixels: output)
    }
}