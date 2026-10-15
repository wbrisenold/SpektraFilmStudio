import CoreGraphics
import CoreImage
import Foundation
import MetalKit
import simd
import os.signpost

let gpuLivePipelineLog = OSLog(subsystem: "com.spektrafilm", category: "gpu_pipeline")

enum GPULiveError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return "GPU live: \(reason)"
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
    init(_ buffers: [any MTLBuffer]) { self.buffers = buffers }
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
        onRelease: (() -> Void)? = nil
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

    private let outputLock = NSLock()
    private var availableOutputTextures: [String: [any MTLTexture]] = [:]
    private var outputPoolBytes = 0
    private let maxOutputPoolBytes = 96 * 1024 * 1024
    private(set) var outputTextureReuses = 0
    private(set) var outputTextureAllocations = 0

    init(device: any MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw GPULiveError.unavailable("Metal queue creation failed")
        }
        self.queue = queue
        self.context = CIContext(
            mtlDevice: device,
            options: [
                .cacheIntermediates: true, .useSoftwareRenderer: false,
            ])
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
    }

    func allocateFloatBuffer(width: Int, height: Int) throws -> any MTLBuffer {
        let product = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !product.overflow,
            product.partialValue <= Int.max / 16,
            let buffer = device.makeBuffer(length: product.partialValue * 16, options: .storageModePrivate)
        else { throw GPULiveError.unavailable("Float image buffer allocation failed") }
        return buffer
    }

    func encodeTextureToBuffer(
        _ source: any MTLTexture, destination: any MTLBuffer,
        on command: any MTLCommandBuffer
    ) throws {
        guard let encoder = command.makeComputeCommandEncoder() else {
            throw GPULiveError.unavailable("RAW texture converter unavailable")
        }
        encoder.setComputePipelineState(textureToBuffer)
        encoder.setTexture(source, index: 0)
        encoder.setBuffer(destination, offset: 0, index: 0)
        encoder.dispatchThreads(
            MTLSize(width: source.width, height: source.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
    }

    func encodeBufferToTexture(
        _ source: any MTLBuffer, destination: any MTLTexture,
        on command: any MTLCommandBuffer
    ) throws {
        guard let encoder = command.makeComputeCommandEncoder() else {
            throw GPULiveError.unavailable("Display texture converter unavailable")
        }
        encoder.setComputePipelineState(bufferToTexture)
        encoder.setBuffer(source, offset: 0, index: 0)
        encoder.setTexture(destination, index: 0)
        encoder.dispatchThreads(
            MTLSize(width: destination.width, height: destination.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
    }

    func makeOutputTexture(width: Int, height: Int) throws -> any MTLTexture {
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
            outputLock.unlock()
            return ready
        }
        outputLock.unlock()
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        guard let texture = device.makeTexture(descriptor: d) else {
            throw GPULiveError.unavailable("Live display texture allocation failed")
        }
        outputLock.lock()
        outputTextureAllocations += 1
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
        guard outputPoolBytes + texture.allocatedSize <= maxOutputPoolBytes,
            availableOutputTextures[key, default: []].count < 3
        else { return }
        availableOutputTextures[key, default: []].append(texture)
        outputPoolBytes += texture.allocatedSize
    }
}

/// Serial latest-request-wins is owned by AppModel; this actor builds exactly
/// one GPU render at a time. RAW is reused while camera-development settings
/// stay fixed, and each effect is encoded on the SAME native Metal queue.
actor GPULiveFramePipeline {
    nonisolated static func supports(_ look: RenderLook) -> Bool {
        // Every stage we cannot yet reproduce identically must stay on the
        // authoritative exact path. No silently omitted local adjustments.
        if look.localGrades?.contains(where: { $0.enabled && $0.opacity > 0 }) == true { return false }
        // Crop, rotation, perspective and framing use StudioMetalGeometry.
        // Resolved auto contrast (one-shot / resolve-once bounds) is GPU-safe.
        // Unresolved auto still needs CPU quantile analysis — keep the exact path.
        if look.tone?.autoContrast == true && !(look.tone?.isAutoContrastResolved ?? false) { return false }
        if look.filmTone?.autoContrast == true && !(look.filmTone?.isAutoContrastResolved ?? false) { return false }
        if look.raw.denoiseMode != .off { return false }
        if SkinToneReference.outputRoleIndex(look) != 0 { return false }
        return true
    }
    private var film: NativeRenderer?
    private var gpu: GPULiveDevice?
    // Keep 3 developed RAW GPU textures warm; no RAM float arrays required.
    private var rawCache: [(key: DecodeKey, frame: MetalDevelopedRAW)] = []
    private let rawCacheCapacity = 3
    private var geometryGPU: StudioMetalGeometry?
    private var importCalibrationGPU: StudioImportCalibrationMetal?
    // SFS_PIPE_MODULE_REUSE_V1: each of these caches its compiled MTLComputePipelineState
    // and MTLLibrary. They used to be constructed inside render(), so the instance cache
    // was always empty and device.makeLibrary(source:) recompiled every kernel on every
    // frame — the cache was written to but never read. Own them here so it actually hits.
    // Rebuilt only when the Metal device changes (see invalidateGPUModules()).
    private var nlmeansGPU: NLMeansDenoiseModule?
    private var bilateralGPU: BilateralBlurModule?
    private var lensPipeGPU: LensCorrectionModule?

    private func invalidateGPUModules() {
        nlmeansGPU = nil
        bilateralGPU = nil
        lensPipeGPU = nil
        geometryGPU = nil
        importCalibrationGPU = nil
    }
    private var lastGPUMode = "spectral"
    // SFS_PREFIX_HASH_DIRTY_TAIL_V1
    // Interactive-only dirty-tail cache for the independent prefix (RAW decode →
    // texture conversion + import calibration). Tone/film/lens/effects/geometry
    // stay fully re-encoded every frame; the export and scanner paths are untouched.
    private var prefixCache: (hash: UInt64, width: Int, height: Int, buffer: any MTLBuffer)?
    // SFS_STAGE1_REUSABLE_SCRATCH_V1
    // The render actor only recycles buffers AFTER its completion fence.
    // A cancellation/error before the fence deliberately discards its borrowed
    // buffers instead of returning possibly in-flight GPU memory to the pool.
    // Output textures stay frame-owned: MTKView may still present an old frame.
    private var scratchByBytes: [Int: [any MTLBuffer]] = [:]
    private var scratchResidentBytes = 0
    private let scratchBudgetBytes = 96 * 1024 * 1024
    private let maxScratchPerSize = 5
    private var scratchReuseCount = 0
    private var scratchAllocCount = 0

    private func borrowScratch(gpu: GPULiveDevice, width: Int, height: Int) throws -> any MTLBuffer {
        let product = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !product.overflow,
            product.partialValue <= Int.max / 16
        else {
            throw GPULiveError.unavailable("Invalid GPU scratch dimensions")
        }
        let bytes = product.partialValue * 16
        if var slots = scratchByBytes[bytes], let reused = slots.popLast() {
            if slots.isEmpty { scratchByBytes.removeValue(forKey: bytes) } else { scratchByBytes[bytes] = slots }
            scratchResidentBytes -= bytes
            if reused.device.registryID == gpu.device.registryID {
                scratchReuseCount += 1
                return reused
            }
            // Don't pass a scratch buffer from an old GPU device to this queue.
        }
        scratchAllocCount += 1
        return try gpu.allocateFloatBuffer(width: width, height: height)
    }

    private func recycleScratch(_ buffers: [any MTLBuffer], gpu: GPULiveDevice) {
        for buffer in buffers {
            let bytes = buffer.length
            guard buffer.storageMode == .private,
                buffer.device.registryID == gpu.device.registryID,
                bytes > 0 && bytes <= scratchBudgetBytes,
                scratchResidentBytes <= scratchBudgetBytes - bytes,
                scratchByBytes[bytes, default: []].count < maxScratchPerSize
            else { continue }
            scratchByBytes[bytes, default: []].append(buffer)
            scratchResidentBytes += bytes
        }
    }

    func scratchPoolStats() -> (reused: Int, allocated: Int, retainedBytes: Int) {
        (scratchReuseCount, scratchAllocCount, scratchResidentBytes)
    }

    /// Stable hash over the independent prefix stages (RAW decode identity +
    /// import calibration). Suffix stages the user drags mid-gesture (tone, film,
    /// lens, effects, geometry) are deliberately excluded.
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
        invalidateGPUModules()
    }

    /// Returns the native film renderer's blocking reason, or nil when film runs.
    func lutBlockReason(look: RenderLook) async throws -> String? {
        guard Self.supports(look) else { return "masks, geometry, Auto Contrast, denoise or output role" }
        guard film != nil else { return "native spectral renderer unavailable" }
        return nil    }

    func render(
        url: URL, look: RenderLook, bypassImportTransform: Bool,
        decoder: ImageDecoder, longEdge: Int = 1080
    ) async throws -> GPULiveFrame {
        let signpostID = OSSignpostID(log: gpuLivePipelineLog)
        os_signpost(.begin, log: gpuLivePipelineLog, name: "GPULiveFramePipeline.render", signpostID: signpostID, "longEdge=%d", longEdge)
        defer { os_signpost(.end, log: gpuLivePipelineLog, name: "GPULiveFramePipeline.render", signpostID: signpostID) }
        
        // The exact code path remains authoritative when an unsupported stage
        // is active; DO NOT ignore layers or geometry to fake a fast preview.
        if look.localGrades?.contains(where: { $0.enabled && $0.opacity > 0 }) == true {
            throw GPULiveError.unavailable("local masks require the exact renderer")
        }
        // Geometry is handled after the film/Look and lens stages on Metal.
        if look.tone?.autoContrast == true || look.filmTone?.autoContrast == true {
            throw GPULiveError.unavailable("Auto Contrast requires full-frame analysis")
        }
        // Always run the native spectral film engine; no imported-LUT/looks modes.
        if lastGPUMode != "spectral" {
            rawCache.removeAll()
            prefixCache = nil
            gpu = nil
            invalidateGPUModules()
            lastGPUMode = "spectral"
        }
        if film == nil { film = try NativeRenderer(profile: .exact) }
        if gpu == nil {
            guard let film else { throw GPULiveError.unavailable("Native film engine unavailable") }
            let nativeDevice = try await film.preferredMetalDevice()
            gpu = try GPULiveDevice(device: nativeDevice.device)
            // Cached pipeline states belong to the old device; drop them with it.
            invalidateGPUModules()
        }
        guard let gpu else { throw GPULiveError.unavailable("Metal device unavailable") }
        // SFS_DECODE_KEY_FINGERPRINT_V1: without the file fingerprint this key made
        // rawCache and prefixCache serve stale GPU frames after an in-place edit of
        // the source (Lightroom round-trip, synced folder, camera write finishing).
        // The field defaults to "" for other call sites; here it must be populated or
        // this cache is exactly the stale tier the decoder fix set out to close.
        let key = DecodeKey(
            path: url.path, longEdge: longEdge, raw: look.raw,
            bypassImportTransform: bypassImportTransform,
            sourceFingerprint: ImageDecoder.sourceFingerprint(url))
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
        var pipeTexturesToReturn: [any MTLTexture] = []
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
                    bypassImportTransform: bypassImportTransform, gpu: gpu)
                rawCache.insert((key: key, frame: developed), at: 0)
                if rawCache.count > rawCacheCapacity { rawCache.removeLast() }
            }
            try Task.checkCancellation()
            width = developed.width
            height = developed.height
            source = try borrowScratch(gpu: gpu, width: width, height: height)
            // The previously cached prefix buffer's commands already completed on
            // the serial queue; hand it back to the scratch pool.
            if let stale = prefixCache?.buffer { borrowedScratch.append(stale) }
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
                    calibration: calibration, on: preCommand)
            }
        }
        try gpu.host.encode(
            source: source, destination: graded, on: preCommand,
            width: width, height: height,
            tone: look.tone, density: look.colorDensity, film: look.filmTone)
        preCommand.commit()
        try Task.checkCancellation()
        let renderedStart = ProcessInfo.processInfo.systemUptime
        guard let film else { throw GPULiveError.unavailable("Native film engine unavailable") }
        try await film.enqueueMetalFilm(
            GPUMetalFilmIO(
                source: graded, destination: filmOutput,
                queue: gpu.queue, width: width, height: height), look: look)
        try Task.checkCancellation()
        guard let postCommand = gpu.queue.makeCommandBuffer() else {
            throw GPULiveError.unavailable("Post-film Metal command allocation failed")
        }
        var renderBuffer: any MTLBuffer = filmOutput
        var renderKeepAlive: [any MTLBuffer] = [source, graded, filmOutput]
        // Ported Lightamer GPU filter pipeline (PipeSettings). When the user has
        // enabled any stage in the Cull/Edit UI, inject the enabled stages AFTER the
        // film pass and BEFORE geometry, on the same serial Metal queue.
        //
        // NLMeans/Bilateral are preview-only image-processing filters. The existing
        // look.raw.denoiseMode gate is left untouched: it still forces the exact
        // renderer for RAW development, so `supports()` keeps returning false when
        // denoiseMode != .off. These pipe stages are an opt-in live path.
        //
        // Lens here is the *ported Lightamer lens kernel* (distortion + TCA + vignette),
        // independent of LensOpticalMetal / LensCharacterPanel which live in the
        // exact/spectral path today. When both are enabled we apply the ported kernel
        // as a non-destructive preview filter.
        //
        // Tone stages (sigmoid/agx/filmicRGB) replace the film LUT for the live preview
        // only when explicitly selected; they never change the settled/export path.
        if let pipe = look.pipe, !pipe.isEmpty {
            // Extra scratch buffers needed for the pipeline: one working buffer per
            // stage. Borrow from the same scratch pool; the fence still owns them.
            var pipeScratch: [any MTLBuffer] = []
            for _ in 1...4 { pipeScratch.append(try borrowScratch(gpu: gpu, width: width, height: height)) }
            renderKeepAlive.append(contentsOf: pipeScratch)
            // Also hand them to the recycler: the fence below waits for the GPU, so by
            // the time recycleScratch runs they are provably idle.
            borrowedScratch.append(contentsOf: pipeScratch)
            // Single command buffer for the pipeline so all stages submit atomically.
            guard let pipeCommand = gpu.queue.makeCommandBuffer() else {
                throw GPULiveError.unavailable("Pipe command allocation failed")
            }
            let pipeSource = renderBuffer
            let pipeDest = pipeScratch[0]
            let pipeWidth = width
            let pipeHeight = height

            var pipeTextures: [any MTLTexture] = []                // Convert the current source buffer → texture for the pipe chain.
                let pipeInputTexture = try gpu.makeOutputTexture(width: pipeWidth, height: pipeHeight)
                pipeTextures.append(pipeInputTexture)
                try gpu.encodeBufferToTexture(pipeSource, destination: pipeInputTexture, on: pipeCommand)

                var currentPipeTexture = pipeInputTexture
                let pipeSettings = pipe

            // NLMeans denoise (preview-only). Skips if disabled.
            if pipeSettings.stages[.nlmeans] == true {
                if nlmeansGPU == nil { nlmeansGPU = NLMeansDenoiseModule(device: gpu.device) }
                guard let nl = nlmeansGPU else { throw GPULiveError.unavailable("NLMeans module unavailable") }
                nl.commitParams(NLMeansDenoiseModule.Params(
                    radius: pipeSettings.nlmeans.radius,
                    strength: pipeSettings.nlmeans.strength,
                    luma: pipeSettings.nlmeans.luma,
                    chroma: pipeSettings.nlmeans.chroma
                ))
                let nlOutput = try gpu.makeOutputTexture(width: pipeWidth, height: pipeHeight)
                pipeTextures.append(nlOutput)
                try nl.encode(commandBuffer: pipeCommand, input: currentPipeTexture, output: nlOutput, width: pipeWidth, height: pipeHeight)
                currentPipeTexture = nlOutput
            }
            // Bilateral blur (preview-only). Skips if disabled.
            if pipeSettings.stages[.bilateral] == true {
                if bilateralGPU == nil { bilateralGPU = BilateralBlurModule(device: gpu.device) }
                guard let bl = bilateralGPU else { throw GPULiveError.unavailable("Bilateral module unavailable") }
                bl.commitParams(BilateralBlurModule.Params(
                    radius: pipeSettings.bilateral.radius,
                    redSigma: pipeSettings.bilateral.redSigma,
                    greenSigma: pipeSettings.bilateral.greenSigma,
                    blueSigma: pipeSettings.bilateral.blueSigma
                ))
                let blOutput = try gpu.makeOutputTexture(width: pipeWidth, height: pipeHeight)
                pipeTextures.append(blOutput)
                try bl.encode(commandBuffer: pipeCommand, input: currentPipeTexture, output: blOutput, width: pipeWidth, height: pipeHeight)
                currentPipeTexture = blOutput
            }
            // Ported Lightamer lens correction (distortion + TCA + vignette).
            if pipeSettings.stages[.lens] == true {
                if lensPipeGPU == nil { lensPipeGPU = LensCorrectionModule(device: gpu.device) }
                guard let lc = lensPipeGPU else { throw GPULiveError.unavailable("Lens correction module unavailable") }
                lc.commitParams(LensCorrectionModule.Params(
                    distortionK1: pipeSettings.lens.distortionK1, distortionK2: pipeSettings.lens.distortionK2,
                    distortionK3: pipeSettings.lens.distortionK3, distortionK4: pipeSettings.lens.distortionK4,
                    tcaRed: pipeSettings.lens.tcaRed, tcaBlue: pipeSettings.lens.tcaBlue,
                    vignetteK1: pipeSettings.lens.vignetteK1, vignetteK2: pipeSettings.lens.vignetteK2,
                    vignetteK3: pipeSettings.lens.vignetteK3, vignetteK4: pipeSettings.lens.vignetteK4
                ))
                let lensOutput = try gpu.makeOutputTexture(width: pipeWidth, height: pipeHeight)
                pipeTextures.append(lensOutput)
                try lc.encode(commandBuffer: pipeCommand, input: currentPipeTexture, output: lensOutput, width: pipeWidth, height: pipeHeight)
                currentPipeTexture = lensOutput
            }
            // Tone mapping (sigmoid/AgX/FilmicRGB) was removed: the native spectral
            // film pass owns tone, so the pipe injects preview filters only.
            // Convert the final pipe texture back to a buffer for the geometry pass.
            try gpu.encodeTextureToBuffer(currentPipeTexture, destination: pipeDest, on: pipeCommand)
            pipeCommand.commit()
            try Task.checkCancellation()
            // After the pipe command completes, pipeDest holds the filtered result.
            renderBuffer = pipeDest
            renderKeepAlive.append(pipeScratch[1])
            pipeTexturesToReturn = pipeTextures
        }
        let geometry = look.geometry ?? GeometrySettings()
        let hasGeometry = geometry != GeometrySettings()
        let geometrySize = StudioMetalGeometry.targetSize(
            sourceWidth: width,
            sourceHeight: height, geometry: geometry)
        let texture = try gpu.makeOutputTexture(
            width: geometrySize.width,
            height: geometrySize.height)
        if hasGeometry {
            if geometryGPU == nil { geometryGPU = try StudioMetalGeometry(device: gpu.device) }
            try geometryGPU?.encode(
                source: renderBuffer, destination: texture,
                width: width, height: height, geometry: geometry, command: postCommand)
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
                                command.error?.localizedDescription ?? "Metal post processing failed"))
                    }
                }
            }
            postCommand.commit()
        }
        recycleScratch(borrowedScratch, gpu: gpu)  // The async Metal completion fence has returned.
        for pipeTexture in pipeTexturesToReturn { gpu.returnOutputTexture(pipeTexture) }
        try Task.checkCancellation()
        let elapsed = (ProcessInfo.processInfo.systemUptime - renderedStart) * 1000.0
        let label: String
        label = "Native spectral Metal · \(Int(elapsed.rounded())) ms"
        return GPULiveFrame(
            texture: texture,
            colorSpace: OutputColorProfile.forLook(look).cgColorSpace,
            rendererLabel: label,
            onRelease: { [gpu] in gpu.returnOutputTexture(texture) })
    }
}
