import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Dispatch

enum CachePressureLevel: Sendable {
    case normal
    case warning
    case critical
}

struct CacheBudget: Sendable {
    static func decodedBytes(mode: PreviewCacheMemoryMode) -> Int {
        let physical = Int(ProcessInfo.processInfo.physicalMemory)
        switch mode {
        case .conservative:
            return min(384 * 1024 * 1024, max(192 * 1024 * 1024, physical / 32))
        case .automatic:
            return min(1536 * 1024 * 1024, max(384 * 1024 * 1024, physical / 12))
        case .aggressive:
            return min(3 * 1024 * 1024 * 1024, max(768 * 1024 * 1024, physical / 7))
        }
    }

    static func renderedFrameBytes(mode: PreviewCacheMemoryMode) -> Int {
        switch mode {
        case .conservative: return 64 * 1024 * 1024
        case .automatic: return 192 * 1024 * 1024
        case .aggressive: return 512 * 1024 * 1024
        }
    }

    static func thumbnailBytes(mode: PreviewCacheMemoryMode) -> Int {
        switch mode {
        case .conservative: return 24 * 1024 * 1024
        case .automatic: return 64 * 1024 * 1024
        case .aggressive: return 160 * 1024 * 1024
        }
    }
}

final class MemoryPressureMonitor: @unchecked Sendable {
    private let source: any DispatchSourceMemoryPressure

    init(handler: @escaping @Sendable (DispatchSource.MemoryPressureEvent) -> Void) {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: .all, queue: .global(qos: .utility))
        self.source = source
        source.setEventHandler { [weak self] in
            guard let self, !self.source.isCancelled else { return }
            handler(self.source.data)
        }
        source.activate()
    }

    deinit { source.cancel() }
}

private enum FloatImageDiskCodec {
    private static let magic = Array("SFFIMG01".utf8)
    private static let headerBytes = 24

    static func runAuditRegressionTest() -> Bool {
        var corrupt = Data("SFFIMG01".utf8)
        for value: UInt32 in [UInt32.max, UInt32.max, 0, 0] {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { corrupt.append(contentsOf: $0) }
        }
        let valid = FloatImagePayload(width: 1, height: 1, data: Data(count: 16))
        guard decode(corrupt) == nil, let encoded = encode(valid), let decoded = decode(encoded) else { return false }
        return decoded.data == valid.data && decoded.width == 1 && decoded.height == 1
    }

    static func encode(_ payload: FloatImagePayload) -> Data? {
        guard payload.width > 0, payload.height > 0, payload.width <= 16384, payload.height <= 16384,
              payload.data.count == payload.expectedByteCount else { return nil }
        var data = Data()
        data.reserveCapacity(headerBytes + payload.data.count)
        data.append(contentsOf: magic)
        var width = UInt32(payload.width).littleEndian
        var height = UInt32(payload.height).littleEndian
        var byteCount = UInt32(payload.data.count).littleEndian
        var reserved: UInt32 = 0
        withUnsafeBytes(of: &width) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &height) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &byteCount) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &reserved) { data.append(contentsOf: $0) }
        data.append(payload.data)
        return data
    }

    static func decode(_ data: Data) -> FloatImagePayload? {
        guard data.count >= headerBytes, Array(data.prefix(8)) == magic else { return nil }
        func u32(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes { raw in
                UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            }
        }
        let width = Int(u32(8))
        let height = Int(u32(12))
        let byteCount = Int(u32(16))
        guard width > 0, height > 0, width <= 16384, height <= 16384,
              byteCount == width * height * 4 * MemoryLayout<Float>.size,
              data.count == headerBytes + byteCount else { return nil }
        return FloatImagePayload(width: width, height: height, data: data.subdata(in: headerBytes..<data.count))
    }
}

struct RenderedPreviewDiskEntry: Sendable {
    let payload: FloatImagePayload
    let quality: RenderedPreviewQuality
}

