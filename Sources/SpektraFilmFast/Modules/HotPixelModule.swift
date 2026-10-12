// Hot Pixel module - exact port of Darktable's hotpixels module
// Detects and corrects abnormally bright pixels by comparing to same-color neighbors
// src/iop/hotpixels.c

import Foundation
import Metal

final class HotPixelModule: PixelpipeModule {
    let name = "hotpixels"
    let order = ModuleOrder(value: 6.0, name: "hotpixels")
    let inputColorSpace: PixelpipeColorSpace = .raw
    let outputColorSpace: PixelpipeColorSpace = .raw
    nonisolated(unsafe) var isEnabled: Bool = true
    nonisolated(unsafe) var blendingOpacity: Float = 1.0
    
    // Parameters matching Darktable exactly
    nonisolated(unsafe) var threshold: Float = 0.05      // Detection threshold
    nonisolated(unsafe) var strength: Float = 0.25       // Multiplier for neighbor comparison
    nonisolated(unsafe) var permissive: Bool = false     // 3 neighbors (true) or 4 (false)
    nonisolated(unsafe) var markFixed: Bool = false      // Mark fixed pixels
    
    func canProcess(_ input: PixelBufferF32) -> Bool {
        return input.channels >= 1
    }
    
    func process(_ input: PixelBufferF32, context: inout PixelpipeContext) throws -> PixelBufferF32 {
        guard isEnabled else { return input }
        
        let width = input.width
        let height = input.height
        var output = input.pixels
        
        if input.channels == 1 {
            // Bayer sensor variant
            output = try processBayer(output, width: width, height: height, context: context)
        } else {
            // Monochrome sensor variant
            output = try processMonochrome(output, width: width, height: height, channels: input.channels)
        }
        
        return PixelBufferF32(width: width, height: height, pixels: output)
    }
    
    // MARK: - Bayer Sensor Processing (exact port of _process_bayer)
    private func processBayer(_ pixels: [Float], width: Int, height: Int, context: PixelpipeContext) throws -> [Float] {
        guard let metadata = context.metadata else { return pixels }
        
        var output = pixels
        let filters = metadata.filters
        let xtrans = metadata.xtrans
        let multiplier = strength
        let thresh = threshold
        let minNeighbours = permissive ? 3 : 4
        
        // Process from row 2 to height-2, col 2 to width-2 (need 2-pixel border for same-color neighbors)
        for row in 2..<height - 2 {
            let rowBase = row * width
            for col in 2..<width - 2 {
                let idx = rowBase + col
                let value = pixels[idx]
                
                // Skip if below threshold
                if value <= thresh { continue }
                
                let mid = value * multiplier
                
                // Determine CFA channel at this position
                let channel: Int
                if filters == 9 { // X-Trans
                    channel = Int(xtrans[row % 6][col % 6])
                } else {
                    channel = Int((filters >> ((row & 1) * 2 + (col & 1)) * 2) & 3)
                }
                
                // Get 4 same-color neighbors at distance 2
                // (same CFA color appears every 2 pixels in Bayer pattern)
                var count = 0
                var maxNeighbor: Float = 0.0
                
                // Test 4 neighbors at distance 2
                let neighborOffsets = [
                    (-2, 0),  // left
                    (0, -2),  // up
                    (2, 0),   // right
                    (0, 2)    // down
                ]
                
                for (dx, dy) in neighborOffsets {
                    let nx = col + dx
                    let ny = row + dy
                    
                    guard nx >= 0 && nx < width && ny >= 0 && ny < height else { continue }
                    
                    let nChannel: Int
                    if filters == 9 {
                        nChannel = Int(xtrans[ny % 6][nx % 6])
                    } else {
                        nChannel = Int((filters >> ((ny & 1) * 2 + (nx & 1)) * 2) & 3)
                    }
                    
                    // Only compare same CFA color
                    if nChannel != channel { continue }
                    
                    let neighborVal = pixels[ny * width + nx]
                    let mid = value * multiplier
                    
                    if mid > neighborVal {
                        if neighborVal > maxNeighbor {
                            maxNeighbor = neighborVal
                        }
                    }
                }
                
                if count >= minNeighbours {
                    output[idx] = maxNeighbor
                }
            }
        }
        
        return output
    }
    
    // MARK: - Monochrome Sensor Processing (exact port of _process_monochrome)
    private func processMonochrome(_ pixels: [Float], width: Int, height: Int, channels: Int) throws -> [Float] {
        var output = pixels
        let planes = channels
        let multiplier = strength
        let thresh = threshold
        let minNeighbours = permissive ? 3 : 4
        
        // Process each plane independently
        for plane in 0..<planes {
            for row in 1..<height - 1 {
                let rowBase = (row * width + 1) * planes + plane
                for col in 1..<width - 1 {
                    let idx = rowBase + col * planes
                    let value = pixels[idx]
                    
                    if value <= thresh { continue }
                    
                    let mid = value * multiplier
                    var count = 0
                    var maxNeighbor: Float = 0.0
                    
                    // 4-connected neighbors (same plane)
                    let neighborOffsets = [
                        (-planes, 0),              // left
                        (-planes * width, 0),      // up
                        (planes, 0),               // right
                        (planes * width, 0)        // down
                    ]
                    
                    for (offset, _) in neighborOffsets {
                        let nIdx = idx + offset
                        guard nIdx >= 0 && nIdx < pixels.count else { continue }
                        let neighborVal = pixels[nIdx]
                        
                        if value * multiplier > neighborVal {
                            count += 1
                            if neighborVal > maxNeighbor {
                                maxNeighbor = neighborVal
                            }
                        }
                    }
                    
                    if count >= minNeighbours {
                        output[idx] = maxNeighbor
                    }
                }
            }
        }
        
        return output
    }
}