import Foundation
import Metal
import Darwin

/// Metal-only output resizing: no vImage/CPU resize fallback. CPU-bound original
/// decoder/film/geometry and ImageIO encoder are existing upstream limitations.
/// This class is not a claim of end-to-end GPU residency.
final class MetalExportResizer: @unchecked Sendable {
    static let shared = MetalExportResizer()

    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let horizontalPSO: MTLComputePipelineState?
    private let verticalPSO: MTLComputePipelineState?

    private init() {
        let d = MTLCreateSystemDefaultDevice()
        device = d
        queue = d?.makeCommandQueue()
        if let d, let library = try? d.makeLibrary(source: Self.kernel, options: nil),
           let horizontal = library.makeFunction(name: "spektrafilm_scale_horizontal"),
           let vertical = library.makeFunction(name: "spektrafilm_scale_vertical") {
            horizontalPSO = try? d.makeComputePipelineState(function: horizontal)
            verticalPSO = try? d.makeComputePipelineState(function: vertical)
        } else {
            horizontalPSO = nil
            verticalPSO = nil
        }
    }

    enum ScaleError: LocalizedError {
        case unavailable, oversized, memory, encoding, execution
        var errorDescription: String? {
            switch self {
            case .unavailable: "Metal export resize is unavailable; CPU fallback is disabled."
            case .oversized: "Output exceeds the supported Metal frame size."
            case .memory: "Insufficient memory for the Metal export frame."
            case .encoding: "Could not schedule the Metal export resize."
            case .execution: "Metal export resize failed; the file was not written."
            }
        }
    }

    /// Float RGBA image; ROI is specified in input pixels. Supports 16-bit TIFF
    /// export and extended-range samples without quantizing to 8-bit first.
    func resized(
        _ input: PixelBufferF32,
        cropX: Int = 0, cropY: Int = 0, cropWidth: Int? = nil, cropHeight: Int? = nil,
        width: Int, height: Int
    ) throws -> PixelBufferF32 {
        let cw = cropWidth ?? input.width
        let ch = cropHeight ?? input.height
        guard width > 0, height > 0, cw > 0, ch > 0,
              cropX >= 0, cropY >= 0,
              cropX <= input.width, cropY <= input.height,
              cw <= input.width - cropX, ch <= input.height - cropY,
              input.width > 0, input.height > 0,
              width <= 16384, height <= 16384,
              input.width <= 16384, input.height <= 16384,
              input.pixels.count == input.width * input.height * 4 else { throw ScaleError.oversized }
        guard let device, let queue, let horizontalPSO, let verticalPSO else { throw ScaleError.unavailable }
        let srcByteCount = input.pixels.count * MemoryLayout<Float>.stride
        let dstPixelCount = width * height
        let dstByteCount = dstPixelCount * 4 * MemoryLayout<Float>.stride
        let intermediateByteCount = width * ch * 4 * MemoryLayout<Float>.stride
        guard srcByteCount <= device.maxBufferLength,
              dstByteCount <= device.maxBufferLength,
              intermediateByteCount <= device.maxBufferLength else { throw ScaleError.oversized }
        // A too-large allocation should fail before macOS memory pressure kills
        // the entire editor. The upstream full-res input is retained concurrently.
        let available = Self.availableMemoryBytes()
        let allocation = UInt64(srcByteCount) + UInt64(dstByteCount) + UInt64(intermediateByteCount)
        if available > 0 && allocation > available / 2 { throw ScaleError.memory }
        guard let source = input.pixels.withUnsafeBytes({ ptr in
            guard let bytes = ptr.baseAddress else { return nil as MTLBuffer? }
            return device.makeBuffer(bytes: bytes, length: srcByteCount, options: .storageModeShared)
        }),
              let intermediate = device.makeBuffer(length: intermediateByteCount, options: .storageModePrivate),
              let destination = device.makeBuffer(length: dstByteCount, options: .storageModeShared),
              let command = queue.makeCommandBuffer() else { throw ScaleError.memory }

        var sourceDims = SIMD2<UInt32>(UInt32(input.width), UInt32(input.height))
        var roiOrigin = SIMD2<UInt32>(UInt32(cropX), UInt32(cropY))
        var roiDims = SIMD2<UInt32>(UInt32(cw), UInt32(ch))
        var outputDims = SIMD2<UInt32>(UInt32(width), UInt32(height))
        guard let horizontal = command.makeComputeCommandEncoder() else { throw ScaleError.encoding }
        horizontal.setComputePipelineState(horizontalPSO)
        horizontal.setBuffer(source, offset: 0, index: 0)
        horizontal.setBuffer(intermediate, offset: 0, index: 1)
        horizontal.setBytes(&sourceDims, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 2)
        horizontal.setBytes(&roiOrigin, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 3)
        horizontal.setBytes(&roiDims, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 4)
        horizontal.setBytes(&outputDims, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 5)
        horizontal.dispatchThreads(MTLSize(width: width, height: ch, depth: 1),
                                   threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
        horizontal.endEncoding()

        guard let vertical = command.makeComputeCommandEncoder() else { throw ScaleError.encoding }
        vertical.setComputePipelineState(verticalPSO)
        vertical.setBuffer(intermediate, offset: 0, index: 0)
        vertical.setBuffer(destination, offset: 0, index: 1)
        vertical.setBytes(&roiDims, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 2)
        vertical.setBytes(&outputDims, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 3)
        vertical.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
        vertical.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw ScaleError.execution }
        let floats = destination.contents().assumingMemoryBound(to: Float.self)
        return PixelBufferF32(width: width, height: height,
                              pixels: Array(UnsafeBufferPointer(start: floats, count: dstPixelCount * 4)))
    }

