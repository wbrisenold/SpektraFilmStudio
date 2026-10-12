// Sigmoid tone mapper - alternative to Filmic RGB
// Equivalent to Darktable's sigmoid module

import Foundation
import simd

final class SigmoidModule: PixelpipeModule {
    let name = "sigmoid"
    let order = ModuleOrder.sigmoid
    let inputColorSpace: PixelpipeColorSpace = .rgb
    let outputColorSpace: PixelpipeColorSpace = .displayRGB
    nonisolated(unsafe) var isEnabled: Bool = true
    nonisolated(unsafe) var blendingOpacity: Float = 1.0
    
    // Parameters
    nonisolated(unsafe) var mode: Mode = .perChannel
    nonisolated(unsafe) var preserveHue: Bool = true
    
    // Spline parameters
    nonisolated(unsafe) var pivotX: Float = 0.5
    nonisolated(unsafe) var pivotY: Float = 0.5
    nonisolated(unsafe) var slope: Float = 1.0
    nonisolated(unsafe) var toeLength: Float = 0.0
    nonisolated(unsafe) var shoulderLength: Float = 0.0
    nonisolated(unsafe) var gamma: Float = 2.2
    
    enum Mode: Int, Sendable {
        case perChannel = 0
        case rgbRatio = 1
    }
    
    func canProcess(_ input: PixelBufferF32) -> Bool {
        return input.channels >= 3
    }
    
    func process(_ input: PixelBufferF32, context: inout PixelpipeContext) throws -> PixelBufferF32 {
        var output = input.pixels
        let width = input.width
        let height = input.height
        let channels = input.channels
        
        for i in 0..<(width * height) {
            let base = i * channels
            var rgb = SIMD3<Float>(output[base], output[base + 1], output[base + 2])
            
            switch mode {
            case .perChannel:
                for c in 0..<3 {
                    output[base + c] = applySigmoid(rgb[c])
                }
            case .rgbRatio:
                // Preserve RGB ratios (like filmic's preserve color)
                let norm = max(1e-6, sqrt(rgb.x*rgb.x + rgb.y*rgb.y + rgb.z*rgb.z))
                let ratio = rgb / norm
                let mappedNorm = applySigmoid(norm)
                rgb = ratio * mappedNorm
                output[base] = rgb.x
                output[base + 1] = rgb.y
                output[base + 2] = rgb.z
            }
        }
        
        // Apply gamma
        if gamma != 1.0 {
            for i in 0..<(width * height) {
                let base = i * channels
                output[base] = pow(max(1e-6, output[base]), 1.0 / gamma)
                output[base + 1] = pow(max(1e-6, output[base + 1]), 1.0 / gamma)
                output[base + 2] = pow(max(1e-6, output[base + 2]), 1.0 / gamma)
            }
        }
        
        return PixelBufferF32(width: width, height: height, pixels: output)
    }
    
    private func applySigmoid(_ x: Float) -> Float {
        // Sigmoid function: 1 / (1 + exp(-slope * (x - pivotX)))
        // With toe and shoulder
        
        let x = max(1e-6, min(1.0, x))
        
        // Apply toe
        var y = x
        if toeLength > 0 && x < pivotX {
            let t = x / pivotX
            y = pivotY * pow(t, 1.0 + toeLength)
        }
        // Apply shoulder
        else if shoulderLength > 0 && x > pivotX {
            let t = (x - pivotX) / (1.0 - pivotX)
            y = pivotY + (1.0 - pivotY) * (1.0 - pow(1.0 - t, 1.0 + shoulderLength))
        }
        else {
            // Main sigmoid
            let s = slope * (x - pivotX)
            y = 1.0 / (1.0 + exp(-s))
            // Scale to pivot
            y = pivotY + (y - 0.5) * (1.0 - 2.0 * pivotY)
        }
        
        return max(0, min(1, y))
    }
}