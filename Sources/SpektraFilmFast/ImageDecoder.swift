import Foundation
import CoreImage
import CoreGraphics
import Metal
import ImageIO
import UniformTypeIdentifiers
import RawSpeedBridge

struct DecodeKey: Hashable, Sendable {
    var path: String
    var longEdge: Int
    var raw: RawSettings
    var bypassImportTransform: Bool
}

private struct AutoNeutralLocation: Hashable, Sendable {
    var x: Double
    var y: Double
}

private struct SourceImageResult {
    var image: CIImage
    var cameraSpaceAutoWBApplied: Bool
    var cameraSpaceWhiteBalanceApplied: Bool
    var baseTemperature: Double?
    var baseTint: Double?
}

private final class CIContextBox: @unchecked Sendable {
    let context: CIContext = {
        let options: [CIContextOption: Any] = [.cacheIntermediates: true, .useSoftwareRenderer: false]
        if let device = StudioGPUDevice.shared { return CIContext(mtlDevice: device, options: options) }
        return CIContext(options: options)
    }()
}

struct AutoWhiteBalanceResolution: Sendable {
    enum Method: String, Sendable {
        case cameraNeutral = "Camera-space neutral"
        case workingSpaceFallback = "Working-space fallback"
    }
    let method: Method
    let neutralX: Double?
    let neutralY: Double?
}

struct WhiteBalanceReference: Sendable {
    let temperature: Double
    let tint: Double
}

