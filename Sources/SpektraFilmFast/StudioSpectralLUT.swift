import Foundation
import Metal
import CryptoKit
import os

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
    private let disk = SpectralLUTDiskStore()
    private var pendingKeys = Set<Data>()
    private(set) var cacheHits = 0
    private(set) var cacheMisses = 0

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
            // Live render is never allowed to bake or load a LUT. A cold LUT
            // must use the native Metal renderer; background prewarm handles it.
            cacheMisses += 1
            return false
        }
        cacheHits += 1
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

    enum Prepared: Sendable { case inMemory, loadedFromDisk, generatedAndSaved, generatedButNotSaved }

    /// Called by the idle preview coordinator, NEVER from a slider callback.
    /// Loads existing LUTs across sessions; a new look is baked once and
    /// persisted. A failure never injects an invalid LUT into a live frame.
    func prewarm(film: NativeRenderer, look: RenderLook) async throws -> Prepared? {
        guard let n = Self.selectedResolution(),
              await film.isColorLUTEligible(look: look) else { return nil }
        let key = try makeKey(look: look, resolution: n)
        if recentlyUsed.contains(where: { $0.key == key }) { return .inMemory }
        if pendingKeys.contains(key) { return nil }
        pendingKeys.insert(key)
        defer { pendingKeys.remove(key) }
        try Task.checkCancellation()
        let texture: any MTLTexture
        let outcome: Prepared
        if let payload = try disk.load(key: key, resolution: n) {
            texture = try await upload(payload: payload, resolution: n)
            outcome = .loadedFromDisk
        } else {
            let baked = try await bake(film: film, look: look, resolution: n)
            texture = baked.texture
            do {
                try disk.save(baked.payload, key: key, resolution: n)
                outcome = .generatedAndSaved
            } catch {
                SpectralLUTDiskStore.logger.error("LUT disk cache write failed: \(String(describing: error))")
                outcome = .generatedButNotSaved
            }
        }
        try Task.checkCancellation()
        recentlyUsed.insert(Entry(key: key, resolution: n, texture: texture), at: 0)
        if recentlyUsed.count > maxEntries { recentlyUsed.removeLast() }
        return outcome
    }

    private func upload(payload: Data, resolution n: Int) async throws -> any MTLTexture {
        let descriptor = Self.textureDescriptor(n)
        guard let texture = gpu.device.makeTexture(descriptor: descriptor),
              let staging = gpu.device.makeBuffer(length: payload.count, options: .storageModeShared),
              let command = gpu.queue.makeCommandBuffer(),
              let blit = command.makeBlitCommandEncoder() else {
            throw GPULiveError.unavailable("Persisted spectral LUT Metal upload allocation failed")
        }
        payload.withUnsafeBytes { bytes in
            if let address = bytes.baseAddress {
                staging.contents().copyMemory(from: address, byteCount: payload.count)
            }
        }
        blit.copy(from: staging, sourceOffset: 0,
                  sourceBytesPerRow: n * 16, sourceBytesPerImage: n * n * 16,
                  sourceSize: MTLSize(width: n, height: n, depth: n),
                  to: texture, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        try await Self.finish(command: command, retaining: RetainedBuffers([staging]))
        return texture
    }

    private static func textureDescriptor(_ n: Int) -> MTLTextureDescriptor {
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rgba32Float
        d.width = n
        d.height = n
        d.depth = n
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        return d
    }

    private static func finish(command: any MTLCommandBuffer,
                               retaining payload: RetainedBuffers) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            command.addCompletedHandler { completed in
                withExtendedLifetime(payload) {
                    if completed.status == .completed { continuation.resume() }
                    else { continuation.resume(throwing: GPULiveError.unavailable(
                        completed.error?.localizedDescription ?? "Spectral LUT GPU command failed")) }
                }
            }
            command.commit()
        }
    }

    private func makeKey(look: RenderLook, resolution: Int) throws -> Data {
        // Ignore host tone, RAW and post-film lens settings: the baked stage has
        // access ONLY to native film parameters (`look.values`). This avoids
        // invalidating a film LUT whenever a scene exposure slider moves.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let values = try encoder.encode(look.values)
        var key = Data("SpektraColorLUT-v2|engine-60c7f467|Rec2020-linear|\(resolution)|".utf8)
        key.append(values)
        return key
    }

    private func bake(film: NativeRenderer, look: RenderLook,
                      resolution n: Int) async throws -> (texture: any MTLTexture, payload: Data) {
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

        guard let lut = gpu.device.makeTexture(descriptor: Self.textureDescriptor(n)),
              let command = gpu.queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder(),
              let staging = gpu.device.makeBuffer(length: n*n*n*16, options: .storageModeShared) else {
            throw GPULiveError.unavailable("3D LUT texture/encoder allocation failed")
        }
        encoder.setComputePipelineState(pack)
        encoder.setBuffer(dst, offset: 0, index: 0)
        encoder.setTexture(lut, index: 0)
        encoder.dispatchThreads(MTLSize(width: n, height: n, depth: n),
                                threadsPerThreadgroup: MTLSize(width: 4, height: 4, depth: 4))
        encoder.endEncoding()
        // One readback at LUT creation for persistence — NEVER per image/slider.
        // Film output is packed in the same R,G,B index order as the 3D texture.
        guard let blit = command.makeBlitCommandEncoder() else {
            throw GPULiveError.unavailable("Spectral LUT disk snapshot encoder unavailable")
        }
        blit.copy(from: dst, sourceOffset: 0, to: staging,
                  destinationOffset: 0, size: n*n*n*16)
        blit.endEncoding()
        try await Self.finish(command: command, retaining: RetainedBuffers([src, dst, staging]))
        let bytes = Data(bytes: staging.contents(), count: n*n*n*16)
        return (lut, bytes)
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

/// On-disk immutable color-look assets. Data is non-authoritative; corrupted
/// or incompatible files are ignored and the native engine remains available.
private struct SpectralLUTDiskStore {
    static let logger = Logger(subsystem: "SpektraFilmStudio", category: "SpectralLUTDisk")
    private struct Envelope: Codable {
        let schema: Int
        let resolution: Int
        let inputColorSpace: String
        let keySHA256: String
        let payloadSHA256: String
    }
    private let magic = Data("SFLUT2\n".utf8)
    private let budget: Int64 = 512 * 1024 * 1024

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func directory() throws -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                        in: .userDomainMask).first else {
            throw GPULiveError.unavailable("Application Support location unavailable")
        }
        let folder = appSupport.appendingPathComponent("SpektraFilmStudio", isDirectory: true)
                               .appendingPathComponent("SpectralLUTs-v2", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    private func location(for key: Data, resolution: Int) throws -> URL {
        try directory().appendingPathComponent("\(resolution)-\(digest(key)).sflut", isDirectory: false)
    }
    func load(key: Data, resolution: Int) throws -> Data? {
        let url = try location(for: key, resolution: resolution)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let bytes: Data
        do { bytes = try Data(contentsOf: url, options: [.mappedIfSafe]) }
        catch { return nil }
        let expected = resolution * resolution * resolution * 16
        guard bytes.count > magic.count + 4 + expected,
              bytes.prefix(magic.count) == magic else { return nil }
        let a = magic.count
        let headerLen = bytes[a..<(a+4)].enumerated().reduce(UInt32(0)) {
            $0 | UInt32($1.element) << UInt32($1.offset * 8)
        }
        let n = Int(headerLen)
        guard n > 0, n <= 4096, bytes.count == a + 4 + n + expected,
              let header = try? JSONDecoder().decode(Envelope.self, from: bytes.subdata(in: a+4..<a+4+n)),
              header.schema == 2, header.resolution == resolution,
              header.inputColorSpace == "linear-Rec2020-signed-v1",
              header.keySHA256 == digest(key) else { return nil }
        let payload = bytes.subdata(in: a+4+n..<bytes.count)
        guard digest(payload) == header.payloadSHA256 else { return nil }
        return payload
    }
    func save(_ payload: Data, key: Data, resolution: Int) throws {
        let expected = resolution * resolution * resolution * 16
        guard payload.count == expected else {
            throw GPULiveError.unavailable("Unexpected spectral LUT payload size")
        }
        let meta = Envelope(schema: 2, resolution: resolution,
                            inputColorSpace: "linear-Rec2020-signed-v1",
                            keySHA256: digest(key), payloadSHA256: digest(payload))
        let header = try JSONEncoder().encode(meta)
        guard header.count <= 4096 else { throw GPULiveError.unavailable("Spectral LUT header too large") }
        var file = Data()
        file.reserveCapacity(magic.count + 4 + header.count + payload.count)
        file.append(magic)
        let n = UInt32(header.count)
        file.append(contentsOf: [UInt8(truncatingIfNeeded:n), UInt8(truncatingIfNeeded:n >> 8),
                                 UInt8(truncatingIfNeeded:n >> 16),UInt8(truncatingIfNeeded:n >> 24)])
        file.append(header)
        file.append(payload)
        let url = try location(for: key, resolution: resolution)
        try file.write(to: url, options: [.atomic])
        prune(excluding: url)
    }
    private func prune(excluding current: URL) {
        guard let folder = try? directory(),
              let files = try? FileManager.default.contentsOfDirectory(at: folder,
                    includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: []) else { return }
        let sorted = files.filter { $0.pathExtension == "sflut" }.sorted {
            let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return d1 < d2
        }
        var used = sorted.reduce(Int64(0)) {
            $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        for url in sorted where used > budget && url != current {
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if (try? FileManager.default.removeItem(at: url)) != nil { used -= size }
        }
    }
}
