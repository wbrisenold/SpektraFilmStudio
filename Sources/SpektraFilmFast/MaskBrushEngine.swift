import Foundation
import Metal

/// Soft circular strokes are rasterized on Metal; the saved bitmap is shared by preview/export.
final class MaskBrushEngine: @unchecked Sendable {
    static let shared = MaskBrushEngine()
    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let pipeline: MTLComputePipelineState?
    private init() {
        device = StudioGPUDevice.shared
        queue = device?.makeCommandQueue()
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void paint(device uchar *alpha [[buffer(0)]], constant float2 *points [[buffer(1)]],
                          constant uint4 &info [[buffer(2)]], constant float4 &brush [[buffer(3)]], uint2 xy [[thread_position_in_grid]]) {
            if (xy.x >= info.x || xy.y >= info.y) return;
            float2 p = float2(xy) + 0.5f;
            float distance = INFINITY;
            for (uint i = 0; i < info.z; ++i) {
                float2 a = points[i] * float2(info.xy);
                float2 b = points[min(i + 1, info.z - 1)] * float2(info.xy);
                float2 ab = b - a;
                float t = clamp(dot(p-a, ab) / max(dot(ab, ab), 0.0001f), 0.0f, 1.0f);
                distance = min(distance, length(p - (a + t * ab)));
            }
            float coverage = (1.0f - smoothstep(brush.x * 0.65f, brush.x, distance)) * brush.y;
            uint index = xy.y * info.x + xy.x;
            float existing = float(alpha[index]) / 255.0f;
            alpha[index] = uchar(round((brush.z > 0 ? existing * (1.0f-coverage) : max(existing, coverage)) * 255.0f));
        }
        """
        if let device, let library = try? device.makeLibrary(source: source, options: nil), let function = library.makeFunction(name: "paint") {
            pipeline = try? device.makeComputePipelineState(function: function)
        } else { pipeline = nil }
    }
    func paint(_ previous: RasterMaskPayload?, width: Int, height: Int, points: [ImagePoint], radius: Double, erase: Bool = false) throws -> RasterMaskPayload {
        guard width > 0, height > 0, !points.isEmpty, let device, let queue, let pipeline else {
            throw RendererError.renderFailed("GPU brush unavailable")
        }
        var alpha = previous?.decodedAlpha() ?? [UInt8](repeating: 0, count: width * height)
        guard alpha.count == width * height else { throw RendererError.renderFailed("Brush dimensions changed") }
        let locations = points.map { SIMD2<Float>(Float($0.x), Float($0.y)) }
        guard let output = alpha.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
              let path = locations.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
              let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw RendererError.renderFailed("Cannot allocate GPU brush")
        }
        var info = SIMD4<UInt32>(UInt32(width), UInt32(height), UInt32(points.count), 0)
        var brush = SIMD4<Float>(Float(radius * Double(max(width, height))), 1, erase ? 1 : 0, 0)
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(output, offset: 0, index: 0); encoder.setBuffer(path, offset: 0, index: 1)
        encoder.setBytes(&info, length: MemoryLayout.size(ofValue: info), index: 2)
        encoder.setBytes(&brush, length: MemoryLayout.size(ofValue: brush), index: 3)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { throw RendererError.renderFailed("GPU brush failed") }
        let byteCount = alpha.count
        alpha.withUnsafeMutableBytes { $0.copyBytes(from: UnsafeRawBufferPointer(start: output.contents(), count: byteCount)) }
        return RasterMaskPayload(width: width, height: height, alpha: alpha)
    }
}
