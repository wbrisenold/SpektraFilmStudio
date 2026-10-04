import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Accelerate

struct ThumbnailPayload: Sendable {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    func makeCGImage() -> CGImage? {
        CGImage.fromRGBA8(width: width, height: height, bytes: rgba)
    }
}

actor ThumbnailPipeline {
    static let shared = ThumbnailPipeline()

    private var memory: [String: ThumbnailPayload] = [:]
    private var memoryOrder: [String] = []
    private var memoryBytes = 0
    private var memoryMode: PreviewCacheMemoryMode = .automatic
    private var pressureConstrained = false
    private var diskBudgetBytes: Int64 = 2 * 1024 * 1024 * 1024
    private var lastDiskPrune = Date.distantPast
    // Disk caching stays disabled until AppModel applies the selected cache root. This avoids
    // a startup race where the first thumbnail could leak into the hidden default cache before
    // a user-selected external SSD is configured.
    private var rootDirectory: URL?
    private var memoryHits = 0
    private var diskHits = 0
    private var misses = 0
    private var writes = 0
    private var inFlight: [String: Task<ThumbnailPayload, Error>] = [:]
    private var activeWorkers = 0
    private var workerWaiters: [CheckedContinuation<Void, Never>] = []
    private let maxWorkers = 4

    func thumbnail(url: URL, maxPixel: Int) async throws -> ThumbnailPayload {
        try Task.checkCancellation()
        let key = try cacheKey(url: url, maxPixel: maxPixel)
        if let cached = memory[key] {
            memoryHits += 1
            touch(key)
            return cached
        }
        if let existing = inFlight[key] {
            let value = try await existing.value
            try Task.checkCancellation()
            return value
        }

        let diskURL = cacheDirectory()?.appendingPathComponent("\(key).jpg")
        if let diskURL, FileManager.default.fileExists(atPath: diskURL.path) {
            do {
                let payload = try await Self.decodeThumbnailFile(diskURL, maxPixel: maxPixel)
                diskHits += 1
                insert(payload, for: key)
                return payload
            } catch {
                try? FileManager.default.removeItem(at: diskURL)
            }
        }

        misses += 1
        await acquireWorker()
        do { try Task.checkCancellation() } catch {
            releaseWorker()
            throw error
        }
        let task = Task.detached(priority: .utility) {
            defer { }
            return try Self.generateThumbnail(url: url, maxPixel: maxPixel, diskURL: diskURL)
        }
        inFlight[key] = task
        do {
            let payload = try await task.value
            inFlight[key] = nil
            releaseWorker()
            if diskURL != nil { writes += 1 }
            insert(payload, for: key)
            return payload
        } catch {
            inFlight[key] = nil
            releaseWorker()
            throw error
        }
    }

    func prefetch(urls: [URL], maxPixels: [Int] = [480, 1280]) async {
        let sizes = Array(Set(maxPixels.filter { $0 > 0 })).sorted(by: >)
        guard !urls.isEmpty, let largest = sizes.first else { return }
        var cursor = 0
        await withTaskGroup(of: Void.self) { group in
            let initial = min(maxWorkers, urls.count)
            for _ in 0..<initial {
                let url = urls[cursor]; cursor += 1
                group.addTask { [weak self] in
                    guard let self, let base = try? await self.thumbnail(url: url, maxPixel: largest) else { return }
                    for size in sizes.dropFirst() where !Task.isCancelled {
                        await self.cacheDerivedThumbnailIfNeeded(source: base, url: url, maxPixel: size)
                    }
                }
            }
            while await group.next() != nil {
                if Task.isCancelled { group.cancelAll(); break }
                guard cursor < urls.count else { continue }
                let url = urls[cursor]; cursor += 1
                group.addTask { [weak self] in
                    guard let self, let base = try? await self.thumbnail(url: url, maxPixel: largest) else { return }
                    for size in sizes.dropFirst() where !Task.isCancelled {
                        await self.cacheDerivedThumbnailIfNeeded(source: base, url: url, maxPixel: size)
                    }
                }
            }
        }
    }

    private func cacheDerivedThumbnailIfNeeded(source: ThumbnailPayload, url: URL, maxPixel: Int) async {
        guard max(source.width, source.height) > maxPixel,
              let key = try? cacheKey(url: url, maxPixel: maxPixel) else { return }
        if memory[key] != nil { touch(key); return }
        guard let cacheDir = cacheDirectory() else { return }
        let diskURL = cacheDir.appendingPathComponent("\(key).jpg")
        if FileManager.default.fileExists(atPath: diskURL.path) { return }
        guard let derived = try? await Task.detached(priority: .utility, operation: {
            try Self.resize(source, maxPixel: maxPixel)
        }).value else { return }
        if (try? Self.writeJPEG(derived, to: diskURL, quality: 0.82)) != nil { writes += 1 }
        insert(derived, for: key)
    }

    func configure(memoryMode: PreviewCacheMemoryMode, totalDiskCacheGB: Int, root: URL?) {
        self.memoryMode = memoryMode
        self.rootDirectory = root
        diskBudgetBytes = CacheDiskBudgetPlan(totalGB: totalDiskCacheGB).thumbnailBytes
        trimMemory()
        pruneDiskIfNeeded(force: true)
    }

    func clearMemory() {
        memory.removeAll(keepingCapacity: true)
        memoryOrder.removeAll(keepingCapacity: true)
        memoryBytes = 0
    }

    func clearDisk() {
        guard let dir = cacheDirectory() else { return }
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func handleMemoryPressure(_ level: CachePressureLevel) {
        switch level {
        case .normal:
            pressureConstrained = false
        case .warning:
            pressureConstrained = true
            trimMemory()
        case .critical:
            pressureConstrained = true
            clearMemory()
            for task in inFlight.values { task.cancel() }
            inFlight.removeAll()
        }
    }

    func approximateMemoryBytes() -> Int { memoryBytes }

    func approximateDiskUsageBytes() -> Int64 {
        guard let dir = cacheDirectory() else { return 0 }
        return Self.directorySize(dir)
    }

    func snapshot() -> CacheStoreSnapshot {
        CacheStoreSnapshot(
            hits: memoryHits + diskHits,
            misses: misses,
            writes: writes,
            memoryBytes: Int64(memoryBytes),
            diskBytes: approximateDiskUsageBytes()
        )
    }

    private func acquireWorker() async {
        if activeWorkers < maxWorkers {
            activeWorkers += 1
            return
        }
        await withCheckedContinuation { continuation in
            workerWaiters.append(continuation)
        }
    }

    private func releaseWorker() {
        if workerWaiters.isEmpty {
            activeWorkers = max(0, activeWorkers - 1)
        } else {
            let next = workerWaiters.removeFirst()
            next.resume()
        }
    }

    private func insert(_ payload: ThumbnailPayload, for key: String) {
        if let old = memory[key] { memoryBytes -= old.rgba.count }
        memory[key] = payload
        memoryBytes += payload.rgba.count
        touch(key)
        trimMemory()
        pruneDiskIfNeeded(force: false)
    }

    private func trimMemory() {
        let normalBudget = CacheBudget.thumbnailBytes(mode: memoryMode)
        let budget = pressureConstrained ? min(normalBudget, CacheBudget.thumbnailBytes(mode: .conservative)) : normalBudget
        while memoryBytes > budget, let old = memoryOrder.first {
            memoryOrder.removeFirst()
            if let removed = memory.removeValue(forKey: old) { memoryBytes -= removed.rgba.count }
        }
    }

    private func touch(_ key: String) {
        memoryOrder.removeAll { $0 == key }
        memoryOrder.append(key)
    }

    private func cacheKey(url: URL, maxPixel: Int) throws -> String {
        let sourceFingerprint = try CacheSourceFingerprint.value(for: url)
        return String(
            format: "%016llx_%d",
            fnv1a64("\(CacheSchema.thumbnail)|\(sourceFingerprint)"),
            maxPixel
        )
    }

    private func cacheDirectory() -> URL? {
        guard let rootDirectory, FileManager.default.fileExists(atPath: rootDirectory.path) else { return nil }
        let dir = CacheLocation.thumbnailsDirectory(root: rootDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func pruneDiskIfNeeded(force: Bool) {
        if !force, Date().timeIntervalSince(lastDiskPrune) < 60 { return }
        lastDiskPrune = Date()
        guard let dir = cacheDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var entries: [(URL, Int64, Date)] = []
        var total: Int64 = 0
        for file in files {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            let size = Int64(values.fileSize ?? 0)
            total += size
            entries.append((file, size, values.contentModificationDate ?? .distantPast))
        }
        guard total > diskBudgetBytes else { return }
        for entry in entries.sorted(by: { $0.2 < $1.2 }) where total > diskBudgetBytes {
            try? FileManager.default.removeItem(at: entry.0)
            total -= entry.1
        }
    }

    private func fnv1a64(_ value: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }

    private nonisolated static func decodeThumbnailFile(_ url: URL, maxPixel: Int) async throws -> ThumbnailPayload {
        try await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return try rasterize(image)
        }.value
    }

    private nonisolated static func generateThumbnail(url: URL, maxPixel: Int, diskURL: URL?) throws -> ThumbnailPayload {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }

        // First ask ImageIO for an existing embedded thumbnail/preview. This is the
        // fast path for camera RAW files and avoids demosaicing the full sensor frame.
        let embeddedOptions: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary

        let fallbackOptions: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, embeddedOptions)
                ?? CGImageSourceCreateThumbnailAtIndex(source, 0, fallbackOptions) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        try Task.checkCancellation()
        let payload = try rasterize(image)
        if let diskURL { try? writeJPEG(payload, to: diskURL, quality: 0.82) }
        return payload
    }

    private nonisolated static func rasterize(_ image: CGImage) throws -> ThumbnailPayload {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                  ) else { return false }
            context.interpolationQuality = .high
            // CGImageSourceCreateThumbnailWithTransform already applies the file's EXIF
            // orientation. Drawing into our row-major RGBA buffer must therefore use the
            // image as returned. The extra Core Graphics Y-flip used here previously made
            // Library/Cull thumbnails appear upside down after the cache pipeline changed.
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { throw CocoaError(.coderInvalidValue) }
        return ThumbnailPayload(width: width, height: height, rgba: bytes)
    }

    private nonisolated static func resize(_ payload: ThumbnailPayload, maxPixel: Int) throws -> ThumbnailPayload {
        let current = max(payload.width, payload.height)
        guard current > maxPixel else { return payload }
        let scale = Double(maxPixel) / Double(current)
        let width = max(1, Int((Double(payload.width) * scale).rounded()))
        let height = max(1, Int((Double(payload.height) * scale).rounded()))
        var output = [UInt8](repeating: 0, count: width * height * 4)
        let error: vImage_Error = payload.rgba.withUnsafeBytes { srcBytes in
            output.withUnsafeMutableBytes { dstBytes in
                guard let src = srcBytes.baseAddress, let dst = dstBytes.baseAddress else {
                    return vImage_Error(kvImageNullPointerArgument)
                }
                var source = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: src),
                    height: vImagePixelCount(payload.height),
                    width: vImagePixelCount(payload.width),
                    rowBytes: payload.width * 4
                )
                var destination = vImage_Buffer(
                    data: dst,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width * 4
                )
                return vImageScale_ARGB8888(&source, &destination, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        guard error == kvImageNoError else {
            throw NSError(domain: "SpektraFilmFast.ThumbnailScale", code: Int(error))
        }
        return ThumbnailPayload(width: width, height: height, rgba: output)
    }

    private nonisolated static func writeJPEG(_ payload: ThumbnailPayload, to url: URL, quality: Double) throws {
        let encoded = NSMutableData()
        guard let image = payload.makeCGImage(),
              let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination), encoded.length > 0 else { throw CocoaError(.fileWriteUnknown) }
        try (encoded as Data).write(to: url, options: .atomic)
    }

    private nonisolated static func directorySize(_ dir: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in e {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

actor MediaMetadataService {
    static let shared = MediaMetadataService()
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let maxConcurrent = 4

    func metadata(url: URL) async -> PhotoMetadata {
        await acquire()
        defer { release() }
        return await Task.detached(priority: .utility) {
            Self.readMetadata(url: url)
        }.value
    }

    func captureDate(url: URL) async -> Date? {
        await metadata(url: url).captureDate
    }

    private func acquire() async {
        if active < maxConcurrent { active += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { active = max(0, active - 1) }
        else { waiters.removeFirst().resume() }
    }

    private nonisolated static func readMetadata(url: URL) -> PhotoMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return PhotoMetadata()
        }

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

        var dates: [String] = []
        if let value = exif?[kCGImagePropertyExifDateTimeOriginal] as? String { dates.append(value) }
        if let value = exif?[kCGImagePropertyExifDateTimeDigitized] as? String { dates.append(value) }
        if let value = tiff?[kCGImagePropertyTIFFDateTime] as? String { dates.append(value) }
        let captureDate = dates.lazy.compactMap(parseDate).first

        let iso: Int? = {
            if let values = exif?[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber], let first = values.first { return first.intValue }
            if let value = exif?[kCGImagePropertyExifISOSpeedRatings] as? NSNumber { return value.intValue }
            return nil
        }()

        let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue

        return PhotoMetadata(
            captureDate: captureDate,
            cameraMake: clean(tiff?[kCGImagePropertyTIFFMake] as? String),
            cameraModel: clean(tiff?[kCGImagePropertyTIFFModel] as? String),
            lensModel: clean(exif?[kCGImagePropertyExifLensModel] as? String),
            iso: iso,
            aperture: (exif?[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue,
            shutterSeconds: (exif?[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue,
            focalLengthMM: (exif?[kCGImagePropertyExifFocalLength] as? NSNumber)?.doubleValue,
            pixelWidth: width,
            pixelHeight: height
        )
    }

    private nonisolated static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private nonisolated static func parseDate(_ value: String) -> Date? {
        let formats = ["yyyy:MM:dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd HH:mm:ss"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}
