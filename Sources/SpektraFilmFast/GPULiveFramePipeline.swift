import Foundation
import CoreGraphics
import CoreImage
import Metal

// SpektraFilmStudio GPL-3.0 — production-facing experimental live GPU pipeline.
// No full-frame CPU RGBA readback between RAW development, host grade, spectral
// film simulation, lens character, film effects, and preview publication.
// Advanced local masks / geometric transforms / Auto Contrast remain on the
// original exact renderer until identical GPU equivalents pass color parity.

enum GPULiveError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let reason): return "GPU live: \(reason)" }
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
    init(texture: any MTLTexture, colorSpace: CGColorSpace, rendererLabel: String) {
        self.texture = texture
        self.colorSpace = colorSpace
        self.rendererLabel = rendererLabel
    }
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

    init(device: any MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw GPULiveError.unavailable("Metal queue creation failed") }
        self.queue = queue
        self.context = CIContext(mtlDevice: device, options: [
            .cacheIntermediates: true, .useSoftwareRenderer: false
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
              let b2t = library.makeFunction(name: "spektraBufferToTexture") else {
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

    func encodeTextureToBuffer(_ source: any MTLTexture, destination: any MTLBuffer,
                               on command: any MTLCommandBuffer) throws {
        guard let encoder = command.makeComputeCommandEncoder() else {
            throw GPULiveError.unavailable("RAW texture converter unavailable")
        }
        encoder.setComputePipelineState(textureToBuffer)
        encoder.setTexture(source, index: 0)
        encoder.setBuffer(destination, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: source.width, height: source.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
    }

    func encodeBufferToTexture(_ source: any MTLBuffer, destination: any MTLTexture,
                               on command: any MTLCommandBuffer) throws {
        guard let encoder = command.makeComputeCommandEncoder() else {
            throw GPULiveError.unavailable("Display texture converter unavailable")
        }
        encoder.setComputePipelineState(bufferToTexture)
        encoder.setBuffer(source, offset: 0, index: 0)
        encoder.setTexture(destination, index: 0)
        encoder.dispatchThreads(MTLSize(width: destination.width, height: destination.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
    }

    func makeOutputTexture(width: Int, height: Int) throws -> any MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
            width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        guard let texture = device.makeTexture(descriptor: d) else {
            throw GPULiveError.unavailable("Live display texture allocation failed")
        }
        return texture
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
        if let geometry = look.geometry, geometry != GeometrySettings() { return false }
        if look.tone?.autoContrast == true || look.filmTone?.autoContrast == true { return false }
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

    func reset() { rawCache.removeAll() }

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
              Self.supports(look) else { return nil }
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
              Self.supports(look), let spectralLUT else { return nil }
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
              count <= Int.max / 4 else { throw GPULiveError.unavailable("Invalid settled LUT frame") }
        let bytes = count * MemoryLayout<Float>.stride
        guard let source = input.pixels.withUnsafeBytes({ data in
                  gpu.device.makeBuffer(bytes: data.baseAddress!, length: bytes, options: .storageModeShared)
              }),
              let destination = gpu.device.makeBuffer(length: bytes, options: .storageModeShared) else {
            throw GPULiveError.unavailable("Settled LUT Metal buffers unavailable")
        }
        let used = try await spectralLUT.encodeIfEligible(film: film, look: look,
            source: source, destination: destination, width: input.width, height: input.height)
        guard used else { return nil }
        guard let fence = gpu.queue.makeCommandBuffer() else {
            throw GPULiveError.unavailable("Settled LUT fence unavailable")
        }
        let retained = GPUBufferLifetime([source, destination])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            fence.addCompletedHandler { completed in
                withExtendedLifetime(retained) {
                    if completed.status == .completed { continuation.resume() }
                    else { continuation.resume(throwing: GPULiveError.unavailable(
                        completed.error?.localizedDescription ?? "Settled LUT GPU failure")) }
                }
            }
            fence.commit() // same FIFO Metal queue; previous LUT kernel completed
        }
        try Task.checkCancellation()
        var pixels = [Float](repeating: 0, count: count)
        pixels.withUnsafeMutableBytes { dest in
            dest.baseAddress!.copyMemory(from: destination.contents(), byteCount: bytes)
        }
        return PixelBufferF32(width: input.width, height: input.height, pixels: pixels)
    }

    func render(url: URL, look: RenderLook, bypassImportTransform: Bool,
                decoder: ImageDecoder, longEdge: Int = 1080) async throws -> GPULiveFrame {
        // The exact code path remains authoritative when an unsupported stage
        // is active; DO NOT ignore layers or geometry to fake a fast preview.
        if look.localGrades?.contains(where: { $0.enabled && $0.opacity > 0 }) == true {
            throw GPULiveError.unavailable("local masks require the exact renderer")
        }
        if look.geometry != nil && look.geometry != GeometrySettings() {
            throw GPULiveError.unavailable("crop/perspective require the exact renderer")
        }
        if look.tone?.autoContrast == true || look.filmTone?.autoContrast == true {
            throw GPULiveError.unavailable("Auto Contrast requires full-frame analysis")
        }
        if film == nil { film = try NativeRenderer(profile: .exact) }
        guard let film else { throw GPULiveError.unavailable("Native film engine unavailable") }
        if gpu == nil {
            let nativeDevice = try await film.preferredMetalDevice()
            gpu = try GPULiveDevice(device: nativeDevice.device)
        }
        guard let gpu else { throw GPULiveError.unavailable("Metal device unavailable") }
        let key = DecodeKey(path: url.path, longEdge: longEdge, raw: look.raw,
                            bypassImportTransform: bypassImportTransform)
        let developed: MetalDevelopedRAW
        if let index = rawCache.firstIndex(where: { $0.key == key }) {
            let hit = rawCache.remove(at: index)
            rawCache.insert(hit, at: 0)
            developed = hit.frame
        } else {
            developed = try await decoder.decodeMetal(url: url, longEdge: longEdge, raw: look.raw,
                bypassImportTransform: bypassImportTransform, gpu: gpu)
            rawCache.insert((key: key, frame: developed), at: 0)
            if rawCache.count > rawCacheCapacity { rawCache.removeLast() }
        }
        try Task.checkCancellation()
        let width = developed.width, height = developed.height
        let source = try gpu.allocateFloatBuffer(width: width, height: height)
        let graded = try gpu.allocateFloatBuffer(width: width, height: height)
        let filmOutput = try gpu.allocateFloatBuffer(width: width, height: height)
        guard let preCommand = gpu.queue.makeCommandBuffer() else {
            throw GPULiveError.unavailable("RAW conversion command allocation failed")
        }
        try gpu.encodeTextureToBuffer(developed.texture, destination: source, on: preCommand)
        try gpu.host.encode(source: source, destination: graded, on: preCommand,
            width: width, height: height,
            tone: look.tone, density: look.colorDensity, film: look.filmTone)
        preCommand.commit()
        try Task.checkCancellation()
        // Only ALREADY GPU-resident LUTs may run during slider movement.
        // A cold/missing LUT uses native Metal immediately, never bakes inline.
        var usedSpectralLUT = false
        var usedImportedLUT = false
        var importedOutput: StudioImportedLUT.OutputSpace?
        let resolution = StudioSpectralLUT.selectedResolution()
        let renderedStart = ProcessInfo.processInfo.systemUptime
        if StudioImportedLUT.isSelected {
            guard let file = StudioImportedLUT.selectedURL() else {
                throw StudioImportedLUT.Failure.invalid("Choose a LUT from the linked folder in Settings.")
            }
            if importedLUT == nil { importedLUT = try StudioImportedLUTMetal(gpu: gpu) }
            guard let importedLUT,
                  let command = gpu.queue.makeCommandBuffer() else {
                throw StudioImportedLUT.Failure.invalid("Metal imported-LUT stage unavailable.")
            }
            importedOutput = try importedLUT.encode(source: graded, destination: filmOutput,
                                    width: width, height: height, on: command, file: file)
            command.commit()
            usedImportedLUT = true
        }
        if !usedImportedLUT && resolution != nil, let spectralLUT {
            do {
                usedSpectralLUT = try await spectralLUT.encodeIfEligible(
                    film: film, look: look, source: graded, destination: filmOutput,
                    width: width, height: height)
            } catch is CancellationError { throw CancellationError() }
            catch { usedSpectralLUT = false }
        }
        if !usedImportedLUT && !usedSpectralLUT {
            try await film.enqueueMetalFilm(GPUMetalFilmIO(source: graded, destination: filmOutput,
                 queue: gpu.queue, width: width, height: height), look: look)
        }
        try Task.checkCancellation()
        guard let postCommand = gpu.queue.makeCommandBuffer() else {
            throw GPULiveError.unavailable("Post-film Metal command allocation failed")
        }
        var result: any MTLBuffer = filmOutput
        var keepAlive: [any MTLBuffer] = [source, graded, filmOutput]
        if let lens = look.lensEffects, lens.enabled && !lens.isIdentity {
            let out = try gpu.allocateFloatBuffer(width: width, height: height)
            try gpu.lens.encode(source: result, destination: out, command: postCommand,
                                width: width, height: height, parameters: lens.resolvedWithCenter)
            result = out
            keepAlive.append(out)
        }
        if let fx = look.filmEffects, !fx.isIdentity {
            let out = try gpu.allocateFloatBuffer(width: width, height: height)
            try gpu.effects.encode(source: result, destination: out, command: postCommand,
                                   width: width, height: height, look: look)
            result = out
            keepAlive.append(out)
        }
        let texture = try gpu.makeOutputTexture(width: width, height: height)
        try gpu.encodeBufferToTexture(result, destination: texture, on: postCommand)
        // Keep all upstream buffers alive until the final GPU completion fence.
        // An async continuation, never waitUntilCompleted() on the main thread.
        let retained = GPUBufferLifetime(keepAlive)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            postCommand.addCompletedHandler { command in
                withExtendedLifetime(retained) {
                    if command.status == .completed { continuation.resume() }
                    else { continuation.resume(throwing: GPULiveError.unavailable(
                        command.error?.localizedDescription ?? "Metal post processing failed")) }
                }
            }
            postCommand.commit()
        }
        try Task.checkCancellation()
        let elapsed = (ProcessInfo.processInfo.systemUptime - renderedStart) * 1000.0
        let label: String
        if usedImportedLUT {
            label = "Imported film LUT · " + StudioImportedLUT.selectedDisplayName
        } else if usedSpectralLUT {
            label = "Cached spectral LUT \(resolution ?? 33)³ · \(Int(elapsed.rounded())) ms"
        } else if let resolution {
            let blocked = await film.colorLUTBlockingReason(look: look)
            label = blocked.map { "Native Metal · LUT blocked (\($0))" }
                ?? "Native Metal · LUT \(resolution)³ not yet cached"
        } else {
            label = "Native spectral Metal · \(Int(elapsed.rounded())) ms"
        }
        return GPULiveFrame(texture: texture, colorSpace: importedOutput?.cgColorSpace ?? OutputColorProfile.forLook(look).cgColorSpace,
                            rendererLabel: label)
    }
}
