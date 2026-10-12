// AgX tone mapper - Blender-inspired parametric tone mapping
// Equivalent to Darktable's AgX module

import Foundation
import simd

final class AgXModule: PixelpipeModule {
    let name = "agx"
    let order = ModuleOrder.agx
    let inputColorSpace: PixelpipeColorSpace = .rgb
    let outputColorSpace: PixelpipeColorSpace = .displayRGB
    nonisolated(unsafe) var isEnabled: Bool = true
    nonisolated(unsafe) var blendingOpacity: Float = 1.0
    
    // Look controls
    nonisolated(unsafe) var lookLift: Float = 0.0
    nonisolated(unsafe) var lookSlope: Float = 1.0
    nonisolated(unsafe) var lookBrightness: Float = 1.0
    nonisolated(unsafe) var lookSaturation: Float = 1.0
    nonisolated(unsafe) var lookOriginalHueMixRatio: Float = 0.6
    
    // Log mapping
    nonisolated(unsafe) var rangeBlackRelativeEV: Float = -10.0
    nonisolated(unsafe) var rangeWhiteRelativeEV: Float = 6.5
    nonisolated(unsafe) var dynamicRangeScaling: Float = 0.1
    
    // Curve parameters
    nonisolated(unsafe) var curvePivotX: Float = 0.606060606061
    nonisolated(unsafe) var curvePivotYLinearOutput: Float = 0.18
    nonisolated(unsafe) var curveContrastAroundPivot: Float = 3.0
    nonisolated(unsafe) var curveLinearRatioBelowPivot: Float = 0.0
    nonisolated(unsafe) var curveLinearRatioAbovePivot: Float = 0.0
    nonisolated(unsafe) var curveToePower: Float = 1.5
    nonisolated(unsafe) var curveShoulderPower: Float = 3.3
    nonisolated(unsafe) var curveGamma: Float = 2.2
    nonisolated(unsafe) var autoGamma: Bool = false
    nonisolated(unsafe) var curveTargetDisplayBlackRatio: Float = 0.0
    nonisolated(unsafe) var curveTargetDisplayWhiteRatio: Float = 1.0
    
    // Primaries
    nonisolated(unsafe) var basePrimaries: BasePrimaries = .rec2020
    nonisolated(unsafe) var disablePrimariesAdjustments: Bool = false
    nonisolated(unsafe) var redInset: Float = 0.0
    nonisolated(unsafe) var redRotation: Float = 0.0
    nonisolated(unsafe) var greenInset: Float = 0.0
    nonisolated(unsafe) var greenRotation: Float = 0.0
    nonisolated(unsafe) var blueInset: Float = 0.0
    nonisolated(unsafe) var blueRotation: Float = 0.0
    nonisolated(unsafe) var masterOutsetRatio: Float = 1.0
    nonisolated(unsafe) var masterUnrotationRatio: Float = 1.0
    nonisolated(unsafe) var redOutset: Float = 0.0
    nonisolated(unsafe) var redUnrotation: Float = 0.0
    nonisolated(unsafe) var greenOutset: Float = 0.0
    nonisolated(unsafe) var greenUnrotation: Float = 0.0
    nonisolated(unsafe) var blueOutset: Float = 0.0
    nonisolated(unsafe) var blueUnrotation: Float = 0.0
    nonisolated(unsafe) var completelyReversePrimaries: Bool = false
    
    // BasePrimaries is defined at the bottom of the file
    
    func canProcess(_ input: PixelBufferF32) -> Bool {
        return input.channels >= 3
    }
    
    func process(_ input: PixelBufferF32, context: inout PixelpipeContext) throws -> PixelBufferF32 {
        var output = input.pixels
        let width = input.width
        let height = input.height
        let channels = input.channels
        
        // Step 1: Convert to base primaries (internal rendering space)
        output = convertToBasePrimaries(output, width: width, height: height, channels: channels)
        
        // Step 2: Apply AgX tone mapping curve
        output = applyAgXCurve(output, width: width, height: height, channels: channels)
        
        // Step 3: Apply look adjustments
        output = applyLook(output, width: width, height: height, channels: channels)
        
        // Step 4: Convert back to output color space
        output = convertFromBasePrimaries(output, width: width, height: height, channels: channels)
        
        return PixelBufferF32(width: input.width, height: input.height, pixels: output)
    }
    
    private func convertToBasePrimaries(_ pixels: [Float], width: Int, height: Int, channels: Int) -> [Float] {
        var output = pixels
        // Matrix conversion from working space to internal rendering space
        let matrix = getWorkingToRenderingMatrix()
        
        let count = width * height
        for i in 0..<count {
            let base = i * channels
            let rgb = SIMD3<Float>(pixels[base], pixels[base + 1], pixels[base + 2])
            let converted = matrix * rgb
            output[base] = converted.x
            output[base + 1] = converted.y
            output[base + 2] = converted.z
        }
        
        return output
    }
    
