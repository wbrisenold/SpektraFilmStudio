// Texture-based film effects sourced from Chromogen.app (MPL-adjacent asset pack):
// light-leak masks (flames, streaks, side ingress, pooled) and scanned paper surfaces.
// SPDX-License-Identifier: MPL-2.0. See Resources/Redlamp-MPL-2.0.txt.
import AppKit
import Foundation
import Metal
import MetalKit

/// A loadable texture-based film effect asset.
struct TextureEffectAsset: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let fileName: String
}

/// A bundled film border with its photo-window geometry, so the photo can be fitted
/// into the frame's window instead of stretching the frame over the photo.
struct FilmFrameAsset: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let fileName: String
    /// Photo window rect in normalized canvas coordinates (0...1, origin top-left).
    let windowX: CGFloat
    let windowY: CGFloat
    let windowWidth: CGFloat
    let windowHeight: CGFloat
    /// Aspect (width / height) of the window the frame was authored for.
    let windowAspect: CGFloat
    let canvasWidth: Int
    let canvasHeight: Int
}

/// Static catalog of the bundled texture effects.
enum TextureEffectCatalog {
    /// Scanned paper surfaces. Index 0..<count maps to `availablePaperTextures`.
    static let papers: [TextureEffectAsset] = [
        TextureEffectAsset(id: "paper-1", displayName: "Paper 1", fileName: "paper-1.jpg"),
        TextureEffectAsset(id: "paper-2", displayName: "Paper 2", fileName: "paper-2.jpg"),
        TextureEffectAsset(id: "paper-3", displayName: "Paper 3", fileName: "paper-3.jpg"),
        TextureEffectAsset(id: "paper-4", displayName: "Paper 4", fileName: "paper-4.jpg"),
        TextureEffectAsset(id: "paper-5", displayName: "Paper 5", fileName: "paper-5.jpg"),
    ]

    /// Instant-film borders drawn over the photo, loaded from the bundled manifest.
    static let frames: [FilmFrameAsset] = loadFrames()

    /// Frames whose photo window matches the requested aspect within `tolerance`
    /// (relative). Frames without a measured window are always offered, since
    /// they span the whole canvas and the border is drawn over the photo.
    static func frames(forAspect aspect: CGFloat, tolerance: CGFloat = 0.18) -> [FilmFrameAsset] {
        guard aspect > 0 else { return frames }
        return frames.filter { frame in
            frame.windowAspect <= 0
                || abs(frame.windowAspect - aspect) <= tolerance * max(aspect, frame.windowAspect)
        }
    }

    private static func loadFrames() -> [FilmFrameAsset] {
        guard let url = Bundle.main.url(
            forResource: "FilmFrames", withExtension: "json", subdirectory: "FilmFrames"),
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(FilmFrameManifest.self, from: data)
        else { return [] }
        return decoded.frames.compactMap { entry in
            guard let aspect = entry.windowAspect else { return nil }
            return FilmFrameAsset(
                id: entry.id,
                displayName: entry.displayName,
                fileName: entry.fileName,
                windowX: entry.windowX ?? 0,
                windowY: entry.windowY ?? 0,
                windowWidth: entry.windowWidth ?? 1,
                windowHeight: entry.windowHeight ?? 1,
                windowAspect: aspect,
                canvasWidth: entry.canvasWidth ?? 1,
                canvasHeight: entry.canvasHeight ?? 1
            )
        }
    }
}

private struct FilmFrameManifest: Decodable {
    let frames: [FilmFrameEntry]
}

private struct FilmFrameEntry: Decodable {
    let id: String
    let displayName: String
    let fileName: String
    let windowX: CGFloat?
    let windowY: CGFloat?
    let windowWidth: CGFloat?
    let windowHeight: CGFloat?
    let windowAspect: CGFloat?
    let canvasWidth: Int?
    let canvasHeight: Int?
}

