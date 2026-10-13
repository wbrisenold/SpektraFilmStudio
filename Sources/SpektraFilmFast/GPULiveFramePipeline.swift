import CoreGraphics
import CoreImage
import Foundation
import Metal

// SpektraFilmStudio GPL-3.0 — production-facing experimental live GPU pipeline.
// No full-frame CPU RGBA readback between RAW development, host grade, spectral
// film simulation, lens character, film effects, and preview publication.
// Advanced local masks / geometric transforms / Auto Contrast remain on the
// original exact renderer until identical GPU equivalents pass color parity.

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
    private var spectralLUT: StudioSpectralLUT?
    private var importedLUT: StudioImportedLUTMetal?
    private var contentGuard: MetalFrameContentGuard?
    private var looksGPU: StudioLooksGPU?
    private var geometryGPU: StudioMetalGeometry?
    private var importCalibrationGPU: StudioImportCalibrationMetal?
    private var lastGPUMode = ""
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
    }

    /// Called before Prepare: returns the actual blocking stage, not a generic
    /// silent nil.  This does not change the spectral engine's correctness gate.
    func lutBlockReason(look: RenderLook) async throws -> String? {
        if !Self.supports(look) { return "masks, geometry, Auto Contrast, denoise or output role" }
        if film == nil { film = try NativeRenderer(profile: .exact) }
        guard let film else { return "native spectral renderer unavailable" }
        return await film.colorLUTBlockingReason(look: look)
    }

    /// The only code path permitted to read or create LUT assets. Triggered
    /// after an idle settled render; never on a pointer-rate live render.
    func prewarmLUT(look: RenderLook) async throws -> StudioSpectralLUT.Prepared? {
        guard StudioSpectralLUT.selectedResolution() != nil,
            Self.supports(look)
        else { return nil }
        if film == nil { film = try NativeRenderer(profile: .exact) }
        guard let film else { return nil }
        guard await film.isColorLUTEligible(look: look) else { return nil }
        if gpu == nil {
            let nativeDevice = try await film.preferredMetalDevice()
            gpu = try GPULiveDevice(device: nativeDevice.device)
        }
        guard let gpu else { return nil }
        if spectralLUT == nil { spectralLUT = try StudioSpectralLUT(gpu: gpu) }
        return try await spectralLUT?.prewarm(film: film, look: look)
    }

    /// Reuse the exact SAME resident film LUT for settled frames. This never
    /// prepares or bakes LUTs. Missing/ineligible LUTs return nil explicitly.
    /// The CPU readback is required only by the existing mask/geometry display
    /// adapter, not by the interactive Metal view.
    func settledCachedFilmLUT(_ input: PixelBufferF32, look: RenderLook) async throws -> PixelBufferF32? {
        guard StudioSpectralLUT.selectedResolution() != nil,
            Self.supports(look), let spectralLUT
        else { return nil }
        if film == nil { film = try NativeRenderer(profile: .exact) }
        guard let film else { return nil }
        if gpu == nil {
            let device = try await film.preferredMetalDevice()
            gpu = try GPULiveDevice(device: device.device)
        }
        guard let gpu else { return nil }
        let count = input.pixels.count
        guard input.width > 0, input.height > 0,
            count == input.width * input.height * 4,
            count <= Int.max / 4
        else { throw GPULiveError.unavailable("Invalid settled LUT frame") }
        let bytes = count * MemoryLayout<Float>.stride
        guard
            let source = input.pixels.withUnsafeBytes({ data in
                gpu.device.makeBuffer(bytes: data.baseAddress!, length: bytes, options: .storageModeShared)
            }),
            let destination = gpu.device.makeBuffer(length: bytes, options: .storageModeShared)
        else {
            throw GPULiveError.unavailable("Settled LUT Metal buffers unavailable")
        }
        let used = try await spectralLUT.encodeIfEligible(
            film: film, look: look,
            source: source, destination: destination, width: input.width, height: input.height)
        guard used else { return nil }
        guard let fence = gpu.queue.makeCommandBuffer() else {
            throw GPULiveError.unavailable("Settled LUT fence unavailable")
        }
        let retained = GPUBufferLifetime([source, destination])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            fence.addCompletedHandler { completed in
                withExtendedLifetime(retained) {
                    if completed.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(
                            throwing: GPULiveError.unavailable(
                                completed.error?.localizedDescription ?? "Settled LUT GPU failure"))
                    }
                }
            }
            fence.commit()  // same FIFO Metal queue; previous LUT kernel completed
        }
        try Task.checkCancellation()
        var pixels = [Float](repeating: 0, count: count)
        pixels.withUnsafeMutableBytes { dest in
            dest.baseAddress!.copyMemory(from: destination.contents(), byteCount: bytes)
        }
        return PixelBufferF32(width: input.width, height: input.height, pixels: pixels)
    }

    func render(
        url: URL, look: RenderLook, bypassImportTransform: Bool,
        decoder: ImageDecoder, longEdge: Int = 1080
    ) async throws -> GPULiveFrame {
        // The exact code path remains authoritative when an unsupported stage
        // is active; DO NOT ignore layers or geometry to fake a fast preview.
        if look.localGrades?.contains(where: { $0.enabled && $0.opacity > 0 }) == true {
            throw GPULiveError.unavailable("local masks require the exact renderer")
        }
        // Geometry is handled after the film/Look and lens stages on Metal.
        if look.tone?.autoContrast == true || look.filmTone?.autoContrast == true {
            throw GPULiveError.unavailable("Auto Contrast requires full-frame analysis")
        }
        // Imported .cube is the authoritative FILM stage when selected.
        // It NEVER initializes or calls NativeRenderer (not even on a cache miss).
        let usedImportedLUT = StudioImportedCubeLUTSettings.isSelected
        let useLooks = StudioLooksSettings.isSelected
        let spectralMode = !usedImportedLUT && !useLooks
        let modeIdentity = spectralMode ? "spectral" : (usedImportedLUT ? "imported-lut" : "looks")
        if lastGPUMode != modeIdentity {
            // Do not reuse GPU-device-specific shader/buffer caches initialized
            // by a different spectral/looks-imported engine on dual-GPU Intel Macs.
            rawCache.removeAll()
            prefixCache = nil
            gpu = nil
            importedLUT = nil
            spectralLUT = nil
            looksGPU = nil
            geometryGPU = nil
            importCalibrationGPU = nil
            lastGPUMode = modeIdentity
        }
        if !usedImportedLUT && film == nil { film = try NativeRenderer(profile: .exact) }
        if gpu == nil {
            if usedImportedLUT || useLooks {
                guard let device = StudioGPUDevice.shared else {
                    throw GPULiveError.unavailable("Metal GPU unavailable for imported LUT")
                }
                gpu = try GPULiveDevice(device: device)
            } else {
                guard let film else { throw GPULiveError.unavailable("Native film engine unavailable") }
                let nativeDevice = try await film.preferredMetalDevice()
                gpu = try GPULiveDevice(device: nativeDevice.device)
            }
        }
        if contentGuard == nil {
            contentGuard = try MetalFrameContentGuard(device: gpu!.device)
        }
        guard let gpu else { throw GPULiveError.unavailable("Metal device unavailable") }
        let key = DecodeKey(
            path: url.path, longEdge: longEdge, raw: look.raw,
            bypassImportTransform: bypassImportTransform)
        // SFS_PREFIX_HASH_DIRTY_TAIL_V1: on a prefix hit the RAW conversion and
        // import-calibration encodes are skipped entirely — only the dirty tail
        // (host grade, film, lens, effects, geometry) is re-encoded.
        let prefixHash = Self.prefixHash(decode: key, calibration: look.importCalibration)
        let source: any MTLBuffer
        let width: Int
        let height: Int
        var borrowedScratch: [any MTLBuffer] = []
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
        let importedMode = usedImportedLUT
        if useLooks {
            if looksGPU == nil { looksGPU = try StudioLooksGPU(device: gpu.device) }
            try looksGPU?.encodePre(graded, width: width, height: height, look: look, command: preCommand)
        }
        preCommand.commit()
        try Task.checkCancellation()
        // Only ALREADY GPU-resident LUTs may run during slider movement.
        // A cold/missing LUT uses native Metal immediately, never bakes inline.
        let resolution = StudioSpectralLUT.selectedResolution()
        let renderedStart = ProcessInfo.processInfo.systemUptime
        guard let film else { throw GPULiveError.unavailable("Native film engine unavailable") }
        var usedSpectralLUT = false
        if !usedImportedLUT && !useLooks && resolution != nil, let spectralLUT {
            do {
                usedSpectralLUT = try await spectralLUT.encodeIfEligible(
                    film: film, look: look, source: graded, destination: filmOutput,
                    width: width, height: height)
            } catch is CancellationError { throw CancellationError() } catch { usedSpectralLUT = false }
        }
        let lutMiss = !usedImportedLUT && !usedSpectralLUT
        if importedMode {
            if importedLUT == nil { importedLUT = try StudioImportedLUTMetal(gpu: gpu) }
            guard let lutFile = StudioImportedCubeLUTSettings.selectedURL else {
                throw GPULiveError.unavailable("Imported LUT selected but file missing")
            }
            let contract = StudioImportedLUT.Contract.legacySRGB
            try importedLUT?.encode(
                source: graded, destination: filmOutput,
                width: width, height: height,
                on: gpu.queue.makeCommandBuffer()!,
                file: lutFile, contractOverride: contract)
        } else if lutMiss {
            try await film.enqueueMetalFilm(
                GPUMetalFilmIO(
                    source: graded, destination: filmOutput,
                    queue: gpu.queue, width: width, height: height), look: look)
        }
        try Task.checkCancellation()
        // LUT_GPU_DISPLAY_PASS: refuse featureless LUT output from detailed RAW input.
        var contentSamples: (any MTLBuffer)?
        if let contentGuard {
            if let encoded = try? contentGuard.encode(
                before: source, after: filmOutput,
                width: width, height: height, on: gpu.queue.makeCommandBuffer()!)
            {
                contentSamples = encoded
            }
        }
        guard let postCommand = gpu.queue.makeCommandBuffer() else {
            throw GPULiveError.unavailable("Post-film Metal command allocation failed")
        }
        var result: any MTLBuffer = filmOutput
        var keepAlive: [any MTLBuffer] = [source, graded, filmOutput]
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
                source: result, destination: texture,
                width: width, height: height, geometry: geometry, command: postCommand)
        } else {
            try gpu.encodeBufferToTexture(result, destination: texture, on: postCommand)
        }
        // Keep all upstream buffers alive until the final GPU completion fence.
        // An async continuation, never waitUntilCompleted() on the main thread.
        let retained = GPUBufferLifetime(keepAlive)
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
        if let contentSamples = contentSamples {
            try MetalFrameContentGuard.verify(contentSamples)
        }
        recycleScratch(borrowedScratch, gpu: gpu)  // The async Metal completion fence has returned.
        try Task.checkCancellation()
        let elapsed = (ProcessInfo.processInfo.systemUptime - renderedStart) * 1000.0
        let label: String
        if usedSpectralLUT {
            label = "Cached spectral LUT \(resolution ?? 33)³ · \(Int(elapsed.rounded())) ms"
        } else if let resolution {
            let blocked = await film.colorLUTBlockingReason(look: look)
            label =
                blocked.map { "Native Metal · LUT blocked (\($0))" }
                ?? "Native Metal · LUT \(resolution)³ not yet cached"
        } else {
            label = "Native spectral Metal · \(Int(elapsed.rounded())) ms"
        }
        return GPULiveFrame(
            texture: texture,
            colorSpace: OutputColorProfile.forLook(look).cgColorSpace,
            rendererLabel: label,
            onRelease: { [gpu] in gpu.returnOutputTexture(texture) })
    }
}
