import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
import os.signpost

let imageDecoderLog = OSLog(subsystem: "com.spektrafilm", category: "decode")

struct DecodeKey: Hashable, Sendable {
    var path: String
    var longEdge: Int
    var raw: RawSettings
    var bypassImportTransform: Bool
    /// CacheSourceFingerprint of the source file, so an in-place edit (Lightroom round trip,
    /// synced folder, a camera finishing a write) invalidates every tier instead of serving
    /// pixels from the previous file version. Defaults to "" so the existing four-label
    /// call sites in GPULiveFramePipeline.swift / ProductionSelfTest.swift keep compiling;
    /// those producers must pass the fingerprint themselves to get invalidation.
    var sourceFingerprint: String = ""
}

private struct AutoNeutralLocation: Hashable, Sendable {
    var x: Double
    var y: Double
}

/// Keyed by path + lensCorrection only, with the file fingerprint carried as the value so an
/// in-place edit overwrites its own entry instead of adding an unevictable one.
private struct AutoNeutralEntry {
    var sourceFingerprint: String
    var location: AutoNeutralLocation?
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
    /// key -> last-touch stamp, so touch/evict are O(1) without scanning for the key.
    private var cacheStamps: [DecodeKey: UInt64] = [:]
    private var touchCounter: UInt64 = 0
    private var cacheBytes = 0
    private var pressureConstrained = false
    private var inFlight: [DecodeKey: Task<PixelBufferF32, Error>] = [:]
    /// Index from base key (path|sourceFingerprint|raw|bypassImportTransform) to set of longEdges for O(1) lookups.
    private var inFlightIndex: [String: Set<Int>] = [:]
    /// Index from base key to set of longEdges for O(1) cache lookups.
    private var cacheIndex: [String: Set<Int>] = [:]
    private var autoNeutralCache: [String: AutoNeutralEntry] = [:]
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
        let signpostID = OSSignpostID(log: imageDecoderLog)
        os_signpost(
            .begin, log: imageDecoderLog, name: "ImageDecoder.decode", signpostID: signpostID, "path=%{public}s, longEdge=%d",
            url.lastPathComponent, longEdge)
        defer { os_signpost(.end, log: imageDecoderLog, name: "ImageDecoder.decode", signpostID: signpostID) }

        let key = DecodeKey(
            path: url.path, longEdge: longEdge, raw: raw,
            bypassImportTransform: bypassImportTransform,
            sourceFingerprint: Self.sourceFingerprint(url)
        )
        if let existing = cache[key] {
            cacheHits += 1
            PerformanceMonitor.shared.recordDecodeCacheHit()
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
            )
        {
            try Task.checkCancellation()
            PerformanceMonitor.shared.recordDiskCacheHit()
            insert(disk, key: key, mode: cacheMode)
            return disk
        }
        PerformanceMonitor.shared.recordDiskCacheMiss()

