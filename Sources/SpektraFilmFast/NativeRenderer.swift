import Foundation
import Darwin
import CoreGraphics
import CSpektraBridge


struct FloatImagePayload: Sendable {
    let width: Int
    let height: Int
    let data: Data

    var expectedByteCount: Int {
        width * height * 4 * MemoryLayout<Float>.size
    }

    func makePixelBuffer() -> PixelBufferF32? {
        guard width > 0, height > 0, data.count == expectedByteCount else { return nil }
        var pixels = [Float](repeating: 0, count: width * height * 4)
        let copied = pixels.withUnsafeMutableBytes { destination in
            data.copyBytes(to: destination)
        }
        guard copied == data.count else { return nil }
        return PixelBufferF32(width: width, height: height, pixels: pixels)
    }

    func makeCGImage(colorSpace: CGColorSpace) -> CGImage? {
        guard width > 0, height > 0, data.count == expectedByteCount else { return nil }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let bitmap = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.last.rawValue |
            CGBitmapInfo.floatComponents.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue
        )
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 32,
            bitsPerPixel: 128,
            bytesPerRow: width * 4 * MemoryLayout<Float>.size,
            space: colorSpace,
            bitmapInfo: bitmap,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

struct PixelBufferF32: Sendable {
    var width: Int
    var height: Int
    var pixels: [Float]

    init(width: Int, height: Int, pixels: [Float]? = nil) {
        self.width = width
        self.height = height
        self.pixels = pixels ?? Array(repeating: 0, count: width * height * 4)
    }

    func displayCGImage(colorSpace: CGColorSpace? = nil) -> CGImage? {
        makeCGImage8(colorSpace: colorSpace ?? (CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()))
    }


    func makeFloatImagePayload() -> FloatImagePayload? {
        guard width > 0, height > 0, pixels.count == width * height * 4 else { return nil }
        return FloatImagePayload(
            width: width,
            height: height,
            data: pixels.withUnsafeBytes { Data($0) }
        )
    }

    func makeCGImageFloat(colorSpace: CGColorSpace) -> CGImage? {
        makeFloatImagePayload()?.makeCGImage(colorSpace: colorSpace)
    }