    /// Free + inactive page bytes. `os_proc_available_memory()` is iOS-only, so
    /// query the Mach VM statistics directly on macOS.
    private static func availableMemoryBytes() -> UInt64 {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pageSize = UInt64(getpagesize())
        return (UInt64(stats.free_count) + UInt64(stats.inactive_count)) * pageSize
    }

    private static let kernel = #"""
#include <metal_stdlib>
using namespace metal;
// Two separable Lanczos-3 kernels. O(outW * srcH * tapsX + outW * outH * tapsY)
// avoids the prohibitively expensive 2D tapsX*tapsY inner loop.
inline float sinc1(float x) {
    if (abs(x) < 0.00001f) return 1.0f;
    float p = 3.14159265358979323846f * x;
    return sin(p) / p;
}
inline float lanczos3(float x) {
    float a = abs(x);
    return a < 3.0f ? sinc1(a) * sinc1(a/3.0f) : 0.0f;
}
kernel void spektrafilm_scale_horizontal(
    device const float4* src [[buffer(0)]],
    device float4* intermediate [[buffer(1)]],
    constant uint2& srcSize [[buffer(2)]],
    constant uint2& origin [[buffer(3)]],
    constant uint2& roiSize [[buffer(4)]],
    constant uint2& outSize [[buffer(5)]],
    uint2 id [[thread_position_in_grid]]) {
    if (id.x >= outSize.x || id.y >= roiSize.y) return;
    float x = (float(id.x) + 0.5f) * float(roiSize.x) / float(outSize.x) - 0.5f;
    float scale = max(1.0f, float(roiSize.x)/float(outSize.x));
    int center = int(floor(x));
    int radius = min(512, int(ceil(3.0f*scale)));
    uint y = id.y + origin.y;
    float4 value = float4(0.0f); float weight = 0.0f;
    for (int i = -radius+1; i <= radius; ++i) {
        int sampleX = center+i;
        float w = lanczos3((float(sampleX)-x)/scale);
        if (w == 0.0f) continue;
        int boundedX = clamp(sampleX, 0, int(roiSize.x)-1) + int(origin.x);
        value += src[y*srcSize.x + uint(boundedX)] * w;
        weight += w;
    }
    intermediate[id.y*outSize.x+id.x] = abs(weight)>0.00001f ? value/weight : float4(0.0f);
}
kernel void spektrafilm_scale_vertical(
    device const float4* intermediate [[buffer(0)]],
    device float4* dst [[buffer(1)]],
    constant uint2& roiSize [[buffer(2)]],
    constant uint2& outSize [[buffer(3)]],
    uint2 id [[thread_position_in_grid]]) {
    if (id.x >= outSize.x || id.y >= outSize.y) return;
    float y = (float(id.y) + 0.5f) * float(roiSize.y) / float(outSize.y) - 0.5f;
    float scale = max(1.0f, float(roiSize.y)/float(outSize.y));
    int center = int(floor(y));
    int radius = min(512, int(ceil(3.0f*scale)));
    float4 value = float4(0.0f); float weight = 0.0f;
    for (int i = -radius+1; i <= radius; ++i) {
        int sampleY = center+i;
        float w = lanczos3((float(sampleY)-y)/scale);
        if (w == 0.0f) continue;
        uint boundedY = uint(clamp(sampleY, 0, int(roiSize.y)-1));
        value += intermediate[boundedY*outSize.x+id.x] * w;
        weight += w;
    }
    dst[id.y*outSize.x+id.x] = abs(weight)>0.00001f ? value/weight : float4(0.0f);
}
"""#
}