/// Applies Chromogen-sourced film borders and paper surfaces on the GPU.
/// Loads the bundled border overlays and paper scans from Resources/FilmFrames and
/// Resources/PaperTextures. Procedural light leaks stay in RedlampFilmEffectsEngine.
final class TextureFilmEffectsEngine: @unchecked Sendable {
    static let shared = TextureFilmEffectsEngine()
    private let device: (any MTLDevice)?
    private var queue: MTLCommandQueue?
    private var paperPipeline: MTLComputePipelineState?
    private var framePipeline: MTLComputePipelineState?
    private let loaderQueue = DispatchQueue(label: "org.spektrafilm.texture-effects.loader")

    // Loaded lazily per asset; guarded by the loader queue and safe because
    // MTLTexture instances are only handed to committed command buffers.
    private var textures: [String: any MTLTexture] = [:]
    private var reportedMissing = Set<String>()

    private convenience init() {
        self.init(device: StudioGPUDevice.shared)
    }

    init(device: (any MTLDevice)?) {
        self.device = device
        guard let device else { return }
        queue = device.makeCommandQueue()
        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            if let paper = library.makeFunction(name: "paperSurface") {
                paperPipeline = try device.makeComputePipelineState(function: paper)
            }
            if let frame = library.makeFunction(name: "filmBorder") {
                framePipeline = try device.makeComputePipelineState(function: frame)
            }
        } catch {
            GPUProcessingFailure.report("Texture effects shader: \(error.localizedDescription)")
        }
    }

    /// Loads a texture from the bundle, or nil when unavailable.
    /// Metal-native decode: MTKTextureLoader straight from the file URL, no NSImage.
    private func texture(named fileName: String, subdirectory: String) -> (any MTLTexture)? {
        let key = "\(subdirectory)/\(fileName)"
        if let cached = textures[key] { return cached }
        guard let url = Bundle.main.url(
            forResource: fileName, withExtension: nil, subdirectory: subdirectory)
        else {
            loaderQueue.sync {
                guard !reportedMissing.contains(key) else { return }
                reportedMissing.insert(key)
                GPUProcessingFailure.report("Texture effect \(key) could not be loaded")
            }
            return nil
        }
        let loader = MTKTextureLoader(device: requireDevice()!)
        let texture: (any MTLTexture)?
        do {
            texture = try loader.newTexture(URL: url, options: [.SRGB: false])
        } catch {
            GPUProcessingFailure.report("Texture effect \(key) failed to load: \(error.localizedDescription)")
            texture = nil
        }
        if let texture {
            loaderQueue.sync { textures[key] = texture }
        }
        return texture
    }

    private func paperTexture(named fileName: String) -> (any MTLTexture)? {
        texture(named: fileName, subdirectory: "PaperTextures")
    }

    private func frameTexture(named fileName: String) -> (any MTLTexture)? {
        texture(named: fileName, subdirectory: "FilmFrames")
    }

    private func requireDevice() -> (any MTLDevice)? {
        #if os(macOS)
        return device ?? MTLCreateSystemDefaultDevice()
        #else
        return device
        #endif
    }

    /// True when the look requests a texture-based effect this engine can apply.
    static func isActive(_ s: FilmEffectsSettings) -> Bool {
        (s.paperTextureIndex >= 0 && s.paperTextureAmount > 0) || s.frameTextureIndex >= 0
    }

    // MARK: - CPU path

    func apply(_ input: PixelBufferF32, look: RenderLook) -> PixelBufferF32 {
        guard let s = look.filmEffects, Self.isActive(s),
            SkinToneReference.outputRoleIndex(look) == 0
        else { return input }
        let space = SkinToneReference.outputSpaceIndex(look)
        guard [14, 15, 16, 17, 18, 22, 23, 24, 25].contains(space) else { return input }
        guard let device = requireDevice(), let queue, input.width > 0, input.height > 0,
            input.pixels.count == input.width * input.height * 4
        else { GPUProcessingFailure.report("Texture effects GPU unavailable"); return input }

        let bytes = input.pixels.count * 4
        guard let source = input.pixels.withUnsafeBytes({
            device.makeBuffer(bytes: $0.baseAddress!, length: bytes, options: .storageModeShared)
        }), let destination = device.makeBuffer(length: bytes, options: .storageModeShared),
            let command = queue.makeCommandBuffer()
        else { GPUProcessingFailure.report("Texture effects GPU allocation failed"); return input }

        var encoded = false
        // Each stage reads the previous stage's buffer; `lastOutput` starts at the
        // source (a copy of the input) so a single-stage run is never uninitialized.
        var lastOutput: (any MTLBuffer)? = source

        if s.paperTextureIndex >= 0, s.paperTextureIndex < TextureEffectCatalog.papers.count,
            s.paperTextureAmount > 0, let paperPipeline,
            let texture = paperTexture(named: TextureEffectCatalog.papers[s.paperTextureIndex].fileName),
            let encoder = command.makeComputeCommandEncoder()
        {
            let scratch = device.makeBuffer(length: bytes, options: .storageModeShared)
            guard let scratch else {
                encoder.endEncoding()
                GPUProcessingFailure.report("Texture effects paper buffer allocation failed")
                return input
            }
            var p: [Float] = [
                Float(input.width), Float(input.height),
                Float(s.paperTextureAmount / 100),
            ]
            encoder.setComputePipelineState(paperPipeline)
            encoder.setBuffer(source, offset: 0, index: 0)
            encoder.setBuffer(scratch, offset: 0, index: 1)
            encoder.setTexture(texture, index: 0)
            encoder.setBytes(&p, length: p.count * MemoryLayout<Float>.stride, index: 2)
            encoder.dispatchThreads(
                MTLSize(width: input.width, height: input.height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.endEncoding()
            lastOutput = scratch
            encoded = true
        }

        // The film border is always last: its transparent window shows everything beneath.
        if s.frameTextureIndex >= 0, s.frameTextureIndex < TextureEffectCatalog.frames.count,
            let framePipeline,
            let texture = frameTexture(named: TextureEffectCatalog.frames[s.frameTextureIndex].fileName),
            let encoder = command.makeComputeCommandEncoder()
        {
            var p: [Float] = [Float(input.width), Float(input.height)]
            encoder.setComputePipelineState(framePipeline)
            encoder.setBuffer(lastOutput, offset: 0, index: 0)
            encoder.setBuffer(destination, offset: 0, index: 1)
            encoder.setTexture(texture, index: 0)
            encoder.setBytes(&p, length: p.count * MemoryLayout<Float>.stride, index: 2)
            encoder.dispatchThreads(
                MTLSize(width: input.width, height: input.height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.endEncoding()
            lastOutput = destination
            encoded = true
        }

        guard encoded else {
            GPUProcessingFailure.report("Texture effects did not run; shader or texture unavailable")
            return input
        }
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            GPUProcessingFailure.report("Texture effects GPU execution failed")
            return input
        }
        // `lastOutput` is whichever stage ran last; with no border it is the paper
        // scratch, and reading an unwritten buffer would return garbage.
        guard let result = lastOutput else { return input }
        return PixelBufferF32(
            width: input.width, height: input.height,
            pixels: Array(
                UnsafeBufferPointer(
                    start: result.contents().assumingMemoryBound(to: Float.self),
                    count: input.pixels.count)))
    }

    // MARK: - GPU path

    func encode(
        source: any MTLBuffer, destination: any MTLBuffer,
        command: any MTLCommandBuffer, width: Int, height: Int,
        look: RenderLook
    ) throws {
        guard let s = look.filmEffects, Self.isActive(s) || s.frameTextureIndex >= 0 else {
            throw GPULiveError.unavailable("inactive texture effects should skip the GPU pass")
        }
        let space = SkinToneReference.outputSpaceIndex(look)
        guard SkinToneReference.outputRoleIndex(look) == 0,
            [14, 15, 16, 17, 18, 22, 23, 24, 25].contains(space),
            let device, command.device.registryID == device.registryID
        else {
            throw GPULiveError.unavailable("texture effects require SDR display signal")
        }
        var lastOutput: (any MTLBuffer)? = source
        if s.paperTextureIndex >= 0, s.paperTextureIndex < TextureEffectCatalog.papers.count,
            s.paperTextureAmount > 0, let paperPipeline,
            let texture = paperTexture(named: TextureEffectCatalog.papers[s.paperTextureIndex].fileName),
            let encoder = command.makeComputeCommandEncoder()
        {
            // Paper needs its own output before the border reads it.
            let bytes = width * height * 16
            let scratch = device.makeBuffer(length: bytes, options: .storageModePrivate)
            guard let scratch else {
                encoder.endEncoding()
                throw GPULiveError.unavailable("texture effects paper buffer allocation failed")
            }
            var p: [Float] = [
                Float(width), Float(height),
                Float(s.paperTextureAmount / 100),
            ]
            encoder.setComputePipelineState(paperPipeline)
            encoder.setBuffer(source, offset: 0, index: 0)
            encoder.setBuffer(scratch, offset: 0, index: 1)
            encoder.setTexture(texture, index: 0)
            encoder.setBytes(&p, length: p.count * MemoryLayout<Float>.stride, index: 2)
            encoder.dispatchThreads(
                MTLSize(width: width, height: height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.endEncoding()
            lastOutput = scratch
        }
        if s.frameTextureIndex >= 0, s.frameTextureIndex < TextureEffectCatalog.frames.count,
            let framePipeline,
            let texture = frameTexture(named: TextureEffectCatalog.frames[s.frameTextureIndex].fileName),
            let encoder = command.makeComputeCommandEncoder()
        {
            var p: [Float] = [Float(width), Float(height)]
            encoder.setComputePipelineState(framePipeline)
            encoder.setBuffer(lastOutput, offset: 0, index: 0)
            encoder.setBuffer(destination, offset: 0, index: 1)
            encoder.setTexture(texture, index: 0)
            encoder.setBytes(&p, length: p.count * MemoryLayout<Float>.stride, index: 2)
            encoder.dispatchThreads(
                MTLSize(width: width, height: height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.endEncoding()
        }
    }

    private static let shader = #"""
            #include <metal_stdlib>
            using namespace metal;

            constexpr sampler paperSampler(coord::normalized, address::repeat, filter::linear);
            constexpr sampler frameSampler(coord::normalized, address::clamp_to_edge, filter::linear);

            // Blending a scanned paper surface under the photo, sampled in frame coordinates
            // with the scan's own texture, then mixed at `amount`.
            kernel void paperSurface(
                device const float4 *source [[buffer(0)]],
                device float4 *destination [[buffer(1)]],
                texture2d<float, access::sample> paper [[texture(0)]],
                constant float *p [[buffer(2)]],
                uint2 xy [[thread_position_in_grid]])
            {
                uint width = uint(p[0]);
                uint height = uint(p[1]);
                if (xy.x >= width || xy.y >= height) return;
                float amount = p[2];
                float4 c = source[xy.y * width + xy.x];
                float2 uv = float2(xy) / float2(width, height);
                // Tiled at 2x so the scan's texture reads as a surface, not one stretched blotch.
                float2 tiled = fract(uv * 2.0);
                float3 surface = paper.sample(paperSampler, tiled).rgb;
                float3 mixed = mix(float3(c.rgb), surface * float3(c.rgb), amount);
                destination[xy.y * width + xy.x] = float4(mixed, c.a);
            }

            // A film border drawn over the photo. The border asset is RGBA: the window is
            // transparent so the photo shows through, and the border paper is
            // alpha-composited over it.
            kernel void filmBorder(
                device const float4 *source [[buffer(0)]],
                device float4 *destination [[buffer(1)]],
                texture2d<float, access::sample> border [[texture(0)]],
                constant float *p [[buffer(2)]],
                uint2 xy [[thread_position_in_grid]])
            {
                uint width = uint(p[0]);
                uint height = uint(p[1]);
                if (xy.x >= width || xy.y >= height) return;
                float2 uv = float2(xy) / float2(width, height);
                float4 b = border.sample(frameSampler, uv);
                float4 c = source[xy.y * width + xy.x];
                float3 over = b.rgb * b.a + float3(c.rgb) * (1.0 - b.a);
                destination[xy.y * width + xy.x] = float4(over, 1.0);
            }
            """#
}
