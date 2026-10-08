import Foundation

/// Originals are session scratch, never project/catalog truth. Only an explicitly chosen
/// non-internal volume is accepted; a disconnected drive is a hard error, not a fallback.
actor ExternalOriginalScratch {
    static let shared = ExternalOriginalScratch()

    enum ScratchError: LocalizedError {
        case notConfigured, internalVolume, unavailable(String), missingOriginal(String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: "Choose an external scratch drive in iCloud Library before editing or exporting cloud originals."
            case .internalVolume: "Scratch originals require a mounted external or network volume. The internal startup disk is not allowed."
            case .unavailable(let path): "Scratch drive is unavailable or not writable: \(path). Reconnect it and retry."
            case .missingOriginal(let path): "Cloud original is unavailable: \(path)"
            }
        }
    }

    private var staged: [UUID: URL] = [:]
    private var editPhotoID: UUID?
    private var exportHolds: [UUID: Int] = [:]
    private var roots: Set<URL> = []

    /// Calling this does not create files; the parent is checked again before every write.
    static func validatedRoot(_ parent: URL) throws -> URL {
        let parent = parent.standardizedFileURL
        let fm = FileManager.default
        guard fm.fileExists(atPath: parent.path),
              let values = try? parent.resourceValues(forKeys: [
                .volumeIsInternalKey, .volumeIsLocalKey, .isUbiquitousItemKey
              ]), values.volumeIsInternal == false, values.isUbiquitousItem != true
        else { throw ScratchError.internalVolume }
        let root = parent.appendingPathComponent("SpektraFilm Studio Scratch", isDirectory: true)
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let probe = root.appendingPathComponent(".writable-\(UUID().uuidString)")
            guard fm.createFile(atPath: probe.path, contents: Data([1])) else {
                throw ScratchError.unavailable(parent.path)
            }
            try fm.removeItem(at: probe)
        } catch {
            throw ScratchError.unavailable(parent.path)
        }
        return root
    }

    func setEditing(_ id: UUID?) {
        editPhotoID = id
        pruneUnprotected()
    }

    func holdExport(_ id: UUID) {
        exportHolds[id, default: 0] += 1
    }

    func releaseExport(_ id: UUID) {
        let count = exportHolds[id, default: 0]
        if count <= 1 { exportHolds.removeValue(forKey: id) }
        else { exportHolds[id] = count - 1 }
        pruneUnprotected()
    }

    /// File Provider downloads will first materialize in iCloud's own managed local cache.
    /// This copy is then placed on the external scratch drive and the iCloud source evicted.
    /// Strict internal-disk-free transfer requires a separate direct-download cloud API.
    func stage(photoID: UUID, fileName: String, original: URL,
               relativePath: String, library: SpektraCloudLibrary, parent: URL) async throws -> URL {
        let root = try Self.validatedRoot(parent)
        roots.insert(root)
        let safeName = URL(fileURLWithPath: fileName).lastPathComponent
        let target = root.appendingPathComponent("Originals/\(photoID.uuidString)", isDirectory: true)
            .appendingPathComponent(safeName)
        if let old = staged[photoID], old != target {
            try? FileManager.default.removeItem(at: old.deletingLastPathComponent())
            staged.removeValue(forKey: photoID)
        }
        if FileManager.default.fileExists(atPath: target.path),
           let a = try? FileManager.default.attributesOfItem(atPath: target.path),
           (a[.size] as? NSNumber)?.int64Value ?? 0 > 0 {
            staged[photoID] = target
            return target
        }
        try Task.checkCancellation()
        try await library.requestDownload(relativePath: relativePath)
        guard FileManager.default.fileExists(atPath: original.path) else {
            throw ScratchError.missingOriginal(original.path)
        }
        try Task.checkCancellation()
        try SpektraCloudLibrary.streamCopy(from: original, to: target)
        staged[photoID] = target
        // Best effort only: File Provider can refuse eviction when Finder/another app pins it.
        try? await library.evict(relativePath: relativePath)
        return target
    }

    func forget(_ ids: Set<UUID>) {
        for id in ids where exportHolds[id] == nil && editPhotoID != id {
            remove(id)
        }
    }

    func clearUnused() { pruneUnprotected() }

    private func pruneUnprotected() {
        for id in Array(staged.keys) where editPhotoID != id && exportHolds[id] == nil {
            remove(id)
        }
    }

    private func remove(_ id: UUID) {
        guard let url = staged.removeValue(forKey: id) else { return }
        // Only delete the per-photo directory created by this actor, never the parent volume.
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
