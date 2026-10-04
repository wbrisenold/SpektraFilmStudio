import Foundation

struct CacheStoreSnapshot: Sendable {
    var hits: Int = 0
    var misses: Int = 0
    var writes: Int = 0
    var memoryBytes: Int64 = 0
    var diskBytes: Int64 = 0
}


/// Cache generation identifiers are deliberately independent from the project format.
/// A cache hit is only valid when the code that produced those pixels/metrics is still
/// compatible with the current build. Bump the relevant token whenever its algorithm,
/// serialization, renderer pin, or model changes.
enum CacheSchema {
    static let thumbnail = "thumb-v4-orientation-correct"
    static let developedSource = "developed-linear-rec2020-autowb-v4-normal-preview"
    static let renderedPreview = "rendered-v6-float-exact-preview-core-8f665185"
    static let cullAnalysis = "cull-v4-vision-native"
}

/// One centralized disk-budget plan prevents independently-sized caches from silently
/// exceeding the user's selected total. The percentages intentionally total 100%.
struct CacheDiskBudgetPlan: Sendable {
    let totalBytes: Int64
    let thumbnailBytes: Int64
    let developedSourceBytes: Int64
    let renderedPreviewBytes: Int64
    let cullAnalysisBytes: Int64

    init(totalGB: Int) {
        let total = Int64(min(100, max(2, totalGB))) * 1024 * 1024 * 1024
        totalBytes = total
        thumbnailBytes = total * 15 / 100
        developedSourceBytes = total * 50 / 100
        renderedPreviewBytes = total * 30 / 100
        cullAnalysisBytes = total - thumbnailBytes - developedSourceBytes - renderedPreviewBytes
    }
}

enum CacheLocationError: LocalizedError {
    case unavailable(String)
    case notWritable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let path): return "Cache location is unavailable: \(path)"
        case .notWritable(let path): return "Cache location is not writable: \(path)"
        }
    }
}

enum CacheLocation {
    static let folderName = "SpektraFilmFast Cache"
    static let markerName = "Cache Info.txt"

    static func defaultParentDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    static func root(parentPath: String) throws -> URL {
        let custom = !parentPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let parent = custom
            ? URL(fileURLWithPath: parentPath, isDirectory: true).standardizedFileURL
            : defaultParentDirectory()

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CacheLocationError.unavailable(parent.path)
        }

        let root = parent.appendingPathComponent(folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw CacheLocationError.notWritable(root.path)
        }
        try validateWritable(root)
        writeMarker(root: root, custom: custom)
        return root
    }

    static func thumbnailsDirectory(root: URL) -> URL {
        child("Thumbnails", root: root)
    }

    static func adjustedPreviewDirectory(root: URL) -> URL {
        child("Adjusted Previews", root: root)
    }

    static func developedSourcesDirectory(root: URL) -> URL {
        child("Developed Sources", root: root)
    }

    static func cullAnalysisDirectory(root: URL) -> URL {
        child("Cull Analysis", root: root)
    }

    static func describe(parentPath: String) -> String {
        let parent = parentPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultParentDirectory()
            : URL(fileURLWithPath: parentPath, isDirectory: true)
        return parent.appendingPathComponent(folderName, isDirectory: true).path
    }

    private static func child(_ name: String, root: URL) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func validateWritable(_ root: URL) throws {
        let probe = root.appendingPathComponent(".write-test-\(UUID().uuidString)")
        do {
            try Data("ok".utf8).write(to: probe, options: .atomic)
            try FileManager.default.removeItem(at: probe)
        } catch {
            try? FileManager.default.removeItem(at: probe)
            throw CacheLocationError.notWritable(root.path)
        }
    }

    private static func writeMarker(root: URL, custom: Bool) {
        let text = """
        SpektraFilmFast local cache

        This folder is safe to delete when SpektraFilmFast is not running.
        It stores generated thumbnails, developed linear preview sources, exact adjusted previews,
        and Smart Cull analysis.
        Original photographs and project files are never stored here.

        Location type: \(custom ? "User-selected" : "macOS default cache")
        """
        try? Data(text.utf8).write(to: root.appendingPathComponent(markerName), options: .atomic)
    }
}

enum CacheSourceFingerprint {
    static func value(for url: URL) throws -> String {
        let standardized = url.standardizedFileURL
        let values = try standardized.resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileSizeKey,
            .generationIdentifierKey,
            .documentIdentifierKey
        ])
        let stamp = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values.fileSize ?? 0
        let documentID = values.documentIdentifier.map(String.init) ?? "no-document-id"
        let generationHash: String
        if let generation = values.generationIdentifier,
           let archived = try? NSKeyedArchiver.archivedData(withRootObject: generation, requiringSecureCoding: true) {
            generationHash = String(format: "%016llx", fnv1a64(archived))
        } else {
            generationHash = "no-generation-id"
        }
        // generationIdentifier is persistent across restarts on supporting filesystems and changes
        // with the data fork. Path/mtime/size keep this useful on FAT/exFAT and other volumes that
        // do not expose Foundation generation identifiers.
        return "\(standardized.path)|\(documentID)|\(generationHash)|\(stamp)|\(size)"
    }

    private static func fnv1a64(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data { hash ^= UInt64(byte); hash &*= 0x100000001b3 }
        return hash
    }
}