        cacheMisses += 1
        PerformanceMonitor.shared.recordDecodeCacheMiss()
        let autoNeutral =
            raw.whiteBalanceMode == .auto
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
            removeInFlight(key)
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
            removeInFlight(key)
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
    func decodeMetal(
        url: URL, longEdge: Int, raw: RawSettings,
        bypassImportTransform: Bool, gpu: GPULiveDevice
    ) async throws -> MetalDevelopedRAW {
        try Task.checkCancellation()
        let autoNeutral =
            raw.whiteBalanceMode == .auto
            ? await resolvedAutoNeutralLocation(url: url, lensCorrection: raw.lensCorrection)
            : nil
        let source = try Self.sourceImage(
            url: url, raw: raw,
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
            longEdge > 0 && longEdge <= 2048
        else {
            throw GPULiveError.unavailable("unsafe GPU decode dimensions")
        }
        let scale = min(1, CGFloat(longEdge) / max(extent.width, extent.height))
        let translated = source.image.transformed(
            by: CGAffineTransform(
                translationX: -extent.minX, y: -extent.minY))
        let scaled = translated.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let width = max(1, Int((extent.width * scale).rounded()))
        let height = max(1, Int((extent.height * scale).rounded()))
        guard width <= 2048, height <= 2048 else {
            throw GPULiveError.unavailable("GPU preview exceeds 2048 px")
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        guard let texture = gpu.device.makeTexture(descriptor: d),
            let command = gpu.queue.makeCommandBuffer()
        else {
            throw GPULiveError.unavailable("GPU RAW development allocation failed")
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
        gpu.context.render(
            scaled, to: texture, commandBuffer: command,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: colorSpace)
        command.commit()
        // The queue guarantees GPU ordering; do not block for the RAW command.
        try Task.checkCancellation()
        return MetalDevelopedRAW(texture: texture, width: width, height: height)
    }

    func fullResolution(url: URL, raw: RawSettings, bypassImportTransform: Bool) async throws -> PixelBufferF32 {
        let autoNeutral =
            raw.whiteBalanceMode == .auto
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
            let location = await resolvedAutoNeutralLocation(url: url, lensCorrection: lensCorrection)
        {
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
        let autoNeutral =
            raw.whiteBalanceMode == .auto
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
        // Exact keys, not a prefix scan: mutating a dictionary while iterating its Keys view is
        // undefined behaviour, and there is now one bounded entry per (path, lensCorrection).
        for lensCorrection in [false, true] {
            let neutralKey = autoNeutralKey(url: url, lensCorrection: lensCorrection)
            autoNeutralCache.removeValue(forKey: neutralKey)
            autoNeutralInFlight[neutralKey]?.cancel()
            autoNeutralInFlight.removeValue(forKey: neutralKey)
        }
        let decodeKeys = cache.keys.filter { $0.path == url.path && $0.raw.whiteBalanceMode == .auto }
        for key in decodeKeys { evict(key) }
        let inflightKeys = inFlight.keys.filter { $0.path == url.path && $0.raw.whiteBalanceMode == .auto }
        for key in inflightKeys {
            inFlight[key]?.cancel()
            removeInFlight(key)
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
        inFlightIndex.removeAll()
        cache.removeAll()
        cacheStamps.removeAll()
        cacheBytes = 0
        cacheIndex.removeAll()
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
            outExtent.width > 0, outExtent.height > 0
        else {
            // CIRAWFilter returns a degenerate (inf, inf, 0, 0) extent when the RAW
            // codec cannot read the file at all. That is an unreadable source, not
            // an oversized one — reporting it as a memory limit hides the real cause.
            throw NSError(
                domain: "SpektraFilm.Decode", code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "This RAW file could not be decoded by macOS. It may be corrupt, truncated, or an unsupported camera format."
                ])
        }
        guard outExtent.width <= 16384, outExtent.height <= 16384,
            outExtent.width * outExtent.height * 16 <= Double(ProcessInfo.processInfo.physicalMemory) / 3
        else {
            throw NSError(
                domain: "SpektraFilm.Decode", code: 3,
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
            let identityCurve =
                rawCurve.count == 2
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
        guard
            let image = CIImage(
                contentsOf: url,
                options: [
                    .applyOrientationProperty: true,
                    .cacheImmediately: false,
                ])
        else {
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
        let fingerprint = Self.sourceFingerprint(url)
        if let cached = autoNeutralCache[key], cached.sourceFingerprint == fingerprint { return cached.location }
        if let existing = autoNeutralInFlight[key] { return await existing.value }

        let box = contextBox
        let task = Task.detached(priority: .utility) {
            Self.estimateAutoNeutralLocation(context: box.context, url: url, lensCorrection: lensCorrection)
        }
        autoNeutralInFlight[key] = task
        let value = await task.value
        autoNeutralInFlight[key] = nil
        // A file that changed while the draft ran simply leaves a non-matching fingerprint behind,
        // which the next lookup treats as a miss and overwrites.
        autoNeutralCache[key] = AutoNeutralEntry(sourceFingerprint: fingerprint, location: value)
        return value
    }

    private func autoNeutralKey(url: URL, lensCorrection: Bool) -> String {
        "\(url.path)|\(lensCorrection)"
    }

    /// A missing or unreadable file yields "", which no real fingerprint can collide with.
    nonisolated static func sourceFingerprint(_ url: URL) -> String {
        (try? CacheSourceFingerprint.value(for: url)) ?? ""
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
            extent.width > 2, extent.height > 2
        else { return nil }
        let target = 256.0
        let scale = min(1.0, target / max(extent.width, extent.height))
        let normalized =
            image
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

    /// Base key without longEdge — shared by all decode sizes of the same source.
    /// Uses a stable hash of RawSettings to prevent silent cache invalidation when new fields are added.
    private func baseKey(for key: DecodeKey) -> String {
        "\(key.path)|\(key.sourceFingerprint)|\(key.raw.stableDecodeHash)|\(key.bypassImportTransform)"
    }

    private func reusableInFlightTask(for requested: DecodeKey) -> (key: DecodeKey, task: Task<PixelBufferF32, Error>)? {
        let base = baseKey(for: requested)
        guard let longEdges = inFlightIndex[base] else { return nil }
        var best: (DecodeKey, Task<PixelBufferF32, Error>)?
        var bestRequestedLongEdge = Int.max
        for longEdge in longEdges {
            if longEdge >= requested.longEdge, longEdge < bestRequestedLongEdge {
                let candidateKey = DecodeKey(
                    path: requested.path, longEdge: longEdge, raw: requested.raw,
                    bypassImportTransform: requested.bypassImportTransform,
                    sourceFingerprint: requested.sourceFingerprint
                )
                if let task = inFlight[candidateKey] {
                    best = (candidateKey, task)
                    bestRequestedLongEdge = longEdge
                }
            }
        }
        return best.map { (key: $0.0, task: $0.1) }
    }

    private func reusableCachedBuffer(for requested: DecodeKey) -> (key: DecodeKey, buffer: PixelBufferF32)? {
        let base = baseKey(for: requested)
        guard let longEdges = cacheIndex[base] else { return nil }
        var best: (DecodeKey, PixelBufferF32)?
        var bestRequestedLongEdge = Int.max
        for longEdge in longEdges {
            if longEdge >= requested.longEdge, longEdge < bestRequestedLongEdge {
                let candidateKey = DecodeKey(
                    path: requested.path, longEdge: longEdge, raw: requested.raw,
                    bypassImportTransform: requested.bypassImportTransform,
                    sourceFingerprint: requested.sourceFingerprint
                )
                if let buffer = cache[candidateKey] {
                    best = (candidateKey, buffer)
                    bestRequestedLongEdge = longEdge
                }
            }
        }
        return best.map { (key: $0.0, buffer: $0.1) }
    }

    private func insert(_ value: PixelBufferF32, key: DecodeKey, mode: PreviewCacheMemoryMode) {
        let base = baseKey(for: key)
        if let replaced = cache[key] { cacheBytes -= byteCount(replaced) }
        cache[key] = value
        cacheBytes += byteCount(value)
        cacheIndex[base, default: []].insert(key.longEdge)
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
            inFlightIndex.removeAll()
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
        while cacheBytes > budget {
            // Smallest stamp is the least-recently-used entry, matching the array order this
            // replaced. The scan only runs when over budget and the entry count is bounded by
            // the byte budget, so touch/evict stay O(1) on the hit and insert paths.
            guard let oldest = cacheStamps.min(by: { $0.value < $1.value })?.key else { return }
            evict(oldest)
        }
    }

    private func evict(_ key: DecodeKey) {
        let base = baseKey(for: key)
        cacheStamps.removeValue(forKey: key)
        if let removed = cache.removeValue(forKey: key) { cacheBytes -= byteCount(removed) }
        cacheIndex[base]?.remove(key.longEdge)
        if cacheIndex[base]?.isEmpty == true { cacheIndex.removeValue(forKey: base) }
    }

    private func byteCount(_ value: PixelBufferF32) -> Int {
        value.pixels.count * MemoryLayout<Float>.size
    }

    private func touch(_ key: DecodeKey) {
        touchCounter &+= 1
        cacheStamps[key] = touchCounter
    }

    private func addInFlight(_ key: DecodeKey, _ task: Task<PixelBufferF32, Error>) {
        inFlight[key] = task
        inFlightIndex[baseKey(for: key), default: []].insert(key.longEdge)
    }

    private func removeInFlight(_ key: DecodeKey) {
        inFlight.removeValue(forKey: key)
        let base = baseKey(for: key)
        inFlightIndex[base]?.remove(key.longEdge)
        if inFlightIndex[base]?.isEmpty == true { inFlightIndex.removeValue(forKey: base) }
    }
}
