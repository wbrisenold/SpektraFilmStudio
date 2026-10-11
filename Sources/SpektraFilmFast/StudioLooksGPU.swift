import Foundation
@preconcurrency import Metal

/// Uniform-only Look controls. All math is on scene-linear extended Rec.2020.
/// The LUT is a fixed GPU texture, never generated from slider movement.
final class StudioLooksGPU {
    private let pre: any MTLComputePipelineState
    private let post: any MTLComputePipelineState

    init(device: any MTLDevice) throws {
        let lib = try device.makeLibrary(source: Self.code, options: nil)
        guard let a = lib.makeFunction(name: "spektraLooksPre"),
              let b = lib.makeFunction(name: "spektraLooksPost") else {
            throw GPULiveError.unavailable("Looks Metal shaders not available")
        }
        pre = try device.makeComputePipelineState(function: a)
        post = try device.makeComputePipelineState(function: b)
    }

    func encodePre(_ frame: any MTLBuffer, width: Int, height: Int,
                   look: RenderLook, command: any MTLCommandBuffer) throws {
        guard let e = command.makeComputeCommandEncoder() else {
            throw GPULiveError.unavailable("Looks host encoder unavailable")
        }
        var shape = SIMD2<UInt32>(UInt32(width), UInt32(height))
        var controls = SIMD4<Float>(
            StudioLooksSettings.scalar(look, "exposure", default: 0),
            StudioLooksSettings.scalar(look, "temperature", default: 0),
            StudioLooksSettings.scalar(look, "tint", default: 0), 0)
        e.setComputePipelineState(pre)
        e.setBuffer(frame, offset: 0, index: 0)
        e.setBytes(&shape, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 1)
        e.setBytes(&controls, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
        e.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        e.endEncoding()
    }

    func encodePost(neutral: any MTLBuffer, transformed: any MTLBuffer,
                    width: Int, height: Int, look: RenderLook,
                    command: any MTLCommandBuffer) throws {
        guard let e = command.makeComputeCommandEncoder() else {
            throw GPULiveError.unavailable("Looks strength encoder unavailable")
        }
        var shape = SIMD2<UInt32>(UInt32(width), UInt32(height))
        var controls = SIMD2<Float>(
            min(1, max(0, StudioLooksSettings.scalar(look, "strength", default: 1))),
            min(2, max(-2, StudioLooksSettings.scalar(look, "contrast", default: 0))))
        e.setComputePipelineState(post)
        e.setBuffer(neutral, offset: 0, index: 0)
        e.setBuffer(transformed, offset: 0, index: 1)
        e.setBytes(&shape, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 2)
        e.setBytes(&controls, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
        e.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        e.endEncoding()
    }

    private static let code = #"""
    #include <metal_stdlib>
    using namespace metal;
    kernel void spektraLooksPre(device float4 *frame [[buffer(0)]],
        constant uint2 &size [[buffer(1)]],
        constant float4 &settings [[buffer(2)]],
        uint2 at [[thread_position_in_grid]]) {
        if (at.x >= size.x || at.y >= size.y) return;
        uint i = at.y * size.x + at.x;
        float4 p = frame[i];
        float exposure = clamp(settings.x, -8.0f, 8.0f);
        float temp = clamp(settings.y, -1.0f, 1.0f);
        float tint = clamp(settings.z, -1.0f, 1.0f);
        float3 gains = exp2(float3(temp + tint * 0.25f,
                                  -tint * 0.5f, -temp + tint * 0.25f));
        frame[i] = float4(p.rgb * exp2(exposure) * gains, p.a);
    }
    kernel void spektraLooksPost(device const float4 *neutral [[buffer(0)]],
        device float4 *cube [[buffer(1)]],
        constant uint2 &size [[buffer(2)]],
        constant float2 &settings [[buffer(3)]],
        uint2 at [[thread_position_in_grid]]) {
        if (at.x >= size.x || at.y >= size.y) return;
        uint i = at.y * size.x + at.x;
        float4 src = neutral[i];
        float4 fx = cube[i];
        float3 blended = mix(src.rgb, fx.rgb, clamp(settings.x, 0.0f, 1.0f));
        // Linear-light contrast about 18% scene gray, not a gamma-encoded curve.
        blended = (blended - 0.18f) * exp2(settings.y) + 0.18f;
        cube[i] = float4(blended, fx.a);
    }
    """#
}
