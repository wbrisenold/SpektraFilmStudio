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
    
    func canProcess(_ input: PixelBufferF32) -> Bool {
        return input.channels >= 1
    }
    
    func process(_ input: PixelBufferF32, context: inout PixelpipeContext) throws -> PixelBufferF32 {
        let wbMode = context.rawSettings.whiteBalanceMode
        
        if wbMode == .asShot {
            return input
        }
        
        guard let metadata = context.metadata else { return input }
        let wbCoeffs = metadata.wbCoeffs
        guard wbCoeffs.count == 4 else { return input }
        
        let width = input.width
        let height = input.height
        var output = input.pixels
        
        if input.channels == 1 {
            // Bayer - apply per-channel gains
            let filters = metadata.filters
            let xtrans = metadata.xtrans
            let count = width * height
            
            // Simple sequential processing to avoid Sendable issues
            for idx in 0..<count {
                let y = idx / width
                let x = idx % width
                
                let channel: Int
                if filters == 9 {
                    channel = Int(xtrans[y % 6][x % 6])
                } else {
                    channel = Int((filters >> ((y & 1) * 2 + (x & 1)) * 2) & 3)
                }
                
                let gain = wbCoeffs[channel] / wbCoeffs[1]
                output[idx] *= gain
            }
        } else {
            let channels = input.channels
            let count = width * height
            
            for idx in 0..<count {
                let base = idx * channels
                for c in 0..<min(channels, 3) {
                    let gain = wbCoeffs[c] / wbCoeffs[1]
                    output[base + c] *= gain
                }
            }
        }
        
        return PixelBufferF32(width: width, height: height, pixels: output)
    }
}