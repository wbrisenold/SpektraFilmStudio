import Foundation

struct RawForgeCacheStats: Sendable {
    var files: Int = 0
    var bytes: Int64 = 0
    var formatted: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + " · \(files) file\(files == 1 ? "" : "s")"
    }
}

struct RawForgeBatchResult: Sendable {
    var prepared = 0
    var cacheHits = 0
    var skipped = 0
    var failed = 0
    var elapsed: TimeInterval = 0
}

actor RawForgeDenoiseService {
    enum ServiceError: LocalizedError {
        case rawForgeMissing
        case unsupportedSource
        case failed(Int32, String)
        var errorDescription: String? {
            switch self {
            case .rawForgeMissing: return "RawForge is not installed. Run PREPARE_STAGE4_RAWFORGE.command first."
            case .unsupportedSource: return "RAW denoise only runs on supported camera RAW/DNG sources."
            case let .failed(code, text): return "RawForge failed (\(code)): \(text)"
            }
        }
    }

    nonisolated static let supportedExtensions: Set<String> = [
        "dng","cr2","cr3","nef","nrw","arw","srf","sr2","raf","orf","rw2","rwl","pef","ptx","3fr","fff","iiq","mos","mef","mrw","erf","kdc","dcr","x3f","raw","srw"
    ]

    nonisolated static func cacheRoot() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpektraFilmFast", isDirectory: true)
            .appendingPathComponent("RawForgeDNG", isDirectory: true)
    }

    nonisolated static func executableURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/SpektraFilmFast/rawforge-venv/bin/rawforge")
    }

    nonisolated static func strength(raw: RawSettings, iso: Int?) -> (luma: Double, chroma: Double) {
        switch raw.denoiseMode {
        case .off: return (0, 0)
        case .manual:
            return (min(1, max(0, raw.denoiseLuma)), min(1, max(0, raw.denoiseChroma)))
        case .auto:
            let value = Double(max(50, iso ?? 800))
            let stops = max(0, log2(value / 100.0))
            return (min(0.72, 0.06 + stops * 0.085), min(0.58, 0.04 + stops * 0.065))
        }
    }

    nonisolated static func destinationURL(source: URL, raw: RawSettings, iso: Int? = nil) -> URL? {
        guard raw.denoiseMode != .off, supportedExtensions.contains(source.pathExtension.lowercased()) else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: source.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let stamp = Int64((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let s = strength(raw: raw, iso: iso)
        let identity = [source.standardizedFileURL.path, String(size), String(stamp), raw.denoiseModel,
                        String(format: "%.4f", s.luma), String(format: "%.4f", s.chroma)].joined(separator: "|")
        let hash = Stage5StableHash.fnv1a64(identity)
        return cacheRoot().appendingPathComponent(String(format: "%016llx.dng", hash))
    }

    nonisolated static func cacheURL(source: URL, raw: RawSettings, iso: Int? = nil) -> URL? {
        guard let url = destinationURL(source: source, raw: raw, iso: iso), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func prepare(source: URL, raw: RawSettings, iso: Int?) async throws -> URL {
        guard raw.denoiseMode != .off else { return source }
        guard Self.supportedExtensions.contains(source.pathExtension.lowercased()) else { throw ServiceError.unsupportedSource }
        if let cached = Self.cacheURL(source: source, raw: raw, iso: iso) { return cached }
        guard let destination = Self.destinationURL(source: source, raw: raw, iso: iso) else { return source }
        let exe = Self.executableURL()
        guard FileManager.default.isExecutableFile(atPath: exe.path) else { throw ServiceError.rawForgeMissing }
        let root = Self.cacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let strengths = Self.strength(raw: raw, iso: iso)
        let temporary = root.appendingPathComponent(".\(UUID().uuidString).dng")
        let process = Process()
        process.executableURL = exe
        process.arguments = [raw.denoiseModel, source.path, temporary.path, "--cfa", "--device", "cpu", "--disable_tqdm",
                             "--lumi", String(format: "%.4f", strengths.luma), "--chroma", String(format: "%.4f", strengths.chroma)]
        let stderr = Pipe(); process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let errorText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: temporary.path) else {
            try? FileManager.default.removeItem(at: temporary)
            throw ServiceError.failed(process.terminationStatus, errorText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if FileManager.default.fileExists(atPath: destination.path) { try? FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    /// Background/pre-export prewarm. Concurrency is intentionally bounded because RawForge is
    /// CPU-heavy and wedding sets should not starve the editor or blow out memory.
    func prewarm(_ images: [ProjectImageRecord], maxConcurrent: Int = 2) async -> RawForgeBatchResult {
        let start = ProcessInfo.processInfo.systemUptime
        let candidates = images.filter { $0.look.raw.denoiseMode != .off && Self.supportedExtensions.contains($0.url.pathExtension.lowercased()) }
        var result = RawForgeBatchResult(skipped: images.count - candidates.count)
        guard !candidates.isEmpty else { result.elapsed = ProcessInfo.processInfo.systemUptime - start; return result }

        let limit = max(1, min(2, maxConcurrent))
        var next = 0
        let service = self
        await withTaskGroup(of: (Bool, Bool).self) { group in
            while next < min(limit, candidates.count) {
                let image = candidates[next]; next += 1
                let wasCached = Self.cacheURL(source: image.url, raw: image.look.raw, iso: image.metadata?.iso) != nil
                group.addTask {
                    do { _ = try await service.prepare(source: image.url, raw: image.look.raw, iso: image.metadata?.iso); return (true, wasCached) }
                    catch { return (false, wasCached) }
                }
            }
            while let item = await group.next() {
                if item.0 { result.prepared += 1; if item.1 { result.cacheHits += 1 } } else { result.failed += 1 }
                if next < candidates.count {
                    let image = candidates[next]; next += 1
                    let wasCached = Self.cacheURL(source: image.url, raw: image.look.raw, iso: image.metadata?.iso) != nil
                    group.addTask {
                        do { _ = try await service.prepare(source: image.url, raw: image.look.raw, iso: image.metadata?.iso); return (true, wasCached) }
                        catch { return (false, wasCached) }
                    }
                }
            }
        }
        result.elapsed = ProcessInfo.processInfo.systemUptime - start
        return result
    }

    func stats() -> RawForgeCacheStats {
        let fm = FileManager.default, root = Self.cacheRoot()
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { return .init() }
        var out = RawForgeCacheStats()
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
            out.files += 1; out.bytes += Int64(v.fileSize ?? 0)
        }
        return out
    }

    func clear() throws {
        let root = Self.cacheRoot()
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
}

private enum Stage5StableHash {
    static func fnv1a64(_ text: String) -> UInt64 {
        var hash: UInt64 = 1469598103934665603
        for byte in text.utf8 { hash ^= UInt64(byte); hash &*= 1099511628211 }
        return hash
    }
}
