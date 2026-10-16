import Foundation
import Metal

/// GPU-only, 64-point content validity check. Runs on the same command buffer as
/// the edit preview; reads back 2 KiB AFTER the normal async GPU completion.
/// A successful kernel is not proof that a nonblank photograph was produced.
final class MetalFrameContentGuard {
    private let device: any MTLDevice
    private let pipeline: any MTLComputePipelineState

    init(device: any MTLDevice) throws {
        self.device = device
        let source = #"""
        #include <metal_stdlib>
        using namespace metal;
        kernel void spektraContentSamples(
            device const float4 *before [[buffer(0)]],
            device const float4 *after [[buffer(1)]],
            device float4 *samples [[buffer(2)]],
            constant uint2 &size [[buffer(3)]],
            uint i [[thread_position_in_grid]]) {
            if (i >= 64) return;
            uint x = min(size.x - 1, ((i % 8) * 2 + 1) * size.x / 16);
            uint y = min(size.y - 1, ((i / 8) * 2 + 1) * size.y / 16);
            uint index = y * size.x + x;
            samples[i * 2] = before[index];
            samples[i * 2 + 1] = after[index];
        }
        """#
        let library = try device.makeLibrary(source: source, options: nil)
        guard let shader = library.makeFunction(name: "spektraContentSamples") else {
            throw GPULiveError.unavailable("LUT content-probe kernel missing")
        }
        pipeline = try device.makeComputePipelineState(function: shader)
    }

    func encode(
        before: any MTLBuffer, after: any MTLBuffer,
        width: Int, height: Int, on command: any MTLCommandBuffer,
    ) throws -> any MTLBuffer {
        guard width > 0, height > 0, width <= Int(UInt32.max), height <= Int(UInt32.max),
              let samples = device.makeBuffer(length: 64 * 2 * 16, options: .storageModeShared),
              let encoder = command.makeComputeCommandEncoder()
        else {
            throw GPULiveError.unavailable("LUT frame content probe allocation failed")
        }
        var dims = SIMD2<UInt32>(UInt32(width), UInt32(height))
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(before, offset: 0, index: 0)
        encoder.setBuffer(after, offset: 0, index: 1)
        encoder.setBuffer(samples, offset: 0, index: 2)
        encoder.setBytes(&dims, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 3)
        encoder.dispatchThreads(
            MTLSize(width: 64, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1),
        )
        encoder.endEncoding()
        return samples
    }

    static func verify(_ samples: any MTLBuffer) throws {
        let floats = samples.contents().assumingMemoryBound(to: Float.self)
        var beforeLow = Float.infinity, beforeHigh = -Float.infinity
        var afterLow = Float.infinity, afterHigh = -Float.infinity
        for i in 0 ..< 64 {
            let before = i * 8, after = before + 4
            let src = 0.2126 * floats[before] + 0.7152 * floats[before + 1] + 0.0722 * floats[before + 2]
            let out = 0.2126 * floats[after] + 0.7152 * floats[after + 1] + 0.0722 * floats[after + 2]
            guard src.isFinite, out.isFinite, floats[after + 3].isFinite else {
                throw GPULiveError.unavailable("LUT GPU produced non-finite pixels")
            }
            beforeLow = min(beforeLow, src)
            beforeHigh = max(beforeHigh, src)
            afterLow = min(afterLow, out)
            afterHigh = max(afterHigh, out)
        }
        // Extremely conservative: allow genuine contrast compression, gray
        // photos and clipped exposures. Only reject almost completely constant
        // output when the RAW feed demonstrably contained significant detail.
        if beforeHigh - beforeLow > 0.25, afterHigh - afterLow < 0.001 {
            throw GPULiveError.unavailable(
                "LUT_GPU_FRAME_BLANK: GPU LUT returned almost constant pixels despite a detailed RAW input. Check LUT shaper, output values and input contract.",
            )
        }
    }
}
