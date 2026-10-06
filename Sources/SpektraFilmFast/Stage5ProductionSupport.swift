import Foundation

extension AppModel {
    func prewarmRawDenoiseForLibrarySelection() {
        let ids = librarySelection.isEmpty ? Set(project.selectedImageID.map { [$0] } ?? []) : librarySelection
        let images = project.images.filter { ids.contains($0.id) && $0.look.raw.denoiseMode != .off }
        prewarmRawDenoise(images, label: "Selected")
    }

    func prewarmRawDenoiseForExportSet() {
        let images = project.images.filter { $0.selectedForExport && $0.look.raw.denoiseMode != .off }
        prewarmRawDenoise(images, label: "Export set")
    }

    private func prewarmRawDenoise(_ images: [ProjectImageRecord], label: String) {
        guard !isPreparingRawDenoise else { return }
        guard !images.isEmpty else { rawDenoiseStatus = "\(label): no RAW photos with denoise enabled"; return }
        isPreparingRawDenoise = true
        rawDenoiseStatus = "\(label): prewarming \(images.count) RAW photo\(images.count == 1 ? "" : "s")…"
        Task { [weak self] in
            guard let self else { return }
            let result = await rawDenoiseService.prewarm(images, maxConcurrent: 2)
            isPreparingRawDenoise = false
            let seconds = String(format: "%.1f", result.elapsed)
            rawDenoiseStatus = "\(label): \(result.prepared) ready · \(result.cacheHits) warm hits · \(result.failed) failed · \(seconds)s"
            refreshStage5CacheAccounting()
            if project.selectedImageID != nil { requestPreviewRefresh() }
        }
    }

    func refreshStage5CacheAccounting() {
        Task { [weak self] in
            guard let self else { return }
            let rawStats = await rawDenoiseService.stats()
            let aiRoot = Bundle.main.resourceURL?.appendingPathComponent("AIModels", isDirectory: true)
            let aiStats = Self.stage5DirectoryStats(aiRoot)
            let semantic = semanticMasks == nil ? "semantic RAM 0 active" : "semantic RAM active"
            cacheHealthStatus = "RawForge \(rawStats.formatted) · AI models \(aiStats.formatted) · \(semantic) · render cache separate"
        }
    }

    private static func stage5DirectoryStats(_ root: URL?) -> RawForgeCacheStats {
        guard let root else { return .init() }
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { return .init() }
        var out = RawForgeCacheStats()
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
            out.files += 1; out.bytes += Int64(v.fileSize ?? 0)
        }
        return out
    }
}
