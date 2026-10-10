import Foundation
import Metal

// Experimental, OFF by default. GPL-3.0, based on SpektraFilm's own native spectral
// renderer (NOT a replacement film model). Inspired by ART's staged CLF generator.
// The 3D LUT is a COLOR-ONLY transform; native spatial effects remain authoritative.
// LUT construction, lookup, and publication stay entirely on the native Metal GPU.
// The cache is owned by GPULiveFramePipeline's actor; do not share this class elsewhere.
final class StudioSpectralLUT: @unchecked Sendable {
    static let setting = "SpektraFilmStudio.preview.spectralLUT.v1"
    static func selectedResolution() -> Int? {
        switch UserDefaults.standard.string(forKey: setting) {
        case "33": return 33
        case "65": return 65
        default: return nil // native spectral physics is the safe default
        }
    }

    private struct Entry {
        let key: Data
        let resolution: Int
        let texture: any MTLTexture
    }

    private final class RetainedBuffers: @unchecked Sendable {
        let buffers: [any MTLBuffer]
        init(_ buffers: [any MTLBuffer]) { self.buffers = buffers }
    }

    private let gpu: GPULiveDevice
    private let grid: any MTLComputePipelineState
    private let pack: any MTLComputePipelineState
    private let lookup: any MTLComputePipelineState
    private var recentlyUsed: [Entry] = []
    private let maxEntries = 3

