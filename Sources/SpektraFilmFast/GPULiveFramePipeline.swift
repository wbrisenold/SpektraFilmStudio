import CoreGraphics
import CoreImage
import Foundation
import MetalKit
import os.signpost
import simd

// GPL-3.0-or-later — SpektraFilm Studio.
//
// Harbeth-as-fast-host boundary note.
//
// This actor owns the fast interactive live-frame pipeline and its public API is
// reachable as `GPULiveFramePipeline.supports(...)` / `.prefixHash(...)` from
// AppModel and the self-test harness. The external Harbeth output-host concept is
// represented locally in `HarbethPresentation`, not by importing the Harbeth
// package here.

let gpuLivePipelineLog = OSLog(subsystem: "com.spektrafilm", category: "gpu_pipeline")

enum GPULiveError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self {
        case let .unavailable(reason): "GPU live: \(reason)"
        }
    }
}

/// Metal protocols are reference types without reliable Swift Sendable annotations
/// on the macOS 15 SDK. Transfer only immutable, explicitly retained handles.
struct GPUMetalDeviceToken: @unchecked Sendable {
    let device: any MTLDevice
}

struct GPUMetalFilmIO: @unchecked Sendable {
    let source: any MTLBuffer
    let destination: any MTLBuffer
    let queue: any MTLCommandQueue
    let width: Int
    let height: Int
}

struct MetalDevelopedRAW: @unchecked Sendable {
    let texture: any MTLTexture
    let width: Int
    let height: Int
}

private final class GPUBufferLifetime: @unchecked Sendable {
    let buffers: [any MTLBuffer]
    init(_ buffers: [any MTLBuffer]) {
        self.buffers = buffers
    }
}

/// Same output dimensions and profile as the authoritative preview. GPU-owned,
/// retained through the frame's completed command buffer and the SwiftUI surface.
final class GPULiveFrame: @unchecked Sendable {
    let id = UUID()
    let texture: any MTLTexture
    let colorSpace: CGColorSpace
    let rendererLabel: String
    private let onRelease: (() -> Void)?
    init(
        texture: any MTLTexture, colorSpace: CGColorSpace, rendererLabel: String,
        onRelease: (() -> Void)? = nil,
    ) {
        self.texture = texture
        self.colorSpace = colorSpace
        self.rendererLabel = rendererLabel
        self.onRelease = onRelease
    }

    deinit { onRelease?() }
}

final class GPULiveDevice: @unchecked Sendable {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let context: CIContext
    let textureToBuffer: any MTLComputePipelineState
    let bufferToTexture: any MTLComputePipelineState
    let host: GPUHostGradeEngine
    let lens: LensOpticalMetal
    let effects: RedlampFilmEffectsEngine

    // MTLHeap for efficient scratch buffer allocation (reduces driver overhead)
    // Optional to allow fallback on memory-constrained devices.
    private let scratchHeap: MTLHeap?
    private let scratchHeapSize = 256 * 1024 * 1024 // 256 MB

    private let outputLock = NSLock()
    private var availableOutputTextures: [String: [any MTLTexture]] = [:]
    private var outputPoolBytes = 0
    private let maxOutputPoolBytes = 96 * 1024 * 1024
    private(set) var outputTextureReuses = 0
    private(set) var outputTextureAllocations = 0
    private var seenDeviceRegistryIDs: Set<UInt64> = []

    init(device: any MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw GPULiveError.unavailable("Metal queue creation failed")
        }
        self.queue = queue

