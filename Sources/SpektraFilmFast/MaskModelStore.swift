import Foundation
import CryptoKit

enum ModelStoreError: Error, LocalizedError {
    case unknownModel(String), download(String), checksumMismatch(String)
    var errorDescription: String? {
        switch self {
        case .unknownModel(let id): return "Install \(id) in Settings › Models first."
        case .download(let message): return message
        case .checksumMismatch(let path): return "Model verification failed: \(path)"
        }
    }
}

/// Redlamp's exact, versioned model manifests; downloads are verified before becoming usable.
actor MaskModelStore {
    static let shared = MaskModelStore()
    static var root: URL {
        if CommandLine.arguments.contains("--mask-integration-test"),
           let index = CommandLine.arguments.firstIndex(of: "--mask-model-root"), index + 1 < CommandLine.arguments.count {
            return URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpektraFilmStudio/Models", isDirectory: true)
    }
    private var installing = Set<String>()
    nonisolated static func directory(_ manifest: ModelManifest) -> URL {
        root.appendingPathComponent("\(manifest.id)-v\(manifest.version)", isDirectory: true)
    }
    nonisolated static func installed(_ manifest: ModelManifest) -> Bool {
        FileManager.default.fileExists(atPath: directory(manifest).appendingPathComponent("verified.json").path)
    }
    func install(_ manifest: ModelManifest) async throws {
        guard manifest.isPublished, manifest.fits() else { throw ModelStoreError.download("This model is unavailable for this Mac.") }
        guard !Self.installed(manifest) else { return }
        guard installing.insert(manifest.id).inserted else { throw ModelStoreError.download("This model is already downloading.") }
        defer { installing.remove(manifest.id) }
        let fm = FileManager.default
        try fm.createDirectory(at: Self.root, withIntermediateDirectories: true)
        let staging = Self.root.appendingPathComponent(".download-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        for file in manifest.files {
            try Task.checkCancellation()
            guard !file.path.hasPrefix("/"), !file.path.split(separator: "/").contains("..") else {
                throw ModelStoreError.download("Invalid model path")
            }
            let (temporary, response) = try await URLSession.shared.download(from: manifest.remote(file))
            defer { try? fm.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw ModelStoreError.download("Download failed for \(file.path)")
            }
            let attributes = try fm.attributesOfItem(atPath: temporary.path)
            guard (attributes[.size] as? NSNumber)?.intValue == file.bytes else {
                throw ModelStoreError.checksumMismatch(file.path)
            }
            let handle = try FileHandle(forReadingFrom: temporary)
            defer { try? handle.close() }
            var hash = SHA256()
            while let block = try handle.read(upToCount: 1024 * 1024), !block.isEmpty { hash.update(data: block) }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
                throw ModelStoreError.checksumMismatch(file.path)
            }
            let destination = staging.appendingPathComponent(file.path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: temporary, to: destination)
        }
        try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("verified.json"), options: .atomic)
        let destination = Self.directory(manifest)
        // An incomplete older directory never counts as installed.
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: staging, to: destination)
    }
}
