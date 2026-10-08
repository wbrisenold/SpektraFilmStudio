import Foundation
import Metal

/// GPU foundation for Stage 2. It deliberately works on generic Metal buffers/textures so
/// the exact SpektraFilm renderer remains untouched. A caller can render any grade into a
/// second texture, then composite it through the mask coverage generated here.
final class MaskMetalEngine: @unchecked Sendable {
    // Reuse a single compiled Metal kernel suite instead of recompiling per mask.
    static let shared = MaskMetalEngine()
    enum EngineError: Error { case unavailable, compileFailed, pipelineFailed, allocationFailed }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let radialPSO: MTLComputePipelineState
    private let gradientPSO: MTLComputePipelineState
    private let rasterPSO: MTLComputePipelineState
    private let combinePSO: MTLComputePipelineState
    private let compositePSO: MTLComputePipelineState

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        do {
            let lib = try device.makeLibrary(source: Self.shaderSource, options: nil)
            guard let radial = lib.makeFunction(name: "mask_radial"),
                  let gradient = lib.makeFunction(name: "mask_linear_gradient"),
                  let raster = lib.makeFunction(name: "mask_raster"),
                  let combine = lib.makeFunction(name: "mask_combine"),
                  let composite = lib.makeFunction(name: "mask_composite_rgba") else { return nil }
            radialPSO = try device.makeComputePipelineState(function: radial)
            gradientPSO = try device.makeComputePipelineState(function: gradient)
            rasterPSO = try device.makeComputePipelineState(function: raster)
            combinePSO = try device.makeComputePipelineState(function: combine)
            compositePSO = try device.makeComputePipelineState(function: composite)
        } catch { return nil }
    }

    struct GeometryUniforms {
        var p0x: Float; var p0y: Float; var p1x: Float; var p1y: Float
        var rotation: Float; var feather: Float; var opacity: Float; var inverted: UInt32
    }

    struct CombineUniforms { var mode: UInt32 }
    struct CompositeUniforms { var opacity: Float }

    /// Redlamp-derived ordered mask evaluator, now on the Metal device.
    /// The exact same coverage plane is used for post-film local adjustments and
    /// on-screen mask compositing. Return nil on memory/kernel failure so the
    /// CPU Redlamp port is a deterministic fallback on older Intel hardware.
    func renderCoverage(grade: LocalGradeRecord, width: Int, height: Int) -> [Float]? {
        guard width > 0, height > 0, width <= 16384,
              height <= 16384, width <= Int.max / height else { return nil }
        let count = width * height
        let sources = grade.masks.sources.filter(\.enabled)
        if grade.masks.sources.isEmpty { return [Float](repeating: 1, count: count) }
        if sources.isEmpty { return [Float](repeating: 0, count: count) }
        guard let commands = queue.makeCommandBuffer(),
              var current = makeCoverageBuffer(pixelCount: count) else { return nil }
        memset(current.contents(), 0, count * MemoryLayout<Float>.stride)
        do {
            for (index, source) in sources.enumerated() {
                guard let next = makeCoverageBuffer(pixelCount: count) else { return nil }
                if source.kind == .raster {
                    try encodeRasterSource(commandBuffer: commands, source: source,
                                           width: width, height: height, output: next)
                } else {
                    try encodeGeometricSource(commandBuffer: commands, source: source,
                                              width: width, height: height, output: next)
                }
                if index == 0 {
                    if source.blendMode != .subtract { current = next }
                } else {
                    guard let combined = makeCoverageBuffer(pixelCount: count) else { return nil }
                    try encodeCombine(commandBuffer: commands, lhs: current, rhs: next,
                                      destination: combined, count: count, mode: source.blendMode)
                    current = combined
                }
            }
            commands.commit()
            commands.waitUntilCompleted()
            guard commands.status == .completed else { return nil }
            let ptr = current.contents().assumingMemoryBound(to: Float.self)
            return Array(UnsafeBufferPointer(start: ptr, count: count))
        } catch { return nil }
    }

    private func encodeRasterSource(
        commandBuffer: MTLCommandBuffer, source: MaskSourceRecord,
        width: Int, height: Int, output: MTLBuffer
    ) throws {
        guard let payload = source.raster,
              payload.width > 0, payload.height > 0 else { throw EngineError.unavailable }
        let alpha = payload.decodedAlpha()
        guard alpha.count == payload.width * payload.height,
              let mask = device.makeBuffer(length: alpha.count, options: .storageModeShared),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw EngineError.allocationFailed
        }
        alpha.withUnsafeBytes { ptr in
            if let base = ptr.baseAddress { memcpy(mask.contents(), base, alpha.count) }
        }
        var u = GeometryUniforms(p0x: 0, p0y: 0, p1x: 0, p1y: 0, rotation: 0,
                                 feather: Float(source.feather), opacity: Float(source.opacity),
                                 inverted: source.inverted ? 1 : 0)
        var dims = SIMD2<UInt32>(UInt32(width), UInt32(height))
        var rasterDims = SIMD2<UInt32>(UInt32(payload.width), UInt32(payload.height))
        encoder.setComputePipelineState(rasterPSO)
        encoder.setBuffer(mask, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.setBytes(&u, length: MemoryLayout<GeometryUniforms>.stride, index: 2)
        encoder.setBytes(&dims, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 3)
        encoder.setBytes(&rasterDims, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 4)
        dispatch(encoder, pso: rasterPSO, count: width * height)
        encoder.endEncoding()
    }

    func makeCoverageBuffer(pixelCount: Int) -> MTLBuffer? {
        device.makeBuffer(length: max(1, pixelCount) * MemoryLayout<Float>.stride, options: .storageModeShared)
    }

    /// Encodes one geometric source into `output` as normalized coverage.
    func encodeGeometricSource(
        commandBuffer: MTLCommandBuffer,
        source: MaskSourceRecord,
        width: Int,
        height: Int,
        output: MTLBuffer
    ) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw EngineError.unavailable }
        let pso: MTLComputePipelineState
        var u: GeometryUniforms
        switch source.kind {
        case .radial:
            let g = source.radial ?? RadialMaskGeometry()
            pso = radialPSO
            u = .init(p0x: Float(g.center.x), p0y: Float(g.center.y), p1x: Float(g.radiusX), p1y: Float(g.radiusY), rotation: Float(g.rotationDegrees * .pi / 180), feather: Float(source.feather), opacity: Float(source.opacity), inverted: source.inverted ? 1 : 0)
        case .linearGradient:
            let g = source.linearGradient ?? LinearGradientMaskGeometry()
            pso = gradientPSO
            u = .init(p0x: Float(g.start.x), p0y: Float(g.start.y), p1x: Float(g.end.x), p1y: Float(g.end.y), rotation: 0, feather: Float(source.feather), opacity: Float(source.opacity), inverted: source.inverted ? 1 : 0)
        case .raster:
            encoder.endEncoding()
            throw EngineError.unavailable
        }
        encoder.setComputePipelineState(pso)
        encoder.setBuffer(output, offset: 0, index: 0)
        encoder.setBytes(&u, length: MemoryLayout<GeometryUniforms>.stride, index: 1)
        var dims = SIMD2<UInt32>(UInt32(width), UInt32(height))
        encoder.setBytes(&dims, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 2)
        dispatch(encoder, pso: pso, count: width * height)
        encoder.endEncoding()
    }

    /// Ordered Add/Subtract/Intersect operation. `destination` may alias `lhs`.
    func encodeCombine(commandBuffer: MTLCommandBuffer, lhs: MTLBuffer, rhs: MTLBuffer, destination: MTLBuffer, count: Int, mode: MaskBlendMode) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw EngineError.unavailable }
        var u = CombineUniforms(mode: mode == .add ? 0 : (mode == .subtract ? 1 : 2))
        encoder.setComputePipelineState(combinePSO)
        encoder.setBuffer(lhs, offset: 0, index: 0)
        encoder.setBuffer(rhs, offset: 0, index: 1)
        encoder.setBuffer(destination, offset: 0, index: 2)
        encoder.setBytes(&u, length: MemoryLayout<CombineUniforms>.stride, index: 3)
        dispatch(encoder, pso: combinePSO, count: count)
        encoder.endEncoding()
    }

    /// Composites a separately-rendered local grade through coverage without altering the
    /// underlying grade renderer. Inputs/outputs are RGBA32F buffers, four floats per pixel.
    func encodeComposite(commandBuffer: MTLCommandBuffer, baseRGBA: MTLBuffer, gradedRGBA: MTLBuffer, coverage: MTLBuffer, outputRGBA: MTLBuffer, pixelCount: Int, opacity: Float) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw EngineError.unavailable }
        var u = CompositeUniforms(opacity: max(0, min(1, opacity)))
        encoder.setComputePipelineState(compositePSO)
        encoder.setBuffer(baseRGBA, offset: 0, index: 0)
        encoder.setBuffer(gradedRGBA, offset: 0, index: 1)
        encoder.setBuffer(coverage, offset: 0, index: 2)
        encoder.setBuffer(outputRGBA, offset: 0, index: 3)
        encoder.setBytes(&u, length: MemoryLayout<CompositeUniforms>.stride, index: 4)
        dispatch(encoder, pso: compositePSO, count: pixelCount)
        encoder.endEncoding()
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, pso: MTLComputePipelineState, count: Int) {
        let w = min(pso.maxTotalThreadsPerThreadgroup, max(1, pso.threadExecutionWidth * 4))
        encoder.dispatchThreads(MTLSize(width: max(1, count), height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
    }

    private static let shaderSource = #"""
#include <metal_stdlib>
using namespace metal;
struct G { float2 p0; float2 p1; float rotation; float feather; float opacity; uint inverted; };
struct C { uint mode; };
struct O { float opacity; };
inline float apply_common(float v, constant G& g) { v = clamp(v, 0.0f, 1.0f); if (g.inverted) v = 1.0f - v; return v * clamp(g.opacity,0.0f,1.0f); }
kernel void mask_radial(device float* out [[buffer(0)]], constant G& g [[buffer(1)]], constant uint2& dims [[buffer(2)]], uint id [[thread_position_in_grid]]) {
    uint n=dims.x*dims.y; if(id>=n) return; uint x=id%dims.x, y=id/dims.x; float2 p=(float2(x,y)+0.5f)/float2(dims);
    float2 d=p-g.p0; float c=cos(-g.rotation), s=sin(-g.rotation); d=float2(c*d.x-s*d.y,s*d.x+c*d.y);
    float2 r=max(g.p1,float2(1e-4f)); float q=length(d/r); float fw=clamp(g.feather,1e-5f,1.0f); float inner=min(0.999f,1.0f-fw); float v=1.0f-smoothstep(inner,1.0f,q); out[id]=apply_common(v,g);
}
kernel void mask_linear_gradient(device float* out [[buffer(0)]], constant G& g [[buffer(1)]], constant uint2& dims [[buffer(2)]], uint id [[thread_position_in_grid]]) {
    uint n=dims.x*dims.y; if(id>=n) return; uint x=id%dims.x, y=id/dims.x; float2 p=(float2(x,y)+0.5f)/float2(dims);
    float2 axis=g.p1-g.p0; float denom=max(dot(axis,axis),1e-6f); float t=dot(p-g.p0,axis)/denom; float fw=max(g.feather,1e-5f); float v=smoothstep(0.5f-fw,0.5f+fw,t); out[id]=apply_common(v,g);
}
// Redlamp Masks.h bilinear raster sampling, adapted to RLE-decoded 8-bit alpha.
kernel void mask_raster(device const uchar* alpha [[buffer(0)]], device float* out [[buffer(1)]],
                        constant G& g [[buffer(2)]], constant uint2& dims [[buffer(3)]],
                        constant uint2& rdims [[buffer(4)]], uint id [[thread_position_in_grid]]) {
    uint count=dims.x*dims.y; if(id>=count) return;
    uint x=id%dims.x,y=id/dims.x;
    float2 uv=(float2(x,y)+0.5f)/float2(dims);
    float2 p=clamp(uv*float2(rdims)-0.5f,float2(0.0f),float2(rdims-1));
    uint x0=uint(p.x),y0=uint(p.y),x1=min(x0+1,rdims.x-1),y1=min(y0+1,rdims.y-1);
    float2 t=p-float2(x0,y0);
    float a=mix(float(alpha[y0*rdims.x+x0]),float(alpha[y0*rdims.x+x1]),t.x);
    float b=mix(float(alpha[y1*rdims.x+x0]),float(alpha[y1*rdims.x+x1]),t.x);
    out[id]=apply_common(mix(a,b,t.y)/255.0f,g);
}
kernel void mask_combine(device const float* a [[buffer(0)]], device const float* b [[buffer(1)]], device float* out [[buffer(2)]], constant C& c [[buffer(3)]], uint id [[thread_position_in_grid]]) {
    float x=clamp(a[id],0.0f,1.0f), y=clamp(b[id],0.0f,1.0f); float v;
    if(c.mode==0) v=max(x,y); else if(c.mode==1) v=x*(1.0f-y); else v=x*y; out[id]=clamp(v,0.0f,1.0f);
}
kernel void mask_composite_rgba(device const float4* base [[buffer(0)]], device const float4* grade [[buffer(1)]], device const float* coverage [[buffer(2)]], device float4* out [[buffer(3)]], constant O& o [[buffer(4)]], uint id [[thread_position_in_grid]]) {
    float a=clamp(coverage[id]*o.opacity,0.0f,1.0f); out[id]=mix(base[id],grade[id],a);
}
"""#
}