enum RenderedPreviewQuality: String, Sendable {
    case accurate
}

private enum CacheFileIO {
    static func directorySize(_ dir: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in e {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

/// Persistent developed linear preview sources. This cache sits *before* Spektrafilm so
/// reopening a RAW does not have to invoke CIRAWFilter again after RAM eviction or app relaunch.
actor DevelopedSourceDiskCache {
    static let shared = DevelopedSourceDiskCache()
    private static let magic = Array("SFFSRC01".utf8)
    private static let headerBytes = 24

    private var rootDirectory: URL?
    private var budgetBytes: Int64 = 8 * 1024 * 1024 * 1024
    private var lastPrune = Date.distantPast
    private var hits = 0
    private var misses = 0
    private var writes = 0

    func configure(totalDiskCacheGB: Int, root: URL?) {
        rootDirectory = root
        budgetBytes = CacheDiskBudgetPlan(totalGB: totalDiskCacheGB).developedSourceBytes
        pruneIfNeeded(force: true)
    }

    func buffer(
        url: URL,
        raw: RawSettings,
        longEdge: Int,
        bypassImportTransform: Bool
    ) -> PixelBufferF32? {
        guard longEdge != Int.max,
              let key = try? key(url: url, raw: raw, longEdge: longEdge, bypassImportTransform: bypassImportTransform),
              let dir = directory() else { misses += 1; return nil }
        let file = dir.appendingPathComponent("\(key).rgba32f")
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
              let decoded = Self.decode(data) else {
            misses += 1
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        hits += 1
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return decoded
    }

    func store(
        _ buffer: PixelBufferF32,
        url: URL,
        raw: RawSettings,
        longEdge: Int,
        bypassImportTransform: Bool
    ) {
        guard longEdge != Int.max,
              let key = try? key(url: url, raw: raw, longEdge: longEdge, bypassImportTransform: bypassImportTransform),
              let dir = directory(),
              let data = Self.encode(buffer) else { return }
        let file = dir.appendingPathComponent("\(key).rgba32f")
        do {
            try data.write(to: file, options: .atomic)
            writes += 1
            pruneSourceVariants(directory: dir, sourceURL: url, maxEntries: 6)
            pruneIfNeeded(force: false)
        } catch {
            return
        }
    }

    func clear() {
        guard let dir = directory() else { return }
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func invalidate(url: URL) {
        guard let dir = directory() else { return }
        let prefix = String(format: "%016llx_", Self.fnv1a64(url.standardizedFileURL.path))
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func snapshot() -> CacheStoreSnapshot {
        CacheStoreSnapshot(hits: hits, misses: misses, writes: writes, memoryBytes: 0, diskBytes: directory().map(CacheFileIO.directorySize) ?? 0)
    }

    private func key(url: URL, raw: RawSettings, longEdge: Int, bypassImportTransform: Bool) throws -> String {
        let sourceFingerprint = try CacheSourceFingerprint.value(for: url)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let rawData = try encoder.encode(raw)
        var hash: UInt64 = 0xcbf29ce484222325
        func consume<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
            for byte in bytes { hash ^= UInt64(byte); hash &*= 0x100000001b3 }
        }
        consume("\(CacheSchema.developedSource)|\(sourceFingerprint)|\(longEdge)|\(bypassImportTransform)".utf8)
        consume(rawData)
        let sourceID = Self.fnv1a64(url.standardizedFileURL.path)
        return String(format: "%016llx_%016llx_%d", sourceID, hash, longEdge)
    }

    private func directory() -> URL? {
        guard let rootDirectory, FileManager.default.fileExists(atPath: rootDirectory.path) else { return nil }
        return CacheLocation.developedSourcesDirectory(root: rootDirectory)
    }

    private func pruneIfNeeded(force: Bool) {
        if !force, Date().timeIntervalSince(lastPrune) < 60 { return }
        lastPrune = Date()
        guard let dir = directory(),
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else { return }
        var total: Int64 = 0
        var entries: [(URL, Int64, Date)] = []
        for file in files {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            let size = Int64(values.fileSize ?? 0)
            total += size
            entries.append((file, size, values.contentModificationDate ?? .distantPast))
        }
        guard total > budgetBytes else { return }
        for entry in entries.sorted(by: { $0.2 < $1.2 }) where total > budgetBytes {
            try? FileManager.default.removeItem(at: entry.0)
            total -= entry.1
        }
    }

    private func pruneSourceVariants(directory: URL, sourceURL: URL, maxEntries: Int) {
        let prefix = String(format: "%016llx_", Self.fnv1a64(sourceURL.standardizedFileURL.path))
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let variants = files.filter { $0.lastPathComponent.hasPrefix(prefix) }
            .compactMap { file -> (URL, Date)? in
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return (file, date)
            }
            .sorted { $0.1 > $1.1 }
        for entry in variants.dropFirst(maxEntries) { try? FileManager.default.removeItem(at: entry.0) }
    }

    nonisolated static func runAuditRegressionTest() -> Bool {
        var corrupt = Data(magic)
        for value: UInt32 in [UInt32.max, UInt32.max, 0, 0] {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { corrupt.append(contentsOf: $0) }
        }
        let valid = PixelBufferF32(width: 1, height: 1, pixels: [0.1, 0.2, 0.3, 1])
        guard decode(corrupt) == nil, let encoded = encode(valid), let decoded = decode(encoded) else { return false }
        return decoded.pixels == valid.pixels && decoded.width == 1 && decoded.height == 1
    }

    private nonisolated static func encode(_ buffer: PixelBufferF32) -> Data? {
        guard buffer.width > 0, buffer.height > 0, buffer.width <= 16384, buffer.height <= 16384,
              buffer.pixels.count == buffer.width * buffer.height * 4 else { return nil }
        var data = Data()
        data.reserveCapacity(headerBytes + buffer.pixels.count * MemoryLayout<Float>.size)
        data.append(contentsOf: magic)
        var width = UInt32(buffer.width).littleEndian
        var height = UInt32(buffer.height).littleEndian
        var count = UInt32(buffer.pixels.count).littleEndian
        var reserved: UInt32 = 0
        withUnsafeBytes(of: &width) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &height) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &reserved) { data.append(contentsOf: $0) }
        buffer.pixels.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    private nonisolated static func decode(_ data: Data) -> PixelBufferF32? {
        guard data.count >= headerBytes,
              Array(data.prefix(8)) == magic else { return nil }
        func u32(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes { raw in
                UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            }
        }
        let width = Int(u32(8))
        let height = Int(u32(12))
        let count = Int(u32(16))
        guard width > 0, height > 0, width <= 16384, height <= 16384, count == width * height * 4,
              data.count == headerBytes + count * MemoryLayout<Float>.size else { return nil }
        let pixels: [Float] = data.withUnsafeBytes { raw in
            let start = raw.baseAddress!.advanced(by: headerBytes).assumingMemoryBound(to: Float.self)
            return Array(UnsafeBufferPointer(start: start, count: count))
        }
        return PixelBufferF32(width: width, height: height, pixels: pixels)
    }

    private nonisolated static func fnv1a64(_ value: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 { hash ^= UInt64(byte); hash &*= 0x100000001b3 }
        return hash
    }
}

actor RenderedPreviewDiskCache {
    static let shared = RenderedPreviewDiskCache()
    private var budgetBytes: Int64 = 4 * 1024 * 1024 * 1024
    private var lastPrune = Date.distantPast
    private var rootDirectory: URL?
    private var hits = 0
    private var misses = 0
    private var writes = 0

    func configure(totalDiskCacheGB: Int, root: URL?) {
        budgetBytes = CacheDiskBudgetPlan(totalGB: totalDiskCacheGB).renderedPreviewBytes
        rootDirectory = root
        pruneIfNeeded(force: true)
    }

    /// Prefer an accurate cached frame if one exists; otherwise the working-policy frame is
    /// the correct instant-open cache for normal editing. Count the lookup once, not as a miss
    /// followed by a hit.
    func bestPreview(url: URL, look: RenderLook, longEdge: Int, bypassImportTransform: Bool) -> RenderedPreviewDiskEntry? {
        guard let dir = directory() else { misses += 1; return nil }
        for quality in [RenderedPreviewQuality.accurate] {
            guard let key = try? key(url: url, look: look, longEdge: longEdge, bypassImportTransform: bypassImportTransform, quality: quality) else { continue }
            let file = dir.appendingPathComponent("\(key).rgba32f")
            if let data = try? Data(contentsOf: file, options: .mappedIfSafe),
               let payload = FloatImageDiskCodec.decode(data) {
                hits += 1
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
                return RenderedPreviewDiskEntry(payload: payload, quality: quality)
            }
            // Invalid/partial cache data must never be reused.
            if FileManager.default.fileExists(atPath: file.path) { try? FileManager.default.removeItem(at: file) }
        }
        misses += 1
        return nil
    }

    func store(
        payload: FloatImagePayload,
        url: URL,
        look: RenderLook,
        longEdge: Int,
        bypassImportTransform: Bool,
        quality: RenderedPreviewQuality
    ) {
        guard let key = try? key(url: url, look: look, longEdge: longEdge, bypassImportTransform: bypassImportTransform, quality: quality),
              let dir = directory(),
              let encoded = FloatImageDiskCodec.encode(payload) else { return }
        let file = dir.appendingPathComponent("\(key).rgba32f")
        do {
            try encoded.write(to: file, options: .atomic)
            writes += 1
            pruneSourceVariants(directory: dir, sourceURL: url, maxEntriesPerQuality: 4)
            pruneIfNeeded(force: false)
        } catch {
            return
        }
    }

    func clear() {
        guard let dir = directory() else { return }
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func invalidate(url: URL) {
        guard let dir = directory() else { return }
        let prefix = String(format: "%016llx_", Self.fnv1a64(url.standardizedFileURL.path))
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func approximateDiskUsageBytes() -> Int64 {
        guard let dir = directory() else { return 0 }
        return CacheFileIO.directorySize(dir)
    }

    func snapshot() -> CacheStoreSnapshot {
        CacheStoreSnapshot(hits: hits, misses: misses, writes: writes, memoryBytes: 0, diskBytes: approximateDiskUsageBytes())
    }

    private func key(
        url: URL,
        look: RenderLook,
        longEdge: Int,
        bypassImportTransform: Bool,
        quality: RenderedPreviewQuality
    ) throws -> String {
        let sourceFingerprint = try CacheSourceFingerprint.value(for: url)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let lookData = try encoder.encode(look)
        var hash: UInt64 = 0xcbf29ce484222325
        func consume<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
            for byte in bytes { hash ^= UInt64(byte); hash &*= 0x100000001b3 }
        }
        consume("\(CacheSchema.renderedPreview)|\(quality.rawValue)|\(sourceFingerprint)|\(longEdge)|\(bypassImportTransform)".utf8)
        consume(lookData)
        let sourceID = Self.fnv1a64(url.standardizedFileURL.path)
        return String(format: "%016llx", sourceID) + "_\(quality.rawValue)_" + String(format: "%016llx_%d", hash, longEdge)
    }

    private func pruneSourceVariants(directory: URL, sourceURL: URL, maxEntriesPerQuality: Int) {
        let sourcePrefix = String(format: "%016llx_", Self.fnv1a64(sourceURL.standardizedFileURL.path))
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for quality in [RenderedPreviewQuality.accurate] {
            let prefix = "\(sourcePrefix)\(quality.rawValue)_"
            let variants = files.filter { $0.lastPathComponent.hasPrefix(prefix) }
                .compactMap { file -> (URL, Date)? in
                    let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return (file, date)
                }
                .sorted { $0.1 > $1.1 }
            for entry in variants.dropFirst(maxEntriesPerQuality) { try? FileManager.default.removeItem(at: entry.0) }
        }
    }

    private nonisolated static func fnv1a64(_ value: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 { hash ^= UInt64(byte); hash &*= 0x100000001b3 }
        return hash
    }

    private func directory() -> URL? {
        guard let rootDirectory, FileManager.default.fileExists(atPath: rootDirectory.path) else { return nil }
        return CacheLocation.adjustedPreviewDirectory(root: rootDirectory)
    }

    private func pruneIfNeeded(force: Bool) {
        if !force, Date().timeIntervalSince(lastPrune) < 60 { return }
        lastPrune = Date()
        guard let dir = directory(),
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
        guard total > budgetBytes else { return }
        for entry in entries.sorted(by: { $0.2 < $1.2 }) where total > budgetBytes {
            try? FileManager.default.removeItem(at: entry.0)
            total -= entry.1
        }
    }
}

actor CullAnalysisDiskCache {
    static let shared = CullAnalysisDiskCache()
    private var rootDirectory: URL?
    private var budgetBytes: Int64 = 512 * 1024 * 1024
    private var hits = 0
    private var misses = 0
    private var writes = 0
    private var lastPrune = Date.distantPast

    func configure(totalDiskCacheGB: Int, root: URL?) {
        rootDirectory = root
        budgetBytes = CacheDiskBudgetPlan(totalGB: totalDiskCacheGB).cullAnalysisBytes
        pruneIfNeeded(force: true)
    }

    func analysis(url: URL) -> CullAnalysisRecord? {
        guard let key = try? key(url: url), let dir = directory() else { misses += 1; return nil }
        let file = dir.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
              let record = try? JSONDecoder().decode(CullAnalysisRecord.self, from: data) else {
            misses += 1
            return nil
        }
        hits += 1
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return record
    }

    func store(_ record: CullAnalysisRecord, url: URL) {
        guard let key = try? key(url: url), let dir = directory(),
              let data = try? JSONEncoder().encode(record) else { return }
        let file = dir.appendingPathComponent("\(key).json")
        do {
            try data.write(to: file, options: .atomic)
            writes += 1
            pruneIfNeeded(force: false)
        } catch {
            return
        }
    }

    func clear() {
        guard let dir = directory() else { return }
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func snapshot() -> CacheStoreSnapshot {
        let bytes = directory().map(CacheFileIO.directorySize) ?? 0
        return CacheStoreSnapshot(hits: hits, misses: misses, writes: writes, memoryBytes: 0, diskBytes: bytes)
    }

    private func directory() -> URL? {
        guard let rootDirectory, FileManager.default.fileExists(atPath: rootDirectory.path) else { return nil }
        return CacheLocation.cullAnalysisDirectory(root: rootDirectory)
    }

    private func key(url: URL) throws -> String {
        let sourceFingerprint = try CacheSourceFingerprint.value(for: url)
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in "\(CacheSchema.cullAnalysis)|\(sourceFingerprint)".utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    private func pruneIfNeeded(force: Bool) {
        if !force, Date().timeIntervalSince(lastPrune) < 60 { return }
        lastPrune = Date()
        guard let dir = directory(),
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else { return }
        var total: Int64 = 0
        var entries: [(URL, Int64, Date)] = []
        for file in files {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            let size = Int64(values.fileSize ?? 0)
            total += size
            entries.append((file, size, values.contentModificationDate ?? .distantPast))
        }
        guard total > budgetBytes else { return }
        for entry in entries.sorted(by: { $0.2 < $1.2 }) where total > budgetBytes {
            try? FileManager.default.removeItem(at: entry.0)
            total -= entry.1
        }
    }
}

enum CacheCodecAudit {
    static func run() -> Bool {
        FloatImageDiskCodec.runAuditRegressionTest() && DevelopedSourceDiskCache.runAuditRegressionTest()
    }
}