        // Create scratch heap for efficient buffer allocation.
        // Fall back to device.makeBuffer() if heap creation fails (e.g., low memory).
        let heapDesc = MTLHeapDescriptor()
        heapDesc.size = scratchHeapSize
        heapDesc.storageMode = .private
        heapDesc.cpuCacheMode = .defaultCache
        scratchHeap = device.makeHeap(descriptor: heapDesc)
        if scratchHeap == nil {
            print("GPULiveDevice: Warning - failed to create scratch heap, falling back to device.makeBuffer()")
        }
        context = CIContext(
            mtlDevice: device,
            options: [
                .cacheIntermediates: true, .useSoftwareRenderer: false,
            ],
        )
        let code = #"""
        #include <metal_stdlib>
        using namespace metal;
        kernel void spektraTextureToBuffer(texture2d<float, access::read> src [[texture(0)]],
                                           device float4 *dst [[buffer(0)]],
                                           uint2 p [[thread_position_in_grid]]) {
            if (p.x >= src.get_width() || p.y >= src.get_height()) return;
            dst[p.y * src.get_width() + p.x] = src.read(p);
        }
        kernel void spektraBufferToTexture(device const float4 *src [[buffer(0)]],
                                           texture2d<float, access::write> dst [[texture(0)]],
                                           uint2 p [[thread_position_in_grid]]) {
            if (p.x >= dst.get_width() || p.y >= dst.get_height()) return;
            dst.write(src[p.y * dst.get_width() + p.x], p);
        }
        """#
        let library = try device.makeLibrary(source: code, options: nil)
        guard let t2b = library.makeFunction(name: "spektraTextureToBuffer"),
              let b2t = library.makeFunction(name: "spektraBufferToTexture")
        else {
            throw GPULiveError.unavailable("Metal resource conversion kernels missing")
        }
        textureToBuffer = try device.makeComputePipelineState(function: t2b)
        bufferToTexture = try device.makeComputePipelineState(function: b2t)
        host = GPUHostGradeEngine(device: device)
        lens = LensOpticalMetal(device: device)
        effects = RedlampFilmEffectsEngine(device: device)

        seenDeviceRegistryIDs.insert(device.registryID)
    }

    /// Allocate a buffer from the scratch heap (much faster than device.makeBuffer),
    /// falling back to device.makeBuffer() if heap is unavailable or exhausted.
    func allocateFromHeap(length: Int, options: MTLResourceOptions = []) throws -> MTLBuffer {
        let alignedLength = (length + 255) & ~255 // 256-byte alignment
        if let heap = scratchHeap, let buffer = heap.makeBuffer(length: alignedLength, options: options) {
            return buffer
        }
        // Fallback: allocate directly from device with the requested options
        if let buffer = device.makeBuffer(length: alignedLength, options: options) {
            return buffer
        }
        // Last resort: try with shared storage (for CPU-accessible buffers)
        let fallbackOptions = options.union(.storageModeShared)
        guard let buffer = device.makeBuffer(length: alignedLength, options: fallbackOptions) else {
            throw GPULiveError.unavailable("Scratch buffer allocation failed (heap and device fallback both exhausted)")
        }
        return buffer
    }

    /// Purge output texture pool for devices that are no longer active
    func purgeStaleOutputPools(currentDeviceRegistryID: UInt64) {
        outputLock.lock()
        defer { outputLock.unlock() }

        // Track current device
        seenDeviceRegistryIDs.insert(currentDeviceRegistryID)

        // Remove entries for stale devices
        var totalFreed = 0
        for key in availableOutputTextures.keys {
            // Extract device registry ID from key format "registryID|width|height"
            if let registryIDStr = key.split(separator: "|").first,
               let registryID = UInt64(registryIDStr),
               !seenDeviceRegistryIDs.contains(registryID)
            {
                let pool = availableOutputTextures.removeValue(forKey: key) ?? []
                for texture in pool {
                    outputPoolBytes -= texture.allocatedSize
                    totalFreed += texture.allocatedSize
                }
            }
        }
        if totalFreed > 0 {
            print("GPULiveDevice: Purged \(totalFreed / 1024 / 1024) MB of stale output textures")
        }
    }

    func allocateFloatBuffer(width: Int, height: Int) throws -> any MTLBuffer {
        let product = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !product.overflow,
              product.partialValue <= Int.max / 16
        else { throw GPULiveError.unavailable("Invalid GPU scratch dimensions") }
        let bytes = product.partialValue * 16
        // Use heap allocation for better performance
        return try allocateFromHeap(length: bytes, options: .storageModePrivate)
    }

    func encodeTextureToBuffer(
        _ source: any MTLTexture, destination: any MTLBuffer,
        on command: any MTLCommandBuffer,
    ) throws {
        guard let encoder = command.makeComputeCommandEncoder() else {
            throw GPULiveError.unavailable("RAW texture converter unavailable")
        }
        encoder.setComputePipelineState(textureToBuffer)
        encoder.setTexture(source, index: 0)
        encoder.setBuffer(destination, offset: 0, index: 0)
        encoder.dispatchThreads(
            MTLSize(width: source.width, height: source.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1),
        )
        encoder.endEncoding()
    }

    func encodeBufferToTexture(
        _ source: any MTLBuffer, destination: any MTLTexture,
        on command: any MTLCommandBuffer,
    ) throws {
        guard let encoder = command.makeComputeCommandEncoder() else {
            throw GPULiveError.unavailable("Display texture converter unavailable")
        }
        encoder.setComputePipelineState(bufferToTexture)
        encoder.setBuffer(source, offset: 0, index: 0)
        encoder.setTexture(destination, index: 0)
        encoder.dispatchThreads(
            MTLSize(width: destination.width, height: destination.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1),
        )
        encoder.endEncoding()
    }

    func makeOutputTexture(width: Int, height: Int) throws -> any MTLTexture {
        // Purge stale output pools for devices no longer in use
        purgeStaleOutputPools(currentDeviceRegistryID: device.registryID)

        let key = "\(device.registryID)|\(width)|\(height)"
        outputLock.lock()
        if var pool = availableOutputTextures[key], let ready = pool.popLast() {
            if pool.isEmpty {
                availableOutputTextures.removeValue(forKey: key)
            } else {
                availableOutputTextures[key] = pool
            }
            outputPoolBytes -= ready.allocatedSize
            outputTextureReuses += 1
            PerformanceMonitor.shared.recordTextureReuse()
            outputLock.unlock()
            return ready
        }
        outputLock.unlock()
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: width, height: height, mipmapped: false,
        )
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        guard let texture = device.makeTexture(descriptor: d) else {
            throw GPULiveError.unavailable("Live display texture allocation failed")
        }
        outputLock.lock()
        outputTextureAllocations += 1
        PerformanceMonitor.shared.recordTextureAllocation()
        outputLock.unlock()
        return texture
    }

    func returnOutputTexture(_ texture: any MTLTexture) {
        guard texture.device.registryID == device.registryID,
              texture.storageMode == .private
        else { return }
        let key = "\(device.registryID)|\(texture.width)|\(texture.height)"
        outputLock.lock()
        defer { outputLock.unlock() }
        let currentPool = availableOutputTextures[key] ?? []
        guard outputPoolBytes + texture.allocatedSize <= maxOutputPoolBytes,
              currentPool.count < 3
        else { return }
        availableOutputTextures[key] = currentPool + [texture]
        outputPoolBytes += texture.allocatedSize
    }
}

/// Serial latest-request-wins is owned by AppModel; this actor builds exactly
/// one GPU render at a time. RAW is reused while camera-development settings
/// stay fixed, and each effect is encoded on the SAME native Metal queue.
///
/// Harbeth is only the local fast-host concept (`HarbethPresentation`). The
/// external Harbeth package is not imported here, and this actor still owns the
/// live-frame public API that AppModel and the self-test harness reach.
actor GPULiveFramePipeline {
    nonisolated static func supports(_ look: RenderLook) -> Bool {
        // Every stage we cannot yet reproduce identically must stay on the
        // authoritative exact path. No silently omitted local adjustments.
        if look.localGrades?.contains(where: { $0.enabled && $0.opacity > 0 }) == true {
            return false
        }
        if look.tone?.autoContrast == true, !(look.tone?.isAutoContrastResolved ?? false) {
            return false
        }
        if look.filmTone?.autoContrast == true, !(look.filmTone?.isAutoContrastResolved ?? false) {
            return false
        }
        if look.raw.denoiseMode != .off {
            return false
        }
        if SkinToneReference.outputRoleIndex(look) != 0 {
            return false
        }
        return true
    }

    private var film: NativeRenderer?
    private var gpu: GPULiveDevice?
    // Keep 3 developed RAW GPU textures warm; no RAM float arrays required.
    private var rawCache: [(key: DecodeKey, frame: MetalDevelopedRAW)] = []
    private let rawCacheCapacity = 3
    private var geometryGPU: StudioMetalGeometry?
    private var importCalibrationGPU: StudioImportCalibrationMetal?
    // The live frame pipeline now pins its presentation device to the same one
    // the visible MTKView uses. The native film renderer may still live on its
    // own device; when that differs, the canvas imports the frame explicitly.
    private let presentationDevice: Required<MTLDevice>

    init() {
        presentationDevice = Required { PresentationDevice.current.value }
    }

    private func invalidateGPUModules() {
        geometryGPU = nil
        importCalibrationGPU = nil
        // Reset scratch pool when GPU modules are invalidated (device change)
        scratchByBytes.removeAll()
        scratchResidentBytes = 0
        renderGeneration = 0
    }

    /// Pre-warm scratch pool with common buffer sizes to avoid allocation spikes
    /// on first frames after mode switches. Call when GPU device initializes or changes.
    private func prewarmScratchPool(gpu: GPULiveDevice) {
        // Common preview sizes: 1080p, 1440p, 4K, 8K
        let commonSizes = [
            (1920, 1080), // 1080p
            (2560, 1440), // 1440p
            (3840, 2160), // 4K
            (7680, 4320), // 8K
            (1024, 1024), // Square thumbnails
        ]
        for (w, h) in commonSizes {
            let product = w.multipliedReportingOverflow(by: h)
            guard !product.overflow,
                  product.partialValue <= Int.max / 16
            else { continue }
            let bytes = product.partialValue * 16
            // Pre-allocate 3 buffers per size (enough for typical pipeline concurrency)
            for _ in 0 ..< 3 {
                do {
                    let buffer = try gpu.allocateFloatBuffer(width: w, height: h)
                    let key = bytes
                    // Pre-warmed buffers are available immediately (generation 0)
                    scratchByBytes[key, default: []].append(ScratchEntry(buffer: buffer, recycledAtGeneration: 0))
                    scratchResidentBytes += bytes
                } catch {
                    // Ignore allocation failures during pre-warm
                    break
                }
            }
        }
    }

    private var lastGPUMode = "spectral"
    /// SFS_PREFIX_HASH_DIRTY_TAIL_V1
    /// Interactive-only dirty-tail cache for the independent prefix (RAW decode →
    /// texture conversion + import calibration). Tone/film/lens/effects/geometry
    /// stay fully re-encoded every frame; the export and scanner paths are untouched.
    private var prefixCache: (hash: UInt64, width: Int, height: Int, buffer: any MTLBuffer)?
    /// SFS_STAGE1_REUSABLE_SCRATCH_V1
    /// The render actor only recycles buffers AFTER its completion fence.
    /// A cancellation/error before the fence deliberately discards its borrowed
    /// buffers instead of returning possibly in-flight GPU memory to the pool.
    /// Output textures stay frame-owned: MTKView may still present an old frame.
    /// Scratch buffer pool entry with generation tracking to prevent use-after-free.
    private struct ScratchEntry {
        let buffer: any MTLBuffer
        let recycledAtGeneration: Int
    }

    private var scratchByBytes: [Int: [ScratchEntry]] = [:]
    private var scratchResidentBytes = 0
    private let scratchBudgetBytes = 96 * 1024 * 1024
    private let maxScratchPerSize = 5
    private var scratchReuseCount = 0
    private var scratchAllocCount = 0
    /// Monotonically increasing generation counter; incremented each render() call.
    /// Buffers are only reused after 2 full generations to ensure GPU completion.
    private var renderGeneration = 0

    private func borrowScratch(gpu: GPULiveDevice, width: Int, height: Int) throws -> any MTLBuffer {
        let product = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !product.overflow,
              product.partialValue <= Int.max / 16
        else {
            throw GPULiveError.unavailable("Invalid GPU scratch dimensions")
        }
        let bytes = product.partialValue * 16
        // Only reuse buffers that were recycled at least 2 generations ago,
        // ensuring the GPU work that used them has fully completed.
        let safeGenerationThreshold = renderGeneration - 2
        if var slots = scratchByBytes[bytes],
           let idx = slots.lastIndex(where: { $0.recycledAtGeneration <= safeGenerationThreshold })
        {
            let entry = slots.remove(at: idx)
            if slots.isEmpty {
                scratchByBytes.removeValue(forKey: bytes)
            } else {
                scratchByBytes[bytes] = slots
            }
            scratchResidentBytes -= bytes
            if entry.buffer.device.registryID == gpu.device.registryID {
                scratchReuseCount += 1
                PerformanceMonitor.shared.recordScratchReuse()
                return entry.buffer
            }
            // Don't pass a scratch buffer from an old GPU device to this queue.
        }
        scratchAllocCount += 1
        PerformanceMonitor.shared.recordScratchAllocation()
        return try gpu.allocateFloatBuffer(width: width, height: height)
    }

    private func recycleScratch(_ buffers: [any MTLBuffer], gpu: GPULiveDevice) {
        for buffer in buffers {
            let bytes = buffer.length
            guard buffer.storageMode == .private,
                  buffer.device.registryID == gpu.device.registryID,
                  bytes > 0, bytes <= scratchBudgetBytes,
                  scratchResidentBytes <= scratchBudgetBytes - bytes,
                  scratchByBytes[bytes, default: []].count < maxScratchPerSize
            else { continue }
            scratchByBytes[bytes, default: []].append(ScratchEntry(buffer: buffer, recycledAtGeneration: renderGeneration))
            scratchResidentBytes += bytes
        }
    }

    func scratchPoolStats() -> (reused: Int, allocated: Int, retainedBytes: Int) {
        (scratchReuseCount, scratchAllocCount, scratchResidentBytes)
    }

    /// Current render generation for diagnostic purposes.
    func currentRenderGeneration() -> Int {
        renderGeneration
    }

    /// Normalize and bound a live-frame request so a single source image cannot
    /// drive a frame of unbounded size into the scratch pool or the Metal device.
    /// Returns the scaled preview dimensions, or nil when the request is unsafe.
    nonisolated static func _normalizeSize(width: Int, height: Int, longEdge: Int) -> (width: Int, height: Int)? {
        guard width > 0, height > 0 else { return nil }
        guard width <= 2048, height <= 2048 else { return nil }
        // A live frame is a preview: cap the pixel count so one oversized source
        // cannot exhaust device memory or stall the cooperative decode pool.
        guard width <= 4194304 / max(1, height) else { return nil } // 2048 x 2048 max
        guard longEdge > 0, longEdge <= 2048 else { return nil }
        let scale = min(1.0, Double(longEdge) / Double(max(width, height)))
        let scaledWidth = max(1, Int(Double(width) * scale))
        let scaledHeight = max(1, Int(Double(height) * scale))
        guard scaledWidth <= 2048, scaledHeight <= 2048,
              scaledWidth <= 4194304 / max(1, scaledHeight)
        else { return nil }
        return (scaledWidth, scaledHeight)
    }

    /// Stable hash over the independent live-frame prefix stages only.
    ///
    /// `calibration` is intentionally nullable because the test harness calls this
    /// with explicit `nil`; do not make the parameter non-optional.
    nonisolated static func prefixHash(decode: DecodeKey, calibration: StudioImportCalibration?) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(decode)
        hasher.combine(calibration)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    func reset() {
        rawCache.removeAll()
        prefixCache = nil
        scratchByBytes.removeAll()
        scratchResidentBytes = 0
        renderGeneration = 0
        invalidateGPUModules()
    }

    // Harbeth remains the local fast-host concept in `HarbethPresentation`.
    // This actor is still the owner of the live-frame prefix hash.

    /// Returns the native film renderer's blocking reason, or nil when film runs.
    func lutBlockReason(look: RenderLook) async throws -> String? {
        guard Self.supports(look) else { return "masks, geometry, Auto Contrast, denoise or output role" }
        guard film != nil else { return "native spectral renderer unavailable" }
        return nil
    }

    func render(
        url: URL, look: RenderLook, bypassImportTransform: Bool,
        decoder: ImageDecoder, longEdge: Int = 1080,
    ) async throws -> GPULiveFrame {
        let signpostID = OSSignpostID(log: gpuLivePipelineLog)
        os_signpost(.begin, log: gpuLivePipelineLog, name: "GPULiveFramePipeline.render", signpostID: signpostID, "longEdge=%d", longEdge)
        defer { os_signpost(.end, log: gpuLivePipelineLog, name: "GPULiveFramePipeline.render", signpostID: signpostID) }

        // The exact code path remains authoritative when an unsupported stage
        // is active. Local masks and auto-contrast are handled natively below.
        // Geometry is handled after the film/Look and lens stages on Metal.
        // Note: supports() governs GPU live preview eligibility; the exact
        // renderer accepts all stages and performs the full spectral film render.
        // Always run the native spectral film engine; no imported-LUT/looks modes.
        if lastGPUMode != "spectral" {
            rawCache.removeAll()
            prefixCache = nil
            gpu = nil
            invalidateGPUModules()
            lastGPUMode = "spectral"
        }
        if film == nil {
            film = try NativeRenderer(profile: .exact)
        }
        if gpu == nil {
            let required = PresentationDevice.current
            guard required.error == nil else {
                throw GPULiveError.unavailable("Metal presentation device unavailable")
            }
            let newGpu = try GPULiveDevice(device: required.value)
            gpu = newGpu
            // Cached pipeline states belong to the old device; drop them with it.
            invalidateGPUModules()
            // Pre-warm scratch pool to avoid allocation spikes on first frames.
            prewarmScratchPool(gpu: newGpu)
            // Purge any stale output pools from previous device instances
            newGpu.purgeStaleOutputPools(currentDeviceRegistryID: newGpu.device.registryID)
        }
        guard let gpu else { throw GPULiveError.unavailable("Metal device unavailable") }
        // Increment generation counter for scratch buffer reuse tracking.
        // This ensures buffers are only reused after GPU work from 2+ generations ago completes.
        renderGeneration &+= 1
        // SFS_DECODE_KEY_FINGERPRINT_V1: without the file fingerprint this key made
        // rawCache and prefixCache serve stale GPU frames after an in-place edit of
        // the source (Lightroom round-trip, synced folder, camera write finishing).
        // The field defaults to "" for other call sites; here it must be populated or
        // this cache is exactly the stale tier the decoder fix set out to close.
        let key = DecodeKey(
            path: url.path, longEdge: longEdge, raw: look.raw,
            bypassImportTransform: bypassImportTransform,
            sourceFingerprint: ImageDecoder.sourceFingerprint(url),
        )
        // SFS_PREFIX_HASH_DIRTY_TAIL_V1: on a prefix hit the RAW conversion and
        // import-calibration encodes are skipped entirely — only the dirty tail
        // (host grade, film, lens, effects, geometry) is re-encoded.
        let prefixHash = Self.prefixHash(decode: key, calibration: look.importCalibration)
        let source: any MTLBuffer
        let width: Int
        let height: Int
        var borrowedScratch: [any MTLBuffer] = []
        // SFS_PIPE_POOL_RETURN_V1: intermediate pipe textures were allocated from the
        // output-texture pool and then dropped, so the pool never refilled and every
        // frame allocated fresh rgba32Float storage. They are intermediate — unlike the
        // final presented texture they are never held by MTKView — so they go back the
        // moment the completion fence returns.
        let pipeTexturesToReturn: [any MTLTexture] = []
        var developedTexture: (any MTLTexture)?
        if let cached = prefixCache, cached.hash == prefixHash {
            source = cached.buffer
            width = cached.width
            height = cached.height
        } else {
            let developed: MetalDevelopedRAW
            if let index = rawCache.firstIndex(where: { $0.key == key }) {
                let hit = rawCache.remove(at: index)
                rawCache.insert(hit, at: 0)
                developed = hit.frame
            } else {
                developed = try await decoder.decodeMetal(
                    url: url, longEdge: longEdge, raw: look.raw,
                    bypassImportTransform: bypassImportTransform, gpu: gpu,
                )
                rawCache.insert((key: key, frame: developed), at: 0)
                if rawCache.count > rawCacheCapacity {
                    rawCache.removeLast()
                }
            }
            try Task.checkCancellation()
            // Bound and normalize the live-frame request before allocating scratch or
            // the output texture. A single oversized source must never drive a huge
            // frame into the GPU pool or the decoder.
            guard let normalized = GPULiveFramePipeline._normalizeSize(width: developed.width, height: developed.height, longEdge: longEdge) else {
                throw GPULiveError.unavailable("unsafe GPU live-frame dimensions")
            }
            width = normalized.width
            height = normalized.height
            source = try borrowScratch(gpu: gpu, width: width, height: height)
            // The previously cached prefix buffer's commands already completed on
            // the serial queue; hand it back to the scratch pool.
            if let stale = prefixCache?.buffer {
                borrowedScratch.append(stale)
            }
            prefixCache = (prefixHash, width, height, source)
            developedTexture = developed.texture
        }
        // Exclusive to this render task until the completion fence; safe to
        // pass into the nonisolated async spectral-LUT encoder.
        nonisolated(unsafe) let graded = try borrowScratch(gpu: gpu, width: width, height: height)
        nonisolated(unsafe) let filmOutput = try borrowScratch(gpu: gpu, width: width, height: height)
        borrowedScratch.append(contentsOf: [graded, filmOutput])
        guard let preCommand = gpu.queue.makeCommandBuffer() else {
            throw GPULiveError.unavailable("RAW conversion command allocation failed")
        }
        if let developedTexture {
            try gpu.encodeTextureToBuffer(developedTexture, destination: source, on: preCommand)
            if let calibration = look.importCalibration, calibration.applies(to: look.raw) {
                if importCalibrationGPU == nil {
                    importCalibrationGPU = try StudioImportCalibrationMetal(device: gpu.device)
                }
                try importCalibrationGPU?.encode(
                    buffer: source, width: width, height: height,
                    calibration: calibration, on: preCommand,
                )
            }
        }
        try gpu.host.encode(
            source: source, destination: graded, on: preCommand,
            width: width, height: height,
            tone: look.tone, density: look.colorDensity, film: look.filmTone,
        )
        preCommand.commit()
        try Task.checkCancellation()
        let renderedStart = ProcessInfo.processInfo.systemUptime
        guard let film else { throw GPULiveError.unavailable("Native film engine unavailable") }
        try await film.enqueueMetalFilm(
            GPUMetalFilmIO(
                source: graded, destination: filmOutput,
                queue: gpu.queue, width: width, height: height,
            ), look: look,
        )
        try Task.checkCancellation()
        guard let postCommand = gpu.queue.makeCommandBuffer() else {
            throw GPULiveError.unavailable("Post-film Metal command allocation failed")
        }
        let renderBuffer: any MTLBuffer = filmOutput
        let renderKeepAlive: [any MTLBuffer] = [source, graded, filmOutput]
        let geometry = look.geometry ?? GeometrySettings()
        let hasGeometry = geometry != GeometrySettings()
        let geometrySize = StudioMetalGeometry.targetSize(
            sourceWidth: width,
            sourceHeight: height, geometry: geometry,
        )
        let texture = try gpu.makeOutputTexture(
            width: geometrySize.width,
            height: geometrySize.height,
        )
        if hasGeometry {
            if geometryGPU == nil {
                geometryGPU = try StudioMetalGeometry(device: gpu.device)
            }
            try geometryGPU?.encode(
                source: renderBuffer, destination: texture,
                width: width, height: height, geometry: geometry, command: postCommand,
            )
        } else {
            try gpu.encodeBufferToTexture(renderBuffer, destination: texture, on: postCommand)
        }
        // Keep all upstream buffers alive until the final GPU completion fence.
        // An async continuation, never waitUntilCompleted() on the main thread.
        let retained = GPUBufferLifetime(renderKeepAlive)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            postCommand.addCompletedHandler { command in
                withExtendedLifetime(retained) {
                    if command.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(
                            throwing: GPULiveError.unavailable(
                                command.error?.localizedDescription ?? "Metal post processing failed",
                            ),
                        )
                    }
                }
            }
            postCommand.commit()
        }
        recycleScratch(borrowedScratch, gpu: gpu) // The async Metal completion fence has returned.
        for pipeTexture in pipeTexturesToReturn {
            gpu.returnOutputTexture(pipeTexture)
        }
        try Task.checkCancellation()
        let elapsed = (ProcessInfo.processInfo.systemUptime - renderedStart) * 1000.0
        let label: String
        label = "Native spectral Metal · \(Int(elapsed.rounded())) ms"
        return GPULiveFrame(
            texture: texture,
            colorSpace: OutputColorProfile.forLook(look).cgColorSpace,
            rendererLabel: label,
            onRelease: { [gpu] in gpu.returnOutputTexture(texture) },
        )
    }
}