    func makeCGImage8(colorSpace: CGColorSpace) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let p = i * 4
            bytes[p] = toUInt8(pixels[p])
            bytes[p + 1] = toUInt8(pixels[p + 1])
            bytes[p + 2] = toUInt8(pixels[p + 2])
            bytes[p + 3] = toUInt8(pixels[p + 3])
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    func makeCGImage16(colorSpace: CGColorSpace) -> CGImage? {
        var words = [UInt16](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let p = i * 4
            words[p] = toUInt16(pixels[p])
            words[p + 1] = toUInt16(pixels[p + 1])
            words[p + 2] = toUInt16(pixels[p + 2])
            words[p + 3] = toUInt16(pixels[p + 3])
        }
        let data = words.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let bitmap = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 16,
            bitsPerPixel: 64,
            bytesPerRow: width * 8,
            space: colorSpace,
            bitmapInfo: bitmap,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private func toUInt8(_ value: Float) -> UInt8 {
        UInt8(clamping: Int((max(0, min(1, value)) * 255).rounded()))
    }

    private func toUInt16(_ value: Float) -> UInt16 {
        UInt16(clamping: Int((max(0, min(1, value)) * 65535).rounded()))
    }
}

enum RendererError: LocalizedError {
    case unavailable(String)
    case renderFailed(String)
    var errorDescription: String? {
        switch self {
        case .unavailable(let message): "Metal renderer unavailable: \(message)"
        case .renderFailed(let message): "Render failed: \(message)"
        }
    }
}

actor NativeRenderer {
    enum Profile: Sendable {
        case exact
    }

    // Immutable native handle. This is intentionally nonisolated for safe destruction
    // under Swift 6; it is never mutated after init. See AI_PITFALLS.md.
    nonisolated(unsafe) private let handle: SpektraRendererRef

    init(profile: Profile = .exact) throws {
        Self.configurePinnedCorePerformanceDefaults(profile: profile)
        guard let renderer = SpektraRendererCreate() else { throw RendererError.unavailable("Could not create renderer") }
        handle = renderer
        guard SpektraRendererIsAvailable(renderer) != 0 else {
            let message = SpektraRendererLastError(renderer).map(String.init(cString:)) ?? "Unknown Metal error"
            SpektraRendererDestroy(renderer)
            throw RendererError.unavailable(message)
        }
    }


    /// Configure the pinned native renderer for exact processing. Preview speed is handled by
    /// decode/render caching and by a transient pointer-rate proxy, not by a second approximate
    /// renderer configuration.
    private nonisolated static func configurePinnedCorePerformanceDefaults(profile: Profile) {
        func set(_ key: String, _ value: String) { setenv(key, value, 1) }

        set("SPEKTRAFILM_FINAL_CORE_MODE", "fused")
        set("SPEKTRAFILM_SCANNER_IMAGE_STORAGE", "texture")
        set("SPEKTRAFILM_GRAIN_BLUR_RECURRENCE", "1")
        set("SPEKTRAFILM_SPECTRAL_TRANSMITTANCE", "exp2")
        set("SPEKTRAFILM_DIR_TAIL_BACKEND", "fused")
        set("SPEKTRAFILM_BLUR_BACKEND", "custom")
        set("SPEKTRAFILM_BLUR_DOWNSAMPLE", "off")
        set("SPEKTRAFILM_INTERMEDIATE_PRECISION", "float")
        set("SPEKTRAFILM_DIFFUSION_CLUSTER_SIGMA", "off")
        set("SPEKTRAFILM_HALATION_GROUPED_TAIL", "0")
        set("SPEKTRAFILM_SCANNER_MPS", "0")
        set("SPEKTRAFILM_DENSITY_CURVE_LOOKUP", "binary")
    }

    deinit { SpektraRendererDestroy(handle) }

    func render(_ input: PixelBufferF32, look: RenderLook, time: Double = 0) throws -> (PixelBufferF32, RenderDiagnosticsView) {
        // A cancelled request that was waiting for the actor must not become another
        // expensive Metal render after it finally reaches the front of the queue.
        try Task.checkCancellation()

        var params = SpektraAppMakeDefaultRenderParams()
        apply(look: look, to: &params)
        params.inputColorSpace = SpektraAppLinearRec2020ColorSpace()

        var outputPixels = [Float](repeating: 0, count: input.width * input.height * 4)
        // The pinned C bridge declares the source image view const and the native renderer
        // only reads it. Do not force Swift Array copy-on-write just to obtain a mutable
        // pointer type for the C struct; this removes a full-frame float copy from every slider.
        let ok: Int32 = input.pixels.withUnsafeBytes { srcBytes in
            guard let srcBase = srcBytes.baseAddress else { return 0 }
            return outputPixels.withUnsafeMutableBytes { dstBytes in
                guard let dstBase = dstBytes.baseAddress else { return 0 }
                var source = SpektraImageBuffer(
                    data: UnsafeMutableRawPointer(mutating: srcBase),
                    width: Int32(input.width), height: Int32(input.height),
                    rowBytes: Int32(input.width * 4 * MemoryLayout<Float>.size),
                    components: 4, bytesPerComponent: Int32(MemoryLayout<Float>.size)
                )
                var destination = SpektraImageBuffer(
                    data: dstBase,
                    width: Int32(input.width), height: Int32(input.height),
                    rowBytes: Int32(input.width * 4 * MemoryLayout<Float>.size),
                    components: 4, bytesPerComponent: Int32(MemoryLayout<Float>.size)
                )
                return SpektraRendererRender(handle, &source, &destination, &params, time)
            }
        }
        guard ok != 0 else {
            let message = SpektraRendererLastError(handle).map(String.init(cString:)) ?? "Unknown native renderer error"
            throw RendererError.renderFailed(message)
        }
        try Task.checkCancellation()

        let d = SpektraRendererLastDiagnostics(handle)
        return (
            PixelBufferF32(width: input.width, height: input.height, pixels: outputPixels),
            RenderDiagnosticsView(
                cpuSetupMs: d.cpuSetupMs,
                sourceCopyMs: d.sourceCopyMs,
                commandBufferMs: d.commandBufferMs,
                outputCopyMs: d.outputCopyMs,
                passCount: d.passCount,
                uploadBytes: d.uploadBytes
            )
        )
    }

    private func apply(look: RenderLook, to params: inout SpektraAppRenderParams) {
        for (name, value) in look.values {
            if name.hasPrefix("raw") { continue }
            name.withCString { cName in
                switch value {
                case .int(let v): _ = SpektraAppSetIntParam(&params, cName, v)
                case .bool(let v): _ = SpektraAppSetBoolParam(&params, cName, v ? 1 : 0)
                case .scalar(let v): _ = SpektraAppSetDoubleParam(&params, cName, v)
                case .vector2(let x, let y): _ = SpektraAppSetDouble3Param(&params, cName, x, y, 0)
                case .vector3(let x, let y, let z): _ = SpektraAppSetDouble3Param(&params, cName, x, y, z)
                }
            }
        }
    }
}