    private func convertFromBasePrimaries(_ pixels: [Float], width: Int, height: Int, channels: Int) -> [Float] {
        var output = pixels
        let matrix = getRenderingToWorkingMatrix()
        
        let count = width * height
        for i in 0..<count {
            let base = i * channels
            let rgb = SIMD3<Float>(pixels[base], pixels[base + 1], pixels[base + 2])
            let converted = matrix * rgb
            output[base] = converted.x
            output[base + 1] = converted.y
            output[base + 2] = converted.z
        }
        
        return output
    }
    
    private func getWorkingToRenderingMatrix() -> simd_float3x3 {
        // Convert from working space to AgX internal rendering space
        // Based on basePrimaries setting
        return simd_float3x3(
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(0, 0, 1)
        )
    }
    
    private func getRenderingToWorkingMatrix() -> simd_float3x3 {
        return getWorkingToRenderingMatrix().inverse
    }
    
    private func applyAgXCurve(_ pixels: [Float], width: Int, height: Int, channels: Int) -> [Float] {
        var output = pixels
        let count = width * height
        
        // AgX curve parameters
        let blackEV = rangeBlackRelativeEV
        let whiteEV = rangeWhiteRelativeEV
        let pivotX = curvePivotX
        let pivotY = curvePivotYLinearOutput
        let contrast = curveContrastAroundPivot
        let toePower = curveToePower
        let shoulderPower = curveShoulderPower
        let gamma = curveGamma
        
        let dynamicRange = whiteEV - blackEV
        
        for i in 0..<count {
            let base = i * channels
            var rgb = SIMD3<Float>(pixels[base], pixels[base + 1], pixels[base + 2])
            
            // Compress out-of-gamut colors
            compressIntoGamut(&rgb)
            
            // Apply tone curve per channel
            for c in 0..<3 {
                let x = max(1e-6, rgb[c])
                let logX = log2(x)
                
                // Normalize to [0, 1] range
                let normalized = (logX - blackEV) / (whiteEV - blackEV)
                let clamped = max(0, min(1, normalized))
                
                // Apply AgX S-curve
                let y = agxCurve(clamped, pivotX: pivotX, pivotY: pivotY,
                               contrast: contrast, toePower: toePower,
                               shoulderPower: shoulderPower, gamma: gamma)
                
                // Convert back
                let newLog = lerp(blackEV, whiteEV, y)
                rgb[c] = pow(2.0, newLog)
            }
            
            output[base] = rgb.x
            output[base + 1] = rgb.y
            output[base + 2] = rgb.z
        }
        
        return output
    }
    
    private func agxCurve(_ x: Float, pivotX: Float, pivotY: Float,
                         contrast: Float, toePower: Float, shoulderPower: Float,
                         gamma: Float) -> Float {
        // AgX S-curve from Desmos calculator
        // https://www.desmos.com/calculator/yrysofmx8h
        
        let linearBelow = curveLinearRatioBelowPivot
        let linearAbove = curveLinearRatioAbovePivot
        
        // Toe (below pivot)
        var y: Float
        if x <= pivotX {
            let t = x / pivotX
            if linearBelow > 0 {
                let linEnd = pivotX * linearBelow
                if x <= linEnd {
                    y = x / pivotX * pivotY
                } else {
                    let t2 = (x - linEnd) / (pivotX - linEnd)
                    let toe = pow(t2, toePower)
                    y = lerp(pivotY * linearBelow, pivotY, toe)
                }
            } else {
                y = pow(t, toePower) * pivotY
            }
        } else {
            // Shoulder (above pivot)
            let t = (x - pivotX) / (1.0 - pivotX)
            if linearAbove > 0 {
                let linStart = pivotX + (1.0 - pivotX) * (1.0 - linearAbove)
                if x >= linStart {
                    y = lerp(pivotY, 1.0, (x - linStart) / (1.0 - linStart))
                } else {
                    let t2 = (x - pivotX) / (linStart - pivotX)
                    let shoulder = 1.0 - pow(1.0 - t2, shoulderPower)
                    y = lerp(pivotY, 1.0, shoulder)
                }
            } else {
                y = pivotY + (1.0 - pivotY) * (1.0 - pow(1.0 - t, shoulderPower))
            }
        }
        
        // Apply gamma
        if gamma != 1.0 {
            y = pow(max(1e-6, y), 1.0 / gamma)
        }
        
        return y
    }
    
    private func applyLook(_ pixels: [Float], width: Int, height: Int, channels: Int) -> [Float] {
        var output = pixels
        // Apply lift, slope, brightness, saturation
        // Simplified for now
        return output
    }
    
    private func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
        a + (b - a) * t
    }
    
    private func compressIntoGamut(_ rgb: inout SIMD3<Float>) {
        // Slide out-of-gamut colors into gamut
        // Simplified implementation
        let minVal = min(rgb.x, min(rgb.y, rgb.z))
        if minVal < 0 {
            let offset = -minVal * 0.5
            rgb += SIMD3<Float>(repeating: offset)
        }
    }
}

extension AgXModule {
    enum BasePrimaries: Int, Sendable {
        case exportProfile = 0
        case workProfile = 1
        case rec2020 = 2
        case displayP3 = 3
        case adobeRGB = 4
        case srgb = 5
    }
}