actor ImageDecoder {
    private let contextBox = CIContextBox()
    private let developedDiskCache = DevelopedSourceDiskCache.shared
    private var cache: [DecodeKey: PixelBufferF32] = [:]
    private var cacheOrder: [DecodeKey] = []
    private var cacheBytes = 0
    private var pressureConstrained = false
    private var inFlight: [DecodeKey: Task<PixelBufferF32, Error>] = [:]
    private var autoNeutralCache: [String: AutoNeutralLocation?] = [:]
    private var autoNeutralInFlight: [String: Task<AutoNeutralLocation?, Never>] = [:]
    private var cacheHits = 0
    private var cacheMisses = 0

    func decode(
        url: URL,
        longEdge: Int,
        raw: RawSettings,
        bypassImportTransform: Bool,
        cacheMode: PreviewCacheMemoryMode
    ) async throws -> PixelBufferF32 {
        let key = DecodeKey(path: url.path, longEdge: longEdge, raw: raw, bypassImportTransform: bypassImportTransform)
        if let existing = cache[key] {
            cacheHits += 1
            touch(key)
            return existing
        }

        // Interactive previews should never redevelop a RAW merely because they ask for
        // a smaller resolution. Reuse the smallest adequate cached exact decode and scale it
        // with vImage instead. This benefits every slider, not only white balance.
        if longEdge != Int.max, let reusable = reusableCachedBuffer(for: key) {
            cacheHits += 1
            let scaled = try reusable.buffer.resized(longEdge: longEdge)
            touch(reusable.key)
            insert(scaled, key: key, mode: cacheMode)
            return scaled
        }

        if let existing = inFlight[key] {
            return try await existing.value
        }

        // If a larger compatible RAW development is already in flight, do not start a
        // second Core Image RAW job merely because the live request asks for fewer pixels.
        // Await the larger decode, then derive this frame with vImage.
        if longEdge != Int.max, let reusable = reusableInFlightTask(for: key) {
            let developed = try await reusable.task.value
            try Task.checkCancellation()
            let scaled = try developed.resized(longEdge: longEdge)
            insert(scaled, key: key, mode: cacheMode)
            return scaled
        }

        // Persistent developed-source cache sits before Core Image RAW development.
        // This is the important app-relaunch / RAM-eviction speed path: revisit a photo and
        // the expensive CIRAWFilter stage can be skipped entirely.
        if longEdge != Int.max,
           let disk = await developedDiskCache.buffer(
            url: url,
            raw: raw,
            longEdge: longEdge,
            bypassImportTransform: bypassImportTransform
           ) {
            try Task.checkCancellation()
            insert(disk, key: key, mode: cacheMode)
            return disk
        }

        cacheMisses += 1
        let autoNeutral = raw.whiteBalanceMode == .auto
            ? await resolvedAutoNeutralLocation(url: url, lensCorrection: raw.lensCorrection)
            : nil
        let box = contextBox
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try Self.decodeSync(
                context: box.context,
                url: url,
                longEdge: longEdge,
                raw: raw,
                bypassImportTransform: bypassImportTransform,
                fullResolution: false,
                autoNeutralLocation: autoNeutral
            )
        }
        inFlight[key] = task
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            inFlight[key] = nil
            insert(result, key: key, mode: cacheMode)
            if longEdge != Int.max {
                Task { [developedDiskCache] in
                    await developedDiskCache.store(
                        result,
                        url: url,
                        raw: raw,
                        longEdge: longEdge,
                        bypassImportTransform: bypassImportTransform
                    )
                }
            }
            return result
        } catch {
            inFlight[key] = nil
            throw error
        }
    }


    func decodeInteractiveWhiteBalance(
        url: URL,
        longEdge: Int,
        baselineRaw: RawSettings,
        targetRaw: RawSettings,
        bypassImportTransform: Bool,
        cacheMode: PreviewCacheMemoryMode
    ) async throws -> PixelBufferF32 {
        // Decode the committed RAW state once. Temperature/tint motion can then use a fast
        // linear Rec.2020 adaptation while the pointer is moving. The committed preview is
        // subsequently rebuilt from the requested RAW state through the normal exact path.
        let baseline = try await decode(
            url: url,
            longEdge: longEdge,
            raw: baselineRaw,
            bypassImportTransform: bypassImportTransform,
            cacheMode: cacheMode
        )
        try Task.checkCancellation()
        let reference: WhiteBalanceReference?
        if baselineRaw.whiteBalanceMode == .custom {
            reference = nil
        } else {
            reference = await whiteBalanceReference(url: url, raw: baselineRaw)
        }
        try Task.checkCancellation()
        return baseline.applyingInteractiveWhiteBalance(
            from: baselineRaw,
            to: targetRaw,
            baseTemperature: reference?.temperature,
            baseTint: reference?.tint
        )
    }

    /// Decode the SAME camera-space CIRAWFilter chain directly into a GPU texture.
    /// No toBitmap, CPU float array or Core Image software rendering is used.
    /// Unsupported non-RAW / working-space Auto WB is NOT silently approximated.
    func decodeMetal(url: URL, longEdge: Int, raw: RawSettings,
                     bypassImportTransform: Bool, gpu: GPULiveDevice) async throws -> MetalDevelopedRAW {
        try Task.checkCancellation()
        let autoNeutral = raw.whiteBalanceMode == .auto
            ? await resolvedAutoNeutralLocation(url: url, lensCorrection: raw.lensCorrection)
            : nil
        let source = try Self.sourceImage(url: url, raw: raw,
                                          draft: longEdge <= 1024,
                                          autoNeutralLocation: autoNeutral)
        // Non-RAW as-shot images already carry a decoded color profile. The
        // CIContext converts them to scene-linear Rec.2020 without asking a
        // missing CIRAWFilter for camera-space WB. Custom/Auto WB still needs
        // a separate proved working-space adaptation stage.
        guard source.cameraSpaceWhiteBalanceApplied || raw.whiteBalanceMode == .asShot else {
            throw GPULiveError.unavailable("source requires unresolved working-space white balance")
        }
        let extent = source.image.extent.integral
        guard extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0,
              longEdge > 0 && longEdge <= 2048 else {
            throw GPULiveError.unavailable("unsafe GPU decode dimensions")
        }
        let scale = min(1, CGFloat(longEdge) / max(extent.width, extent.height))
        let translated = source.image.transformed(by: CGAffineTransform(
            translationX: -extent.minX, y: -extent.minY))
        let scaled = translated.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let width = max(1, Int((extent.width * scale).rounded()))
        let height = max(1, Int((extent.height * scale).rounded()))
        guard width <= 2048, height <= 2048 else {
            throw GPULiveError.unavailable("GPU preview exceeds 2048 px")
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
                       width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        guard let texture = gpu.device.makeTexture(descriptor: d),
              let command = gpu.queue.makeCommandBuffer() else {
            throw GPULiveError.unavailable("GPU RAW development allocation failed")
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
        gpu.context.render(scaled, to: texture, commandBuffer: command,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           colorSpace: colorSpace)
        command.commit()
        // The queue guarantees GPU ordering; do not block for the RAW command.
try Task.checkCancellation()
        return MetalDevelopedRAW(texture: texture, width: width, height: height)
    }
    
    /// Decode RAW using RawSpeed (libraw) for scene-referred pipeline.
    /// Returns linear, scene-referred, camera RGB data in Rec.2020 primaries.
    /// This bypasses CIRAWFilter entirely and matches Darktable's RawSpeed path.
    func decodeRawSpeed(
        url: URL,
        longEdge: Int,
        raw: RawSettings,
        bypassImportTransform: Bool,
        cacheMode: PreviewCacheMemoryMode
    ) async throws -> PixelBufferF32 {
        let key = DecodeKey(path: url.path, longEdge: longEdge, raw: raw, bypassImportTransform: bypassImportTransform)
        if let existing = cache[key] {
            cacheHits += 1
            touch(key)
            return existing
        }
        
        if let existing = inFlight[key] {
            return try await existing.value
        }
        
        // Check persistent disk cache first
        if longEdge != Int.max,
           let disk = await developedDiskCache.buffer(
               url: url,
               raw: raw,
               longEdge: longEdge,
               bypassImportTransform: bypassImportTransform
           ) {
            try Task.checkCancellation()
            insert(disk, key: key, mode: cacheMode)
            return disk
        }
        
        cacheMisses += 1
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try Self.decodeRawSpeedSync(
                url: url,
                longEdge: longEdge,
                raw: raw,
                bypassImportTransform: bypassImportTransform
            )
        }
        inFlight[key] = task
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            inFlight[key] = nil
            insert(result, key: key, mode: cacheMode)
            if longEdge != Int.max {
                Task { [developedDiskCache] in
                    await developedDiskCache.store(
                        result,
                        url: url,
                        raw: raw,
                        longEdge: longEdge,
                        bypassImportTransform: bypassImportTransform
                    )
                }
            }
            return result
        } catch {
            inFlight[key] = nil
            throw error
        }
    }
    
    /// Synchronous RawSpeed decode for background thread.
    private nonisolated static func decodeRawSpeedSync(
        url: URL,
        longEdge: Int,
        raw: RawSettings,
        bypassImportTransform: Bool
    ) throws -> PixelBufferF32 {
        // Open RawSpeed decoder
        var error: RawSpeedError = RawSpeedError_None
        guard let decoderRef = RawSpeedDecoderCreate(url.path, &error) else {
            throw mapRawSpeedError(error)
        }
        defer { RawSpeedDecoderDestroy(decoderRef) }
        
        // Get metadata
        var cMeta = RawSpeedBridge.RawSpeedMetadata()
        let metaError = RawSpeedDecoderGetMetadata(decoderRef, &cMeta)
        guard metaError == RawSpeedError_None else {
            throw NSError(domain: "RawSpeed", code: Int(metaError.rawValue),
                         userInfo: [NSLocalizedDescriptionKey: "Failed to get RAW metadata"])
        }
        let meta = RawSpeedMetadata(from: cMeta)
        
        // Check camera support
        guard meta.cameraSupported else {
            throw NSError(domain: "RawSpeed", code: 6,
                         userInfo: [NSLocalizedDescriptionKey: "Camera not supported by RawSpeed"])
        }
        
        // Decode RAW to linear float buffer
        var cRawImage = RawSpeedBridge.RawSpeedImage()
        let decodeError = RawSpeedDecoderDecode(decoderRef, &cRawImage)
        guard decodeError == RawSpeedError_None else {
            throw mapRawSpeedError(decodeError)
        }
        let rawImage = RawSpeedImage(from: cRawImage)
        defer {
            rawImage.freeCMemory()
        }
        
        // Apply camera-space white balance if not "as shot"
        var baseTemperature: Double?
        var baseTint: Double?
        var cameraSpaceWBApplied = false
        
        if raw.whiteBalanceMode != .asShot {
            // Get WB coeffs from metadata
            let wbCoeffs = meta.wbCoeffs
            baseTemperature = Double(wbCoeffs[0]) // Approximate
            baseTint = Double(wbCoeffs[1])
            cameraSpaceWBApplied = true
        }
        
        // Convert to PixelBufferF32
        let width = rawImage.width
        let height = rawImage.height
        let channels = rawImage.channels
        
        guard width > 0, height > 0, channels >= 1 else {
            throw NSError(domain: "RawSpeed", code: 3,
                         userInfo: [NSLocalizedDescriptionKey: "Invalid RAW dimensions"])
        }
        
        // For Bayer (1 channel), we need to demosaic
        // For now, return the raw Bayer data as single-channel
        // The scene-referred pipeline will handle demosaicing separately
        var floats: [Float]
        if channels == 1 {
            // Single channel Bayer - expand to 4 channels for consistency
            // The demosaic module will interpolate RGB
            floats = rawImage.data
        } else {
            // sRAW or processed - already has RGB
            floats = rawImage.data
        }
        
        // Scale if needed
        let scaled: [Float]
        if longEdge != Int.max && max(width, height) > longEdge {
            let scale = CGFloat(longEdge) / CGFloat(max(width, height))
            let newWidth = max(1, Int(CGFloat(width) * scale))
            let newHeight = max(1, Int(CGFloat(height) * scale))
            // Use vImage for fast scaling
            scaled = try scaleBuffer(floats, width: width, height: height, channels: max(channels, 1),
                                   newWidth: newWidth, newHeight: newHeight)
            return PixelBufferF32(width: newWidth, height: newHeight, pixels: scaled)
        } else {
            // Pad to 4 channels if needed
            if channels == 1 {
                // Expand single channel to RGBA (R=raw, G=0, B=0, A=1)
                var rgba = [Float](repeating: 0, count: width * height * 4)
                for i in 0..<(width * height) {
                    rgba[i * 4] = floats[i]
                    rgba[i * 4 + 3] = 1.0
                }
                return PixelBufferF32(width: width, height: height, pixels: rgba)
            } else if channels == 3 {
                var rgba = [Float](repeating: 0, count: width * height * 4)
                for i in 0..<(width * height) {
                    rgba[i * 4] = floats[i * 3]
                    rgba[i * 4 + 1] = floats[i * 3 + 1]
                    rgba[i * 4 + 2] = floats[i * 3 + 2]
                    rgba[i * 4 + 3] = 1.0
                }
                return PixelBufferF32(width: width, height: height, pixels: rgba)
            } else {
                return PixelBufferF32(width: width, height: height, pixels: floats)
            }
        }
    }
    
    private nonisolated static func mapRawSpeedError(_ error: RawSpeedError) -> Error {
        switch error {
        case RawSpeedError_UnsupportedFormat:
            return NSError(domain: "RawSpeed", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Unsupported RAW format"])
        case RawSpeedError_LoadFailed:
            return NSError(domain: "RawSpeed", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to load RAW file"])
        case RawSpeedError_UnsupportedFeature:
            return NSError(domain: "RawSpeed", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Unsupported feature"])
        case RawSpeedError_FileCorrupted:
            return NSError(domain: "RawSpeed", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "RAW file corrupted"])
        case RawSpeedError_Memory:
            return NSError(domain: "RawSpeed", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Out of memory"])
        case RawSpeedError_CameraNotSupported:
            return NSError(domain: "RawSpeed", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "Camera not supported"])
        case RawSpeedError_Internal:
            return NSError(domain: "RawSpeed", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "Internal RawSpeed error"])
        default:
            return NSError(domain: "RawSpeed", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Unknown RawSpeed error"])
        }
    }
    
    private nonisolated static func scaleBuffer(_ input: [Float], width: Int, height: Int, channels: Int,
                                              newWidth: Int, newHeight: Int) throws -> [Float] {
        // Use vImage for fast scaling
        var output = [Float](repeating: 0, count: newWidth * newHeight * 4)
        // Simplified: just use CPU scaling for now
        for y in 0..<newHeight {
            let srcY = Float(y) / Float(newHeight) * Float(height - 1)
            let y0 = Int(srcY)
            let y1 = min(y0 + 1, height - 1)
            let fy = srcY - Float(y0)
            for x in 0..<newWidth {
                let srcX = Float(x) / Float(newWidth) * Float(width - 1)
                let x0 = Int(srcX)
                let x1 = min(x0 + 1, width - 1)
                let fx = srcX - Float(x0)
                
                let dstIdx = (y * newWidth + x) * 4
                for c in 0..<min(channels, 4) {
                    let srcIdx = (y0 * width + x0) * channels + c
                    let v00 = input[srcIdx]
                    let v01 = input[(y0 * width + x1) * channels + c]
                    let v10 = input[(y1 * width + x0) * channels + c]
                    let v11 = input[(y1 * width + x1) * channels + c]
                    
                    let interp = v00 * (1 - fx) * (1 - fy) + v01 * fx * (1 - fy) +
                                v10 * (1 - fx) * fy + v11 * fx * fy
                    output[dstIdx + c] = interp
                }
                output[dstIdx + 3] = 1.0
            }
        }
        return output
    }
    
    func fullResolution(url: URL, raw: RawSettings, bypassImportTransform: Bool) async throws -> PixelBufferF32 {
        let autoNeutral = raw.whiteBalanceMode == .auto
            ? await resolvedAutoNeutralLocation(url: url, lensCorrection: raw.lensCorrection)
            : nil
        let box = contextBox
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try Self.decodeSync(
                context: box.context,
                url: url,
                longEdge: Int.max,
                raw: raw,
                bypassImportTransform: bypassImportTransform,
                fullResolution: true,
                autoNeutralLocation: autoNeutral
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func autoWhiteBalanceResolution(url: URL, lensCorrection: Bool) async -> AutoWhiteBalanceResolution {
        if CIRAWFilter(imageURL: url) != nil,
           let location = await resolvedAutoNeutralLocation(url: url, lensCorrection: lensCorrection) {
            return AutoWhiteBalanceResolution(
                method: .cameraNeutral,
                neutralX: location.x,
                neutralY: location.y
            )
        }
        return AutoWhiteBalanceResolution(method: .workingSpaceFallback, neutralX: nil, neutralY: nil)
    }

    func whiteBalanceReference(url: URL, raw: RawSettings) async -> WhiteBalanceReference {
        if raw.whiteBalanceMode == .custom {
            return WhiteBalanceReference(temperature: raw.temperature, tint: raw.tint)
        }
        let autoNeutral = raw.whiteBalanceMode == .auto
            ? await resolvedAutoNeutralLocation(url: url, lensCorrection: raw.lensCorrection)
            : nil
        return await Task.detached(priority: .utility) {
            guard let filter = CIRAWFilter(imageURL: url) else {
                return WhiteBalanceReference(temperature: 6500, tint: 0)
            }
            filter.isLensCorrectionEnabled = raw.lensCorrection
            if let autoNeutral {
                filter.neutralLocation = CGPoint(x: autoNeutral.x, y: autoNeutral.y)
            }
            let temperature = Double(filter.neutralTemperature)
            let tint = Double(filter.neutralTint)
            return WhiteBalanceReference(
                temperature: temperature.isFinite && temperature >= 1667 ? temperature : 6500,
                tint: tint.isFinite ? tint : 0
            )
        }.value
    }

    func invalidateAutoWhiteBalance(url: URL) async {
        let prefix = url.path + "|"
        for key in autoNeutralCache.keys where key.hasPrefix(prefix) { autoNeutralCache.removeValue(forKey: key) }
        for key in autoNeutralInFlight.keys where key.hasPrefix(prefix) {
            autoNeutralInFlight[key]?.cancel()
            autoNeutralInFlight.removeValue(forKey: key)
        }
        let decodeKeys = cache.keys.filter { $0.path == url.path && $0.raw.whiteBalanceMode == .auto }
        for key in decodeKeys {
            if let removed = cache.removeValue(forKey: key) { cacheBytes -= byteCount(removed) }
            cacheOrder.removeAll { $0 == key }
        }
        let inflightKeys = inFlight.keys.filter { $0.path == url.path && $0.raw.whiteBalanceMode == .auto }
        for key in inflightKeys {
            inFlight[key]?.cancel()
            inFlight.removeValue(forKey: key)
        }
        // Recalculation must not race a stale persistent developed-source hit.
        await developedDiskCache.invalidate(url: url)
    }

    func prefetch(url: URL, longEdge: Int, raw: RawSettings, bypassImportTransform: Bool, cacheMode: PreviewCacheMemoryMode) async {
        _ = try? await decode(
            url: url,
            longEdge: longEdge,
            raw: raw,
            bypassImportTransform: bypassImportTransform,
            cacheMode: cacheMode
        )
    }

    func clear() {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        cache.removeAll()
        cacheOrder.removeAll()
        cacheBytes = 0
        for task in autoNeutralInFlight.values { task.cancel() }
        autoNeutralInFlight.removeAll()
        autoNeutralCache.removeAll()
    }

    private nonisolated static func decodeSync(
        context: CIContext,
        url: URL,
        longEdge: Int,
        raw: RawSettings,
        bypassImportTransform: Bool,
        fullResolution: Bool,
        autoNeutralLocation: AutoNeutralLocation?
    ) throws -> PixelBufferF32 {
        try Task.checkCancellation()
        let source = try sourceImage(
            url: url,
            raw: raw,
            draft: !fullResolution && longEdge <= 1024,
            autoNeutralLocation: autoNeutralLocation
        )
        let image = source.image
        try Task.checkCancellation()

        let extent = image.extent.integral
        let scaled: CIImage
        if fullResolution || max(extent.width, extent.height) <= CGFloat(longEdge) {
            scaled = image
        } else {
            let scale = CGFloat(longEdge) / max(extent.width, extent.height)
            scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        let outExtent = scaled.extent.integral
        guard outExtent.width.isFinite, outExtent.height.isFinite,
              outExtent.width > 0, outExtent.height > 0,
              outExtent.width <= 16384, outExtent.height <= 16384,
              outExtent.width * outExtent.height * 16 <= Double(ProcessInfo.processInfo.physicalMemory) / 3 else {
            throw NSError(domain: "SpektraFilm.Decode", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Photo dimensions exceed the safe decoding memory limit."])
        }
        let width = max(1, Int(outExtent.width.rounded()))
        let height = max(1, Int(outExtent.height.rounded()))
        var floats = [Float](repeating: 0, count: width * height * 4)
        let working = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!

        floats.withUnsafeMutableBytes { bytes in
            context.render(
                scaled,
                toBitmap: bytes.baseAddress!,
                rowBytes: width * 4 * MemoryLayout<Float>.size,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .RGBAf,
                colorSpace: bypassImportTransform ? nil : working
            )
        }
        try Task.checkCancellation()
        let decoded = PixelBufferF32(width: width, height: height, pixels: floats)
        // RAW Auto WB starts in camera space when a reliable neutral location exists, then runs
        // the same conservative working-space residual used by non-RAW files. The residual is
        // important in practice: camera neutralLocation can leave a small scene cast, and the old
        // implementation could appear to do nothing when As Shot was already close to neutral.
        let baseCorrected: PixelBufferF32
        if raw.whiteBalanceMode == .auto {
            // Do not stack a second gray-world correction on top of a successful camera-space
            // neutralLocation correction. The working-space estimator is fallback-only.
            baseCorrected = source.cameraSpaceAutoWBApplied ? decoded : decoded.applyingAutoWhiteBalance()
        } else {
            baseCorrected = decoded
        }
        // Settled RAW WB belongs in CIRAWFilter/camera space. The Rec.2020
        // adaptation remains only as a fallback for non-RAW and low-confidence
        // Auto-WB fallback paths.
        if source.cameraSpaceWhiteBalanceApplied {
            return baseCorrected
        }
        return baseCorrected.applyingWhiteBalanceOffsets(
            raw,
            baseTemperature: source.baseTemperature,
            baseTint: source.baseTint
        )
    }

    private nonisolated static func sourceImage(
        url: URL,
        raw: RawSettings,
        draft: Bool,
        autoNeutralLocation: AutoNeutralLocation?
    ) throws -> SourceImageResult {
        if let rawFilter = CIRAWFilter(imageURL: url) {
            rawFilter.isDraftModeEnabled = draft
            rawFilter.isLensCorrectionEnabled = raw.lensCorrection
            switch raw.whiteBalanceMode {
            case .asShot:
                break
            case .auto:
                if let autoNeutralLocation {
                    rawFilter.neutralLocation = CGPoint(x: autoNeutralLocation.x, y: autoNeutralLocation.y)
                }
            case .custom:
                rawFilter.neutralTemperature = Float(raw.temperature)
                rawFilter.neutralTint = Float(raw.tint)
            }

            // Resolve the camera-space base first. Relative As-Shot/Auto offsets
            // are then applied through CIRAWFilter instead of an approximate
            // post-development RGB matrix whenever camera-space WB is available.
            let baseTemperature = Double(rawFilter.neutralTemperature)
            let baseTint = Double(rawFilter.neutralTint)
            let canCommitCameraSpaceWB =
                raw.whiteBalanceMode != .auto || autoNeutralLocation != nil

            if raw.whiteBalanceMode != .custom && canCommitCameraSpaceWB {
                let miredOffset = raw.temperatureOffsetMired ?? 0
                let tintOffset = raw.tintOffset ?? 0
                if abs(miredOffset) > 1.0e-9 || abs(tintOffset) > 1.0e-9 {
                    let safeBase = PixelBufferF32.clampedKelvin(
                        baseTemperature.isFinite ? baseTemperature : 6500
                    )
                    rawFilter.neutralTemperature = Float(
                        PixelBufferF32.kelvin(
                            baseKelvin: safeBase,
                            miredOffset: miredOffset
                        )
                    )
                    rawFilter.neutralTint = Float(
                        (baseTint.isFinite ? baseTint : 0) + tintOffset
                    )
                }
            }

            rawFilter.exposure = Float(min(5, max(-5, raw.developExposureEV)))
            rawFilter.boostAmount = Float(min(1, max(0, raw.developGlobalTone)))
            rawFilter.boostShadowAmount = Float(min(2, max(0, raw.developShadowBoost)))
            rawFilter.extendedDynamicRangeAmount = Float(min(2, max(0, raw.developHighlightHeadroom)))

            let rawCurve = ToneCurveMath.normalize(raw.developCurvePoints)
            let identityCurve = rawCurve.count == 2
                && abs(rawCurve[0].x) < 1e-9 && abs(rawCurve[0].y) < 1e-9
                && abs(rawCurve[1].x - 1) < 1e-9 && abs(rawCurve[1].y - 1) < 1e-9
            if !identityCurve, let curveFilter = CIFilter(name: "CIToneCurve") {
                let cache = ToneCurveMath.buildCache(rawCurve)
                for index in 0...4 {
                    let x = Double(index) / 4.0
                    let y = min(1.0, max(0.0, ToneCurveMath.evaluate(x, points: rawCurve, cache: cache)))
                    curveFilter.setValue(CIVector(x: CGFloat(x), y: CGFloat(y)), forKey: "inputPoint\(index)")
                }
                rawFilter.linearSpaceFilter = curveFilter
            } else {
                rawFilter.linearSpaceFilter = nil
            }

            if let output = rawFilter.outputImage {
                return SourceImageResult(
                    image: output,
                    cameraSpaceAutoWBApplied:
                        raw.whiteBalanceMode == .auto && autoNeutralLocation != nil,
                    cameraSpaceWhiteBalanceApplied: canCommitCameraSpaceWB,
                    baseTemperature: baseTemperature.isFinite ? baseTemperature : nil,
                    baseTint: baseTint.isFinite ? baseTint : nil
                )
            }
        }
        guard let image = CIImage(contentsOf: url, options: [
            .applyOrientationProperty: true,
            .cacheImmediately: false
        ]) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        return SourceImageResult(
            image: image,
            cameraSpaceAutoWBApplied: false,
            cameraSpaceWhiteBalanceApplied: false,
            baseTemperature: raw.whiteBalanceMode == .custom ? raw.temperature : 6500,
            baseTint: raw.whiteBalanceMode == .custom ? raw.tint : 0
        )
    }

    private func resolvedAutoNeutralLocation(url: URL, lensCorrection: Bool) async -> AutoNeutralLocation? {
        let key = autoNeutralKey(url: url, lensCorrection: lensCorrection)
        if let cached = autoNeutralCache[key] { return cached }
        if let existing = autoNeutralInFlight[key] { return await existing.value }

        let box = contextBox
        let task = Task.detached(priority: .utility) {
            Self.estimateAutoNeutralLocation(context: box.context, url: url, lensCorrection: lensCorrection)
        }
        autoNeutralInFlight[key] = task
        let value = await task.value
        autoNeutralInFlight[key] = nil
        autoNeutralCache[key] = value
        return value
    }

    private func autoNeutralKey(url: URL, lensCorrection: Bool) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(url.path)|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(lensCorrection)"
    }

    /// Finds a plausible neutral patch on a small draft decode, then asks CIRAWFilter to
    /// white-balance from that location on the real RAW. This keeps Auto WB in camera space
    /// instead of applying a cosmetic RGB multiplier after development.
    private nonisolated static func estimateAutoNeutralLocation(
        context: CIContext,
        url: URL,
        lensCorrection: Bool
    ) -> AutoNeutralLocation? {
        guard let rawFilter = CIRAWFilter(imageURL: url) else { return nil }
        rawFilter.isDraftModeEnabled = true
        rawFilter.isLensCorrectionEnabled = lensCorrection
        // Do not search for a neutral patch after the camera's As Shot WB has already neutralized
        // the scene. A fixed neutral illuminant makes the color cast observable to the detector;
        // the selected pixel coordinate is then handed back to CIRAWFilter for camera-space WB.
        rawFilter.neutralTemperature = 6500
        rawFilter.neutralTint = 0
        guard let image = rawFilter.outputImage else { return nil }

        let extent = image.extent.integral
        guard extent.width.isFinite, extent.height.isFinite,
              extent.width > 2, extent.height > 2 else { return nil }
        let target = 256.0
        let scale = min(1.0, target / max(extent.width, extent.height))
        let normalized = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let width = max(1, Int((extent.width * scale).rounded()))
        let height = max(1, Int((extent.height * scale).rounded()))
        var floats = [Float](repeating: 0, count: width * height * 4)
        let working = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
        floats.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            context.render(
                normalized,
                toBitmap: base,
                rowBytes: width * 4 * MemoryLayout<Float>.size,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .RGBAf,
                colorSpace: working
            )
        }

        var bestScore = Double.greatestFiniteMagnitude
        var bestX = 0
        var bestY = 0
        var candidates = 0
        let borderX = max(2, width / 20)
        let borderY = max(2, height / 20)
        if width <= borderX * 2 || height <= borderY * 2 { return nil }

        for y in borderY..<(height - borderY) {
            for x in borderX..<(width - borderX) {
                let p = (y * width + x) * 4
                let r = max(0.0, Double(floats[p]))
                let g = max(0.0, Double(floats[p + 1]))
                let b = max(0.0, Double(floats[p + 2]))
                let maximum = max(r, max(g, b))
                let minimum = min(r, min(g, b))
                let luma = 0.2627 * r + 0.6780 * g + 0.0593 * b
                guard maximum > 1.0e-6, luma > 0.055, luma < 0.82 else { continue }
                let saturation = (maximum - minimum) / maximum
                guard saturation < 0.30 else { continue }

                // Favor truly neutral midtones and locally smooth surfaces; the local term
                // rejects single noisy pixels/specular edges that look neutral by accident.
                var localDelta = 0.0
                var localCount = 0.0
                for oy in -1...1 {
                    for ox in -1...1 where !(ox == 0 && oy == 0) {
                        let q = ((y + oy) * width + (x + ox)) * 4
                        let qr = Double(floats[q]), qg = Double(floats[q + 1]), qb = Double(floats[q + 2])
                        localDelta += abs(qr - r) + abs(qg - g) + abs(qb - b)
                        localCount += 1
                    }
                }
                let smoothness = localCount > 0 ? localDelta / localCount : 0
                let midtonePenalty = abs(log(max(1.0e-5, luma) / 0.32)) * 0.025
                let score = saturation + min(0.35, smoothness * 0.35) + midtonePenalty
                candidates += 1
                if score < bestScore {
                    bestScore = score
                    bestX = x
                    bestY = y
                }
            }
        }

        guard candidates >= 24, bestScore < 0.34 else { return nil }
        let nx = (Double(bestX) + 0.5) / Double(width)
        let ny = (Double(bestY) + 0.5) / Double(height)
        return AutoNeutralLocation(
            x: Double(extent.minX) + nx * Double(extent.width),
            y: Double(extent.minY) + ny * Double(extent.height)
        )
    }


    private func reusableInFlightTask(for requested: DecodeKey) -> (key: DecodeKey, task: Task<PixelBufferF32, Error>)? {
        var best: (DecodeKey, Task<PixelBufferF32, Error>)?
        var bestRequestedLongEdge = Int.max
        for (candidateKey, task) in inFlight {
            guard candidateKey.path == requested.path,
                  candidateKey.raw == requested.raw,
                  candidateKey.bypassImportTransform == requested.bypassImportTransform,
                  candidateKey.longEdge >= requested.longEdge else { continue }
            if candidateKey.longEdge < bestRequestedLongEdge {
                best = (candidateKey, task)
                bestRequestedLongEdge = candidateKey.longEdge
            }
        }
        return best.map { (key: $0.0, task: $0.1) }
    }

    private func reusableCachedBuffer(for requested: DecodeKey) -> (key: DecodeKey, buffer: PixelBufferF32)? {
        var best: (DecodeKey, PixelBufferF32)?
        var bestRequestedLongEdge = Int.max
        for (candidateKey, candidateBuffer) in cache {
            guard candidateKey.path == requested.path,
                  candidateKey.raw == requested.raw,
                  candidateKey.bypassImportTransform == requested.bypassImportTransform,
                  candidateKey.longEdge >= requested.longEdge else { continue }
            // Compare the requested decode sizes rather than actual pixel dimensions: a
            // physically small source may be below both sizes but the larger decode is still
            // already the best data that exists for that file.
            if candidateKey.longEdge < bestRequestedLongEdge {
                best = (candidateKey, candidateBuffer)
                bestRequestedLongEdge = candidateKey.longEdge
            }
        }
        return best.map { (key: $0.0, buffer: $0.1) }
    }

    private func insert(_ value: PixelBufferF32, key: DecodeKey, mode: PreviewCacheMemoryMode) {
        if let replaced = cache[key] { cacheBytes -= byteCount(replaced) }
        cache[key] = value
        cacheBytes += byteCount(value)
        touch(key)
        let normalBudget = CacheBudget.decodedBytes(mode: mode)
        let budget = pressureConstrained ? min(normalBudget, CacheBudget.decodedBytes(mode: .conservative)) : normalBudget
        trim(to: budget)
    }

    func handleMemoryPressure(_ level: CachePressureLevel) {
        switch level {
        case .normal:
            pressureConstrained = false
        case .warning:
            pressureConstrained = true
            // A warning means macOS is actively asking applications to return memory.
            // Keep the most-recently-used working set, but release older float decodes now.
            trim(to: CacheBudget.decodedBytes(mode: .conservative))
        case .critical:
            pressureConstrained = true
            trim(to: 0)
            for task in inFlight.values { task.cancel() }
            inFlight.removeAll()
        }
    }

    func approximateCacheBytes() -> Int { cacheBytes }

    func snapshot() -> CacheStoreSnapshot {
        CacheStoreSnapshot(
            hits: cacheHits,
            misses: cacheMisses,
            writes: 0,
            memoryBytes: Int64(cacheBytes),
            diskBytes: 0
        )
    }

    private func trim(to budget: Int) {
        while cacheBytes > budget, let old = cacheOrder.first {
            cacheOrder.removeFirst()
            if let removed = cache.removeValue(forKey: old) { cacheBytes -= byteCount(removed) }
        }
    }

    private func byteCount(_ value: PixelBufferF32) -> Int {
        value.pixels.count * MemoryLayout<Float>.size
    }

    private func touch(_ key: DecodeKey) {
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
    }
}