    init(gpu: GPULiveDevice) throws {
        self.gpu = gpu
        let library = try gpu.device.makeLibrary(source: Self.metalSource, options: nil)
        func pipeline(_ name: String) throws -> any MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw GPULiveError.unavailable("LUT shader \(name) unavailable")
            }
            return try gpu.device.makeComputePipelineState(function: function)
        }
        grid = try pipeline("spektralGrid")
        pack = try pipeline("spektralPack3D")
        lookup = try pipeline("spektralLookupTetrahedral")
    }

    /// Returns false when using the normal Metal spectral engine is required.
    /// Never substitutes an arbitrary LUT when the current film response is spatial
    /// or depends on global image statistics.
    func encodeIfEligible(film: NativeRenderer, look: RenderLook,
                          source: any MTLBuffer, destination: any MTLBuffer,
                          width: Int, height: Int) async throws -> Bool {
        guard let resolution = Self.selectedResolution() else { return false }
        guard await film.isColorLUTEligible(look: look) else { return false }
        try Task.checkCancellation()
        let key = try makeKey(look: look, resolution: resolution)
        let texture: any MTLTexture
        if let index = recentlyUsed.firstIndex(where: { $0.key == key }) {
            let hit = recentlyUsed.remove(at: index)
            recentlyUsed.insert(hit, at: 0)
            texture = hit.texture
        } else {
            texture = try await bake(film: film, look: look, resolution: resolution)
            try Task.checkCancellation()
            recentlyUsed.insert(Entry(key: key, resolution: resolution, texture: texture), at: 0)
            if recentlyUsed.count > maxEntries { recentlyUsed.removeLast() }
        }
        guard let command = gpu.queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else {
            throw GPULiveError.unavailable("LUT lookup encoder unavailable")
        }
        let count = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !count.overflow,
              count.partialValue <= Int.max / 16,
              source.length >= count.partialValue * 16,
              destination.length >= count.partialValue * 16 else {
            encoder.endEncoding()
            throw GPULiveError.unavailable("LUT image dimensions/buffers mismatch")
        }
        var params = SIMD2<UInt32>(UInt32(width), UInt32(height))
        encoder.setComputePipelineState(lookup)
        encoder.setBuffer(source, offset: 0, index: 0)
        encoder.setBuffer(destination, offset: 0, index: 1)
        encoder.setTexture(texture, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 2)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        command.commit() // post-film commands use same queue and stay ordered
        return true
    }

    private func makeKey(look: RenderLook, resolution: Int) throws -> Data {
        // Ignore host tone, RAW and post-film lens settings: the baked stage has
        // access ONLY to native film parameters (`look.values`). This avoids
        // invalidating a film LUT whenever a scene exposure slider moves.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let values = try encoder.encode(look.values)
        var key = Data("SpektraColorLUT-v1|Rec2020-linear|\(resolution)|".utf8)
        key.append(values)
        return key
    }

    private func bake(film: NativeRenderer, look: RenderLook,
                      resolution n: Int) async throws -> any MTLTexture {
        let w = n * n, h = n
        let src = try gpu.allocateFloatBuffer(width: w, height: h)
        let dst = try gpu.allocateFloatBuffer(width: w, height: h)
        guard let gridCommand = gpu.queue.makeCommandBuffer(),
              let gridEncoder = gridCommand.makeComputeCommandEncoder() else {
            throw GPULiveError.unavailable("LUT grid encoder unavailable")
        }
        var size = UInt32(n)
        gridEncoder.setComputePipelineState(grid)
        gridEncoder.setBuffer(src, offset: 0, index: 0)
        gridEncoder.setBytes(&size, length: MemoryLayout<UInt32>.stride, index: 1)
        gridEncoder.dispatchThreads(MTLSize(width: w, height: h, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        gridEncoder.endEncoding()
        gridCommand.commit()
        // The grid is a synthetic image; the LUT gate has proved that all
        // source-dependent or spatial effects are disabled, so its pixel layout
        // cannot affect the film result.
        try await film.enqueueMetalFilm(
            GPUMetalFilmIO(source: src, destination: dst, queue: gpu.queue,
                           width: w, height: h), look: look)
        try Task.checkCancellation()

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba32Float
        descriptor.width = n
        descriptor.height = n
        descriptor.depth = n
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let lut = gpu.device.makeTexture(descriptor: descriptor),
              let command = gpu.queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else {
            throw GPULiveError.unavailable("3D LUT texture/encoder allocation failed")
        }
        encoder.setComputePipelineState(pack)
        encoder.setBuffer(dst, offset: 0, index: 0)
        encoder.setTexture(lut, index: 0)
        encoder.dispatchThreads(MTLSize(width: n, height: n, depth: n),
                                threadsPerThreadgroup: MTLSize(width: 4, height: 4, depth: 4))
        encoder.endEncoding()
        let retained = RetainedBuffers([src, dst])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            command.addCompletedHandler { completed in
                withExtendedLifetime(retained) {
                    if completed.status == .completed { continuation.resume() }
                    else { continuation.resume(throwing: GPULiveError.unavailable(
                        completed.error?.localizedDescription ?? "Spectral LUT bake failed")) }
                }
            }
            command.commit()
        }
        return lut
    }

    // We use float32 3D textures and manual tetrahedral interpolation; RGBA32Float
    // hardware-linear sampling is not available on every supported Intel/Radeon GPU.
    // Domain: signed, log-like [-2,64] scene-linear Rec.2020. Never gamma-encode
    // these RGB values before passing them to the native film engine.
    private static let metalSource = #"""
    #include <metal_stdlib>
    using namespace metal;

    inline float encodeChannel(float x) {
        if (x < 0.0f) {
            return 0.2f * (1.0f - log2(1.0f + min(-x, 2.0f) * 8.0f) / log2(17.0f));
        }
        return 0.2f + 0.8f * log2(1.0f + min(x, 64.0f) * 8.0f) / log2(513.0f);
    }
    inline float decodeChannel(float u) {
        if (u < 0.2f) {
            return -(exp2(((0.2f - u) / 0.2f) * log2(17.0f)) - 1.0f) / 8.0f;
        }
        return (exp2(((u - 0.2f) / 0.8f) * log2(513.0f)) - 1.0f) / 8.0f;
    }
    kernel void spektralGrid(device float4 *dst [[buffer(0)]],
                             constant uint &n [[buffer(1)]],
                             uint2 xy [[thread_position_in_grid]]) {
        uint w = n * n;
        if (xy.x >= w || xy.y >= n) return;
        uint r = xy.x % n, g = xy.x / n, b = xy.y;
        float3 x = float3(decodeChannel(float(r)/float(n-1)),
                          decodeChannel(float(g)/float(n-1)),
                          decodeChannel(float(b)/float(n-1)));
        dst[xy.y*w + xy.x] = float4(x, 1.0f);
    }
    kernel void spektralPack3D(device const float4 *source [[buffer(0)]],
                               texture3d<float, access::write> output [[texture(0)]],
                               uint3 xyz [[thread_position_in_grid]]) {
        uint n = output.get_width();
        if (xyz.x >= n || xyz.y >= n || xyz.z >= n) return;
        uint index = xyz.z*n*n + xyz.y*n + xyz.x;
        output.write(source[index], xyz);
    }
    inline float3 sampleTetra(texture3d<float, access::read> lut, float3 v) {
        uint n = lut.get_width();
        float3 q = clamp(v, 0.0f, 1.0f) * float(n-1);
        uint3 lo = uint3(floor(q));
        float3 f = q - float3(lo);
        uint3 a, b;
        if (f.x >= f.y) {
            if (f.y >= f.z)      { a=uint3(1,0,0); b=uint3(1,1,0); }
            else if (f.x >= f.z) { a=uint3(1,0,0); b=uint3(1,0,1); }
            else                 { a=uint3(0,0,1); b=uint3(1,0,1); }
        } else {
            if (f.x >= f.z)      { a=uint3(0,1,0); b=uint3(1,1,0); }
            else if (f.y >= f.z) { a=uint3(0,1,0); b=uint3(0,1,1); }
            else                 { a=uint3(0,0,1); b=uint3(0,1,1); }
        }
        float u1 = f[a.x ? 0 : (a.y ? 1 : 2)];
        uint3 delta = b-a;
        float u2 = f[delta.x ? 0 : (delta.y ? 1 : 2)];
        float u3 = f.x + f.y + f.z - u1 - u2;
        float3 c0 = lut.read(lo).rgb;
        float3 c1 = lut.read(min(lo+a,uint3(n-1))).rgb;
        float3 c2 = lut.read(min(lo+b,uint3(n-1))).rgb;
        float3 c3 = lut.read(min(lo+uint3(1),uint3(n-1))).rgb;
        return c0 + u1*(c1-c0) + u2*(c2-c1) + u3*(c3-c2);
    }
    kernel void spektralLookupTetrahedral(
        device const float4 *source [[buffer(0)]],
        device float4 *destination [[buffer(1)]],
        texture3d<float, access::read> lut [[texture(0)]],
        constant uint2 &shape [[buffer(2)]],
        uint2 xy [[thread_position_in_grid]]) {
        if (xy.x >= shape.x || xy.y >= shape.y) return;
        uint i = xy.y * shape.x + xy.x;
        float4 input = source[i];
        float3 u = float3(encodeChannel(input.x),encodeChannel(input.y),encodeChannel(input.z));
        destination[i] = float4(sampleTetra(lut, u), input.w);
    }
    """#
}
