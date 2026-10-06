import AppKit
import SwiftUI
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Combine
import Darwin

private struct ExportDecodedFrame: Sendable {
    let buffer: PixelBufferF32
    let decodeMs: Double
}

private struct PendingExportWrite {
    let index: Int
    let itemStarted: TimeInterval
    var timings: ExportItemTimings
    let task: Task<Double, Error>
}

private struct SourcePreviewKey: Hashable, Sendable {
    let path: String
    let width: Int
    let height: Int
    let raw: RawSettings
    let bypassImportTransform: Bool
}


enum LookCopyCategory: String, CaseIterable, Identifiable, Sendable {
    case whiteBalance = "White Balance / RAW"
    case exposure = "Exposure / Auto"
    case tone = "Tone / Curve"
    case colorDensity = "Color Density"
    case film = "Film / Print / Effects"
    case geometry = "Crop / Geometry"
    var id: String { rawValue }
}

struct LookCopyOptions: Equatable, Sendable {
    var whiteBalance = true
    var exposure = true
    var tone = true
    var colorDensity = true
    var film = true
    var geometry = true

    func enabled(_ category: LookCopyCategory) -> Bool {
        switch category {
        case .whiteBalance: whiteBalance
        case .exposure: exposure
        case .tone: tone
        case .colorDensity: colorDensity
        case .film: film
        case .geometry: geometry
        }
    }

    mutating func set(_ category: LookCopyCategory, _ enabled: Bool) {
        switch category {
        case .whiteBalance: whiteBalance = enabled
        case .exposure: exposure = enabled
        case .tone: tone = enabled
        case .colorDensity: colorDensity = enabled
        case .film: film = enabled
        case .geometry: geometry = enabled
        }
    }
}

private struct PreviewRenderRequest: Sendable {
    let generation: Int
    let imageID: UUID
    let url: URL
    let look: RenderLook
    let preferences: AppPreferences
    let cacheMemoryMode: PreviewCacheMemoryMode
    let interactive: Bool
    let useInteractiveRenderPolicy: Bool
    let changedParameter: String?
    let rawField: RawInteractiveField?
    let baselineRaw: RawSettings?
    let longEdgeOverride: Int?
    let fullResolutionRequest: Bool
    let cacheResult: Bool
    let reason: String
}

private struct RenderedFrameKey: Hashable {
    let imageID: UUID
    let sourceFingerprint: String
    let look: RenderLook
    let previewLongEdge: Int
    let fullResolution: Bool
    let bypassImportTransform: Bool
}

private struct CachedRenderedFrame {
    let rendered: CGImage
    let source: CGImage?
    let buffer: PixelBufferF32
    let quality: RenderedPreviewQuality
}

@MainActor
final class PreviewFrameState: ObservableObject {
    @Published var renderedPreview: CGImage?
    @Published var sourcePreview: CGImage?
    @Published var status = "Ready"
    @Published var isRendering = false
    @Published var diagnostics = RenderDiagnosticsView()
}

@MainActor
final class AppModel: ObservableObject {
    @Published var page: WorkspacePage = .library
    @Published var project = SpektraProjectDocument()
    @Published var projectURL: URL?
    let frameState = PreviewFrameState()
    var renderedPreview: CGImage? {
        get { frameState.renderedPreview }
        set { frameState.renderedPreview = newValue }
    }
    var sourcePreview: CGImage? {
        get { frameState.sourcePreview }
        set { frameState.sourcePreview = newValue }
    }
    @Published var analysisOverlay: CGImage?
    @Published var scopeTrace: CGImage?
    @Published var analysisMetrics = StudioAnalysisMetrics()
    var latestSkinMaskWidth = 0
    var latestSkinMaskHeight = 0
    var latestSkinMaskAlpha: [UInt8] = []
    var isRendering: Bool {
        get { frameState.isRendering }
        set { frameState.isRendering = newValue }
    }
    @Published var isAnalyzing = false
    @Published var isExporting = false
    @Published var exportProgress = 0.0
    @Published var exportFailures: [ExportFailure] = []
    @Published var activeExportJob: ExportJob?
    @Published var isStoppingExport = false
    @Published var exportCurrentFileName = ""
    var status: String {
        get { frameState.status }
        set { frameState.status = newValue }
    }
    @Published var showingBefore = false
    var diagnostics: RenderDiagnosticsView {
        get { frameState.diagnostics }
        set { frameState.diagnostics = newValue }
    }
    @Published var presetSearch = ""
    @Published var presetCategoryFilter = "All"
    @Published var isPresetSidebarVisible: Bool = {
        if UserDefaults.standard.object(forKey: "SpektraFilmFast.isPresetSidebarVisible") == nil { return true }
        return UserDefaults.standard.bool(forKey: "SpektraFilmFast.isPresetSidebarVisible")
    }() {
        didSet { UserDefaults.standard.set(isPresetSidebarVisible, forKey: "SpektraFilmFast.isPresetSidebarVisible") }
    }
    @Published var presets: [SpektraPreset] = []
    @Published var rendererAvailable = false
    @Published var rendererError: String?
    @Published var isProjectDirty = false
    @Published var cacheStatus = ""
    @Published var cacheRootPath = ""
    @Published var cacheLocationAvailable = true
    @Published var cacheDirectoryParentPath = UserDefaults.standard.string(forKey: "SpektraFilmFast.cacheDirectoryParentPath") ?? ""
    @Published var cacheMemoryMode: PreviewCacheMemoryMode = {
        guard let raw = UserDefaults.standard.string(forKey: "SpektraFilmFast.cacheMemoryMode"),
              let value = PreviewCacheMemoryMode(rawValue: raw) else { return .automatic }
        return value
    }()
    @Published var localDiskCacheGB: Int = {
        let stored = UserDefaults.standard.integer(forKey: "SpektraFilmFast.localDiskCacheGB")
        return stored == 0 ? 15 : min(100, max(2, stored))
    }()
    @Published var autoWhiteBalanceStatus = ""
    @Published var isSkinWhiteBalanceRunning = false
    @Published var skinWhiteBalanceStatus = ""
    @Published var diagnosticStatus = ""
    @Published var diagnosticsAreSettling = false
    @Published var whiteBalanceDisplayTemperature: Double = 5500
    @Published var whiteBalanceDisplayTint: Double = 0
    @Published var isResolvingWhiteBalanceReference = false
    private var whiteBalanceBaseTemperature: Double = 5500
    private var whiteBalanceBaseTint: Double = 0

    // Library / Cull workspace state lives outside the project document so browsing
    // filters do not dirty a project merely because the photographer changes views.
    @Published var libraryFilter: LibraryFilter = .all
    @Published var libraryFolderFilter: String? = nil
    @Published var librarySearch = ""
    @Published var libraryThumbnailSize: Double = 176
    @Published var librarySelection: Set<UUID> = []
    @Published var lookCopyOptions = LookCopyOptions()
    @Published var libraryAlbumFilter: UUID? = nil
    @Published var librarySmartCollectionFilter: UUID? = nil
    @Published var libraryPeopleGroupFilter: UUID? = nil
    @Published var isGroupingPeople = false
    @Published var peopleGroupingStatus = ""
    @Published var isIngesting = false
    @Published var ingestProgress = 0.0
    @Published var ingestStatus = ""
    @Published var hasRecoverableIngest = false
    @Published var collapsedCullStacks: Set<UUID> = []
    @Published var showBackgroundTasks = false
    var librarySelectionAnchor: UUID?
    @Published var isCullAnalyzing = false
    @Published var cullAnalysisProgress = 0.0

    // Alcedo-inspired scopes are deliberately decoupled from the render scheduler.
    // They analyze only the newest published working frame and can be throttled/cancelled
    // without ever delaying slider input or a Spektrafilm render.
    @Published var editorScopeImage: CGImage?
    @Published var isScopeAnalyzing = false
    @Published var isCropToolActive = false
    @Published var isGeometryAnalyzing = false
    @Published var proofGalleries: [ProofGallerySnapshot] = []
    @Published var selectedProofGalleryID: UUID?
    @Published var isGeneratingProofs = false
    @Published var proofGenerationProgress = 0.0
    @Published var proofStatus = "ProofDock ready"

    let decoder = ImageDecoder()
    private let analysisEngine = StudioAnalysisEngine()
    private let geometryAnalyzer = GeometryAutoAnalyzer()
    let scopeEngine = ScopeEngine()
    let cullEngine = CullEngine()
    let faceGroupingEngine = FaceGroupingEngine()
    let exportEngine = ExportEngine()
    let thumbnails = ThumbnailPipeline.shared
    private let metadataService = MediaMetadataService.shared
    private let xmpService = XMPService.shared
    private let renderedDiskCache = RenderedPreviewDiskCache.shared
    private let developedSourceDiskCache = DevelopedSourceDiskCache.shared
    let cullDiskCache = CullAnalysisDiskCache.shared
    private let recoveryStore = ProjectRecoveryStore.shared
    private var renderer: NativeRenderer?
    var exactRenderer: NativeRenderer?

    // Latest-render-wins scheduler: there can be one active render and exactly one
    // replaceable pending request. Slider motion never creates an unbounded queue.
    private var renderLoopTask: Task<Void, Never>?
    private var renderLoopID: UUID?
    private var pendingRenderRequest: PreviewRenderRequest?
    private var renderGeneration = 0
    private var refinementTask: Task<Void, Never>?
    private var refinementGeneration = 0

    private var analysisTask: Task<Void, Never>?
    private var analysisGeneration = 0
    private var lastInteractiveStudioAnalysisUptime = 0.0
    var scopeTask: Task<Void, Never>?
    var scopeGeneration = 0
    var lastScopeUpdateUptime = 0.0
    var cullTask: Task<Void, Never>?
    private var latestSourceBuffer: PixelBufferF32?
    private var latestSourceRaw: RawSettings?
    var latestRenderedBuffer: PixelBufferF32?
    private var latestRenderedLook: RenderLook?
    // Keep the last normal preview frame even after an explicit 100% render. Slider proxies must
    // never inherit a full-resolution buffer or one 100% inspection would make the next drag slow.
    private var latestWorkingRenderedBuffer: PixelBufferF32?
    private var latestWorkingFilmRenderedBuffer: PixelBufferF32?
    private var latestFilmRenderedBuffer: PixelBufferF32?
    private var latestWorkingRenderedLook: RenderLook?
    private var lastSourcePreviewKey: SourcePreviewKey?

    private var importHydrationTask: Task<Void, Never>?
    private var selectionPresentationTask: Task<Void, Never>?
    private var editorWarmupTask: Task<Void, Never>?
    private var selectionPresentationGeneration = 0
    private var renderedFrameCache: [RenderedFrameKey: CachedRenderedFrame] = [:]
    private var renderedFrameCacheOrder: [RenderedFrameKey] = []
    private var renderedFrameCacheBytes = 0
    private var memoryPressureConstrained = false
    private var configuredCacheMemoryMode: PreviewCacheMemoryMode?
    private var configuredDiskCacheGB: Int?
    private var configuredCacheDirectoryPath: String?

    private var copiedLook: RenderLook?
    private var undoStack: [RenderLook] = []
    private var redoStack: [RenderLook] = []
    private var activeEditBaseline: RenderLook?
    private var gestureWorkingLook: RenderLook?
    private var activeEditChangedParameter: String?
    private var gestureBaselineRenderedBuffer: PixelBufferF32?
    private var gestureSettleBaselineBuffer: PixelBufferF32?
    private var latestInteractiveBaseBuffer: PixelBufferF32?
    private var latestInteractiveBaseLook: RenderLook?
    private var interactiveBaselineTask: Task<Void, Never>?
    private var interactiveBaselineGeneration = 0
    private var interactiveProxyTask: Task<Void, Never>?
    private var interactiveProxyGeneration = 0
    private var autosaveTask: Task<Void, Never>?
    private var autosaveGeneration = 0
    var exportTask: Task<Void, Never>?
    var managedIngestTask: Task<Void, Never>?
    var peopleGroupingTask: Task<Void, Never>?
    var proofGenerationTask: Task<Void, Never>?
    var projectGeneration = 0
    private var projectChangeCancellable: AnyCancellable?
    private var cacheVolumeCancellables = Set<AnyCancellable>()
    private var suppressDirtyTracking = false
    private var memoryPressureMonitor: MemoryPressureMonitor?
    private var whiteBalanceReferenceTask: Task<Void, Never>?
    private var whiteBalanceReferenceGeneration = 0
    private var skinWhiteBalanceTask: Task<Void, Never>?
    private var skinWhiteBalanceGeneration = 0
    private var didCheckRecovery = false

    init() {
        do {
            // One exact native renderer is the source of truth for committed previews and export.
            // Responsiveness comes from latest-wins scheduling, decoded-source caches, adjusted
            // preview caches, and the transient pointer-rate proxy rather than a second renderer.
            let exact = try NativeRenderer(profile: .exact)
            exactRenderer = exact
            renderer = exact
            rendererAvailable = true
        } catch {
            rendererError = error.localizedDescription
            status = error.localizedDescription
        }
        project.migrateForV2()
        loadPresetLibrary()
        configureCaches()
        installCacheVolumeObservers()

        Task { [weak self] in
            guard let self else { return }
            await restoreExportJobIfNeeded()
            await refreshRecoverableIngestState()
        }

        projectChangeCancellable = $project.dropFirst().sink { [weak self] _ in
            guard let self, !self.suppressDirtyTracking else { return }
            self.projectDidChange()
        }
        memoryPressureMonitor = MemoryPressureMonitor { [weak self] event in
            let level: CachePressureLevel
            if event.contains(.critical) { level = .critical }
            else if event.contains(.warning) { level = .warning }
            else { level = .normal }
            Task { @MainActor [weak self] in
                self?.handleMemoryPressure(level)
            }
        }
    }

    private func installCacheVolumeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            center.publisher(for: name)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.configureCaches(force: true)
                    self.refreshCacheStatus()
                }
                .store(in: &cacheVolumeCancellables)
        }
    }

    var selectedIndex: Int? {
        guard let id = project.selectedImageID else { return nil }
        return project.images.firstIndex { $0.id == id }
    }

    var selectedImage: ProjectImageRecord? {
        guard let i = selectedIndex else { return nil }
        return project.images[i]
    }

    var selectedLook: RenderLook {
        if let gestureWorkingLook { return gestureWorkingLook }
        return selectedImage?.look ?? .defaults()
    }

    var isInteractiveEditActive: Bool {
        activeEditBaseline != nil
    }


    var visibleImages: [ProjectImageRecord] {
        let query = librarySearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let activeAlbumIDs = libraryAlbumFilter.flatMap { id in project.albums.first(where: { $0.id == id })?.imageIDs }
        let activeSmart = librarySmartCollectionFilter.flatMap { id in project.smartCollections.first(where: { $0.id == id }) }
        let activePeopleIDs = libraryPeopleGroupFilter.flatMap { id in project.peopleGroups.first(where: { $0.id == id })?.imageIDs }
        var values = project.images.filter { image in
            let ratingPass = project.filterRating == 0 || image.rating >= project.filterRating
            let flagPass = project.filterFlag == nil || image.flag == project.filterFlag
            let folderPass = libraryFolderFilter == nil || image.url.deletingLastPathComponent().path == libraryFolderFilter
            let libraryPass: Bool = {
                switch libraryFilter {
                case .all: return true
                case .picked: return image.flag == .picked
                case .clientPicks: return image.clientPicked
                case .rejected: return image.flag == .rejected
                case .unrated: return image.rating == 0
                case .fiveStar: return image.rating == 5
                case .needsReview: return image.cullAnalysis?.recommendation == .review
                case .exportQueued: return image.selectedForExport
                case .missing: return !FileManager.default.fileExists(atPath: image.sourcePath)
                }
            }()
            let searchPass: Bool = Self.matchesLibrarySearch(image, query: query)
            let albumPass = activeAlbumIDs == nil || activeAlbumIDs!.contains(image.id)
            let peoplePass = activePeopleIDs == nil || activePeopleIDs!.contains(image.id)
            let smartPass: Bool = {
                guard let smart = activeSmart else { return true }
                if smart.minimumRating > 0 && image.rating < smart.minimumRating { return false }
                if let flag = smart.flag, image.flag != flag { return false }
                if let label = smart.colorLabel, image.colorLabel != label { return false }
                if let recommendation = smart.cullRecommendation, image.cullAnalysis?.recommendation != recommendation { return false }
                let smartQuery = smart.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return Self.matchesLibrarySearch(image, query: smartQuery)
            }()
            return ratingPass && flagPass && folderPass && libraryPass && searchPass && albumPass && peoplePass && smartPass
        }
        switch project.sortMode {
        case .importDate: values.sort { $0.importedAt < $1.importedAt }
        case .fileName: values.sort { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        case .rating: values.sort { $0.rating > $1.rating }
        case .captureDate: values.sort { ($0.captureDate ?? $0.importedAt) < ($1.captureDate ?? $1.importedAt) }
        case .camera:
            values.sort { ($0.metadata?.cameraDisplay ?? "").localizedStandardCompare($1.metadata?.cameraDisplay ?? "") == .orderedAscending }
        case .lens:
            values.sort { ($0.metadata?.lensModel ?? "").localizedStandardCompare($1.metadata?.lensModel ?? "") == .orderedAscending }
        case .aiScore:
            values.sort { ($0.cullAnalysis?.score ?? -1) > ($1.cullAnalysis?.score ?? -1) }
        }
        return values
    }

    private static func matchesLibrarySearch(_ image: ProjectImageRecord, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        if image.fileName.lowercased().contains(query) { return true }
        if image.url.deletingLastPathComponent().lastPathComponent.lowercased().contains(query) { return true }
        if image.note?.lowercased().contains(query) == true { return true }
        if image.keywords?.contains(where: { $0.lowercased().contains(query) }) == true { return true }
        if image.metadata?.cameraDisplay.lowercased().contains(query) == true { return true }
        if image.metadata?.lensModel?.lowercased().contains(query) == true { return true }
        if let iso = image.metadata?.iso, "iso \(iso)".contains(query) || "\(iso)" == query { return true }
        if let focal = image.metadata?.focalLengthMM, "\(Int(focal.rounded()))mm".contains(query) { return true }
        return false
    }

    var libraryFolders: [String] {
        Array(Set(project.images.map { $0.url.deletingLastPathComponent().path }))
            .sorted { URL(fileURLWithPath: $0).lastPathComponent.localizedStandardCompare(URL(fileURLWithPath: $1).lastPathComponent) == .orderedAscending }
    }

    var cullComparisonImages: [ProjectImageRecord] {
        guard let selected = selectedImage else { return [] }
        let sorted = visibleImages
        guard let index = sorted.firstIndex(where: { $0.id == selected.id }) else { return [selected] }
        let lower = max(0, index - 3)
        let upper = min(sorted.count, index + 5)
        return Array(sorted[lower..<upper])
    }

    var presetCategories: [String] {
        ["All"] + Array(Set(presets.map(\.category))).sorted()
    }

    var filteredPresets: [SpektraPreset] {
        presets.filter { preset in
            (presetCategoryFilter == "All" || preset.category == presetCategoryFilter) &&
            (presetSearch.isEmpty || preset.name.localizedCaseInsensitiveContains(presetSearch))
        }
    }

    func newProject() {
        guard confirmDestructiveTransitionIfNeeded() else { return }
        invalidateRendering()
        autosaveTask?.cancel()
        suppressDirtyTracking = true
        project = SpektraProjectDocument()
        project.migrateForV2()
        suppressDirtyTracking = false
        project.workspaceMode = .project
        projectURL = nil
        renderedPreview = nil
        sourcePreview = nil
        latestSourceBuffer = nil
        latestRenderedBuffer = nil
        latestRenderedLook = nil
        latestWorkingRenderedBuffer = nil
        latestWorkingRenderedLook = nil
        lastSourcePreviewKey = nil
        selectionPresentationTask?.cancel()
        importHydrationTask?.cancel()
        clearStudioAnalysis()
        page = .library
        isProjectDirty = false
        Task { [recoveryStore] in await recoveryStore.clear() }
        status = "New project"
    }

    func standalonePhotoMode() {
        guard confirmDestructiveTransitionIfNeeded() else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .rawImage]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        invalidateRendering()
        project = SpektraProjectDocument()
        project.migrateForV2()
        project.workspaceMode = .standalone
        project.name = url.deletingPathExtension().lastPathComponent
        project.images = [Self.makeImageRecord(url: url)]
        project.selectedImageID = project.images[0].id
        projectURL = nil
        page = .edit
        isProjectDirty = true
        status = "Standalone photo mode"
        presentFastSelectionPreview(for: project.images[0])
        workspaceDidChange(.edit)
    }

    func importImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .rawImage]
        guard panel.runModal() == .OK else { return }
        addImages(urls: panel.urls)
    }

    /// Imports an entire shoot without asking the user to select thousands of files.
    /// Enumeration and type filtering happen off the main actor; adding records remains one
    /// project publication followed by the existing bounded thumbnail/metadata hydration path.
    func importFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.prompt = "Import Folder"
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        status = "Scanning \(folder.lastPathComponent)…"
        Task { [weak self] in
            guard let self else { return }
            let urls = await Task.detached(priority: .userInitiated) {
                Self.photoURLs(in: folder)
            }.value
            guard !Task.isCancelled else { return }
            if urls.isEmpty {
                status = "No supported photos found in \(folder.lastPathComponent)"
                return
            }
            addImages(urls: urls)
        }
    }

    private nonisolated static func photoURLs(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey, .contentTypeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var urls: [URL] = []
        urls.reserveCapacity(1024)
        for case let url as URL in enumerator {
            if Task.isCancelled { break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  values.isHidden != true else { continue }
            if let type = values.contentType,
               type.conforms(to: .image) || type.conforms(to: .rawImage) {
                urls.append(url)
                continue
            }
            // Some camera RAW extensions are not registered with UTType on every macOS release.
            // Accept the common families that Core Image/ImageIO can open, then let the decoder
            // reject a genuinely unsupported file later instead of silently omitting the shoot.
            if supportedPhotoExtensions.contains(url.pathExtension.lowercased()) {
                urls.append(url)
            }
        }
        return urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private nonisolated static let supportedPhotoExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "png", "heic", "heif", "tif", "tiff", "dng",
        "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf",
        "rw2", "rwl", "pef", "ptx", "3fr", "fff", "iiq", "mos", "mef", "mrw",
        "erf", "kdc", "dcr", "x3f", "raw", "srw", "bay", "cap", "eip"
    ]

    func addImages(urls: [URL]) {
        let existing = Set(project.images.map(\.sourcePath))
        let additions = urls.filter { !existing.contains($0.path) }.map { url -> ProjectImageRecord in
            var record = Self.makeImageRecord(url: url)
            record.look.normalizeForProOnly()
            return record
        }
        guard !additions.isEmpty else {
            status = "No new images to import"
            return
        }

        project.images.append(contentsOf: additions)
        status = "Imported \(additions.count) image\(additions.count == 1 ? "" : "s") · indexing in background"

        let imported = additions.map { ($0.id, $0.url) }
        startBackgroundImportHydration(imported)

        if project.selectedImageID == nil, let first = additions.first {
            selectImage(first.id, renderPreview: false)
        }
    }

    private func startBackgroundImportHydration(_ imported: [(UUID, URL)]) {
        importHydrationTask?.cancel()
        let urls = imported.map { $0.1 }
        let generation = projectGeneration
        var indexByID = Dictionary(uniqueKeysWithValues: project.images.indices.map { (project.images[$0].id, $0) })

        importHydrationTask = Task { [weak self] in
            guard let self else { return }
            async let thumbnailWarmup: Void = thumbnails.prefetch(urls: urls, maxPixels: [480, 1280])

            let batchSize = 32
            var offset = 0
            while offset < imported.count, !Task.isCancelled {
                guard generation == projectGeneration else { return }
                let end = min(imported.count, offset + batchSize)
                let batch = Array(imported[offset..<end])

                var results: [(UUID, PhotoMetadata?, XMPSidecarState?)] = []
                results.reserveCapacity(batch.count)
                await withTaskGroup(of: (UUID, PhotoMetadata?, XMPSidecarState?).self) { group in
                    for (id, url) in batch {
                        group.addTask { [metadataService, xmpService] in
                            if Task.isCancelled { return (id, nil, nil) }
                            async let metadata = metadataService.metadata(url: url)
                            async let xmp = xmpService.read(for: url)
                            return (id, await metadata, await xmp)
                        }
                    }
                    for await result in group {
                        if Task.isCancelled { break }
                        results.append(result)
                    }
                }

                guard !Task.isCancelled, generation == projectGeneration else { return }

                // Only touch records completed in this batch. The old path copied the entire
                // project and rescanned every image every 32 files, which scaled poorly on
                // multi-thousand-image weddings.
                for (id, metadata, xmp) in results {
                    let index: Int
                    if let known = indexByID[id],
                       known < project.images.count,
                       project.images[known].id == id {
                        index = known
                    } else if let found = project.images.firstIndex(where: { $0.id == id }) {
                        indexByID[id] = found
                        index = found
                    } else {
                        continue
                    }

                    var record = project.images[index]
                    var changed = false
                    if let metadata, record.metadata != metadata {
                        record.metadata = metadata
                        record.captureDate = metadata.captureDate
                        changed = true
                    }
                    if let xmp {
                        if let rating = xmp.rating, record.rating != rating {
                            record.rating = rating
                            changed = true
                        }
                        if let flag = xmp.flag, record.flag != flag {
                            record.flag = flag
                            changed = true
                        }
                        if let label = xmp.colorLabel, record.colorLabel != label {
                            record.colorLabel = label
                            changed = true
                        }
                    }
                    if changed { project.images[index] = record }
                }
                offset = end
            }

            _ = await thumbnailWarmup
            guard !Task.isCancelled, generation == projectGeneration else { return }
            if project.preferences.autoAnalyzeCull {
                analyzeForCull(ids: imported.map { $0.0 })
                status = "Import ready · thumbnails cached · Smart Cull started"
            } else if page == .library {
                status = "Import ready · \(imported.count) image\(imported.count == 1 ? "" : "s") cached"
            }
        }
    }

    /// Workspace transitions are explicit lifecycle events. Library/Cull never wake the
    /// expensive film renderer. Entering Edit restores an exact adjusted preview from RAM/SSD
    /// first and invokes the normal preview renderer only on a true cache miss.
    func workspaceDidChange(_ destination: WorkspacePage) {
        if page != destination { page = destination }
        switch destination {
        case .library, .cull, .proofs, .export:
            cancelIdleRefinement()
            // A render that was already in flight is obsolete once the user leaves Edit.
            // Cancel it so Library/Cull interaction always wins the device.
            renderGeneration += 1
            pendingRenderRequest = nil
            renderLoopTask?.cancel()
            renderLoopTask = nil
            renderLoopID = nil
            isRendering = false
            if destination != .edit {
                scopeTask?.cancel()
                isScopeAnalyzing = false
            }
            if destination == .proofs {
                Task { await refreshProofGalleries() }
            }
        case .edit:
            guard let image = selectedImage else {
                renderedPreview = nil
                sourcePreview = nil
                status = "Select a photo in Library or Cull"
                return
            }
            guard FileManager.default.fileExists(atPath: image.sourcePath) else {
                status = "Missing media · use Relink Missing Media…"
                return
            }
            presentFastSelectionPreview(for: image, renderOnMiss: true)
            refreshWhiteBalanceReference(for: image)
        }
    }

    func selectImage(_ id: UUID, renderPreview: Bool = true) {
        let changed = project.selectedImageID != id
        if changed {
            cancelPreviewForNavigation()
            gestureWorkingLook = nil
            activeEditBaseline = nil
            project.selectedImageID = id
            undoStack.removeAll()
            redoStack.removeAll()
            latestSourceBuffer = nil
            latestSourceRaw = nil
            latestRenderedBuffer = nil
            latestRenderedLook = nil
            latestWorkingRenderedBuffer = nil
            latestWorkingRenderedLook = nil
            latestInteractiveBaseBuffer = nil
            latestInteractiveBaseLook = nil
            gestureSettleBaselineBuffer = nil
            interactiveBaselineTask?.cancel()
            clearStudioAnalysis()
        }

        guard let image = selectedImage else { return }
        refreshWhiteBalanceReference(for: image)
        guard FileManager.default.fileExists(atPath: image.sourcePath) else {
            renderedPreview = nil
            sourcePreview = nil
            status = "Missing media · use Relink Missing Media…"
            return
        }
        if changed || renderedPreview == nil {
            presentFastSelectionPreview(for: image, renderOnMiss: renderPreview)
        } else if renderPreview {
            // The already-present frame may only be a Library thumbnail. Require a float working
            // buffer before treating it as edit-ready.
            if !restoreLatestWorkingStateFromMemoryCache(for: image) {
                presentFastSelectionPreview(for: image, renderOnMiss: true)
            }
        } else {
            warmEditorSourceAfterSelectionIdle(image)
        }
    }

    /// Library/Cull selection quietly develops only the selected photo after a short idle.
    /// Rapid navigation cancels older warmups, so a 2,000-photo shoot cannot create a RAW
    /// decode backlog. When the user enters Edit, the normal preview source is usually already
    /// resident and the first Spektrafilm frame can start immediately.
    private func warmEditorSourceAfterSelectionIdle(_ image: ProjectImageRecord) {
        editorWarmupTask?.cancel()
        let prefs = project.preferences
        let currentIndex = project.images.firstIndex(where: { $0.id == image.id })
        var candidates: [ProjectImageRecord] = [image]
        if let currentIndex {
            if currentIndex > 0 { candidates.append(project.images[currentIndex - 1]) }
            if currentIndex + 1 < project.images.count { candidates.append(project.images[currentIndex + 1]) }
        }
        let memoryMode = cacheMemoryMode
        editorWarmupTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(240))
                guard !Task.isCancelled, project.selectedImageID == image.id, page != .edit else { return }
                // Build the persistent linear workfile for the active photo and its nearest
                // neighbors. These are temporary cache files only; the originals stay untouched.
                await withTaskGroup(of: Void.self) { group in
                    for candidate in candidates {
                        group.addTask { [decoder] in
                            await decoder.prefetch(
                                url: candidate.url,
                                longEdge: max(prefs.workingFileLongEdge, prefs.previewLongEdge),
                                raw: candidate.look.raw,
                                bypassImportTransform: prefs.bypassImportTransform,
                                cacheMode: memoryMode
                            )
                        }
                    }
                }
            } catch {
                return
            }
        }
    }

    func presentFastSelectionPreview(for image: ProjectImageRecord, renderOnMiss: Bool = false) {
        selectionPresentationTask?.cancel()
        selectionPresentationGeneration += 1
        let generation = selectionPresentationGeneration
        let prefs = project.preferences
        let longEdge = prefs.previewLongEdge
        let key = RenderedFrameKey(
            imageID: image.id,
            sourceFingerprint: sourceFingerprint(for: image.url),
            look: image.look,
            previewLongEdge: longEdge,
            fullResolution: false,
            bypassImportTransform: prefs.bypassImportTransform
        )

        let memoryCached = renderedFrameCache[key]
        if let memoryCached {
            touchRenderedFrameCache(key)
            publishCachedRenderedFrame(memoryCached, look: image.look)
            status = memoryCached.quality == .accurate ? "RAM cache · exact preview" : "RAM cache · preview"
        } else {
            renderedPreview = nil
            sourcePreview = nil
            status = "Loading preview…"
        }

        let url = image.url
        selectionPresentationTask = Task { [weak self] in
            guard let self else { return }
            var adjustedHit = memoryCached != nil

            if memoryCached == nil,
               let disk = await renderedDiskCache.bestPreview(
                    url: url,
                    look: image.look,
                    longEdge: longEdge,
                    bypassImportTransform: prefs.bypassImportTransform
               ),
               !Task.isCancelled,
               generation == selectionPresentationGeneration,
               project.selectedImageID == image.id,
               let buffer = disk.payload.makePixelBuffer(),
               let cg = disk.payload.makeCGImage(colorSpace: OutputColorProfile.forLook(image.look).cgColorSpace) {
                let cached = CachedRenderedFrame(rendered: cg, source: nil, buffer: buffer, quality: disk.quality)
                publishCachedRenderedFrame(cached, look: image.look)
                cacheRenderedFrame(key: key, rendered: cg, source: nil, buffer: buffer, quality: disk.quality)
                status = disk.quality == .accurate ? "SSD cache · exact preview" : "SSD cache · preview"
                adjustedHit = true
            }

            // Source/Before presentation is independent from the adjusted cache. Loading this
            // lightweight embedded/cached thumbnail must never block edit readiness.
            if let payload = try? await thumbnails.thumbnail(url: url, maxPixel: 1280),
               !Task.isCancelled,
               generation == selectionPresentationGeneration,
               project.selectedImageID == image.id,
               let cg = payload.makeCGImage() {
                sourcePreview = cg
                if !adjustedHit, latestRenderedBuffer == nil {
                    renderedPreview = cg
                    status = "Thumbnail · building exact preview…"
                }
            }

            if adjustedHit {
                // Warm the developed source independently for RAW-dependent accurate work. A valid
                // adjusted float cache hit is already fully editable and must not invoke Spektrafilm.
                warmEditorSourceAfterCacheHit(image)
                return
            }

            guard renderOnMiss,
                  !Task.isCancelled,
                  generation == selectionPresentationGeneration,
                  project.selectedImageID == image.id,
                  page == .edit else { return }
            scheduleRender(
                interactive: false,
                longEdgeOverride: longEdge,
                fullResolutionRequest: false,
                cacheResult: true,
                reason: "cache miss · exact preview",
                useInteractiveRenderPolicy: false
            )
        }
    }

    private func publishCachedRenderedFrame(_ cached: CachedRenderedFrame, look: RenderLook) {
        renderedPreview = cached.rendered
        sourcePreview = cached.source
        latestRenderedBuffer = cached.buffer
        latestRenderedLook = look
        latestWorkingRenderedBuffer = cached.buffer
        latestWorkingRenderedLook = look
        prepareInteractiveBaseline(from: cached.buffer, look: look)
        refreshStudioAnalysis(interactive: false)
        requestEditorScopeUpdate()
    }

    @discardableResult
    private func restoreLatestWorkingStateFromMemoryCache(for image: ProjectImageRecord) -> Bool {
        let prefs = project.preferences
        let key = RenderedFrameKey(
            imageID: image.id,
            sourceFingerprint: sourceFingerprint(for: image.url),
            look: image.look,
            previewLongEdge: prefs.previewLongEdge,
            fullResolution: false,
            bypassImportTransform: prefs.bypassImportTransform
        )
        guard let cached = renderedFrameCache[key] else { return false }
        touchRenderedFrameCache(key)
        publishCachedRenderedFrame(cached, look: image.look)
        return true
    }

    private func warmEditorSourceAfterCacheHit(_ image: ProjectImageRecord) {
        editorWarmupTask?.cancel()
        let prefs = project.preferences
        let imageID = image.id
        editorWarmupTask = Task { [weak self] in
            guard let self else { return }
            guard let source = try? await decoder.decode(
                url: image.url,
                longEdge: prefs.previewLongEdge,
                raw: image.look.raw,
                bypassImportTransform: prefs.bypassImportTransform,
                cacheMode: cacheMemoryMode
            ) else { return }
            guard !Task.isCancelled, project.selectedImageID == imageID else { return }
            latestSourceBuffer = source
            latestSourceRaw = image.look.raw
        }
    }

    func selectRelative(_ delta: Int, renderPreview: Bool? = nil) {
        guard !visibleImages.isEmpty else { return }
        let ids = visibleImages.map(\.id)
        let current = project.selectedImageID.flatMap { ids.firstIndex(of: $0) } ?? 0
        let next = max(0, min(ids.count - 1, current + delta))
        selectImage(ids[next], renderPreview: renderPreview ?? (page == .edit))
    }

    func setRating(_ rating: Int) {
        mutateSelected { $0.rating = max(0, min(5, rating)) }
        writeSelectedXMPIfEnabled()
        if project.preferences.autoAdvanceRatings { selectRelative(1) }
    }

    func setFlag(_ flag: ProjectFlag) {
        mutateSelected { $0.flag = flag }
        writeSelectedXMPIfEnabled()
        if project.preferences.autoAdvanceRatings { selectRelative(1) }
    }

    private func writeSelectedXMPIfEnabled() {
        guard project.preferences.writeXMPAutomatically, let image = selectedImage else { return }
        Task.detached(priority: .utility) { [xmpService] in
            try? await xmpService.write(image: image)
        }
    }

    func toggleExportSelection(_ id: UUID) {
        guard let i = project.images.firstIndex(where: { $0.id == id }) else { return }
        project.images[i].selectedForExport.toggle()
    }

    // MARK: - Edit gestures

    func beginEditGesture() {
        cancelIdleRefinement()
        if project.preferences.fullResolutionPreview { project.preferences.fullResolutionPreview = false }
        invalidateNativePreviewForInteraction()
        guard let i = selectedIndex else { return }
        if activeEditBaseline == nil {
            activeEditBaseline = project.images[i].look
            gestureWorkingLook = project.images[i].look
            activeEditChangedParameter = nil
            // Freeze the last native frame for the whole gesture. Pointer-rate previews are
            // derived from this immutable frame so a slow/stale native render can never become
            // the next slider sample's input.
            // Keep two immutable gesture baselines: a small pointer-rate proxy and the latest
            // committed exact preview. Mouse movement never touches the spectral renderer; when
            // the gesture ends the normal exact preview is scheduled through the latest-wins queue.
            gestureSettleBaselineBuffer = latestWorkingRenderedBuffer ?? latestRenderedBuffer
            if latestInteractiveBaseLook == project.images[i].look, let proxyBase = latestInteractiveBaseBuffer {
                gestureBaselineRenderedBuffer = proxyBase
            } else {
                gestureBaselineRenderedBuffer = gestureSettleBaselineBuffer
            }
        }
    }

    func endEditGesture() {
        guard let i = selectedIndex else {
            activeEditBaseline = nil
            gestureWorkingLook = nil
            activeEditChangedParameter = nil
            gestureBaselineRenderedBuffer = nil
            gestureSettleBaselineBuffer = nil
            return
        }

        let baselineLook = activeEditBaseline
        var committedLook = gestureWorkingLook ?? project.images[i].look
        committedLook.normalizeForProOnly()
        let settledParameter = activeEditChangedParameter
        let rawField: RawInteractiveField?
        switch settledParameter {
        case "rawTemperature": rawField = .temperature
        case "rawTint": rawField = .tint
        default: rawField = nil
        }

        if let baselineLook, baselineLook != committedLook {
            undoStack.append(baselineLook)
            redoStack.removeAll()
            project.images[i].look = committedLook
            propagateBatchEdit(from: committedLook, activeIndex: i, changedParameter: settledParameter)
            status = batchEditIDs.count > 1
                ? "Edit committed to \(batchEditIDs.count) photos · rendering exact preview…"
                : "Edit committed · rendering exact preview…"
        }

        activeEditBaseline = nil
        gestureWorkingLook = nil
        activeEditChangedParameter = nil
        gestureBaselineRenderedBuffer = nil
        gestureSettleBaselineBuffer = nil
        interactiveProxyTask?.cancel()
        interactiveProxyTask = nil

        guard let baselineLook, baselineLook != committedLook else { return }
        scheduleIdleRefinement(
            baselineRaw: rawField == nil ? nil : baselineLook.raw,
            rawField: rawField,
            changedParameter: settledParameter,
            delayMilliseconds: 80
        )
    }

    func setParameter(_ name: String, value: ParameterValue, interactive: Bool) {
        guard let i = selectedIndex else { return }
        if interactive {
            if gestureWorkingLook == nil { beginEditGesture() }
            gestureWorkingLook?.values[name] = value
            activeEditChangedParameter = name
            // Pointer-rate work is display-only. Do not enqueue the spectral renderer here.
            // Mouse-up/idle schedules one exact render from the committed settings.
            publishInteractiveProxy(changedParameter: name, rawField: nil)
            return
        }

        cancelIdleRefinement()
        if activeEditBaseline == nil {
            undoStack.append(project.images[i].look)
            redoStack.removeAll()
        }
        project.images[i].look.values[name] = value
        project.images[i].look.normalizeForProOnly()
        propagateBatchEdit(from: project.images[i].look, activeIndex: i, changedParameter: name)
        scheduleIdleRefinement(changedParameter: name)
    }

    func refreshWhiteBalanceReference(for imageOverride: ProjectImageRecord? = nil) {
        guard let image = imageOverride ?? selectedImage else { return }
        let raw = image.look.raw
        whiteBalanceReferenceTask?.cancel()
        whiteBalanceReferenceGeneration += 1
        let generation = whiteBalanceReferenceGeneration

        if raw.whiteBalanceMode == .custom {
            whiteBalanceBaseTemperature = PixelBufferF32.clampedKelvin(raw.temperature)
            whiteBalanceBaseTint = raw.tint
            whiteBalanceDisplayTemperature = whiteBalanceBaseTemperature
            whiteBalanceDisplayTint = raw.tint
            isResolvingWhiteBalanceReference = false
            return
        }

        isResolvingWhiteBalanceReference = true
        whiteBalanceReferenceTask = Task { [weak self] in
            guard let self else { return }
            let reference = await decoder.whiteBalanceReference(url: image.url, raw: raw)
            guard !Task.isCancelled,
                  generation == whiteBalanceReferenceGeneration,
                  project.selectedImageID == image.id else { return }
            let baseTemperature = PixelBufferF32.clampedKelvin(reference.temperature)
            let baseTint = reference.tint.isFinite ? reference.tint : 0
            whiteBalanceBaseTemperature = baseTemperature
            whiteBalanceBaseTint = baseTint
            whiteBalanceDisplayTemperature = PixelBufferF32.kelvin(
                baseKelvin: baseTemperature,
                miredOffset: raw.temperatureOffsetMired ?? 0
            )
            whiteBalanceDisplayTint = baseTint + (raw.tintOffset ?? 0)
            isResolvingWhiteBalanceReference = false
        }
    }

    func setWhiteBalanceMode(_ mode: RawWhiteBalanceMode) {
        guard let i = selectedIndex else { return }
        cancelIdleRefinement()
        let previous = project.images[i].look
        undoStack.append(previous)
        redoStack.removeAll()

        // Custom starts exactly where the image is currently balanced. As Shot and Auto
        // return to their native neutral, but their sliders remain visible and can grade
        // relative to that neutral without silently switching modes.
        if mode == .custom {
            project.images[i].look.raw.whiteBalanceMode = .custom
            project.images[i].look.raw.temperature = PixelBufferF32.clampedKelvin(whiteBalanceDisplayTemperature)
            project.images[i].look.raw.tint = whiteBalanceDisplayTint
            project.images[i].look.raw.temperatureOffsetMired = nil
            project.images[i].look.raw.tintOffset = nil
            whiteBalanceBaseTemperature = project.images[i].look.raw.temperature
            whiteBalanceBaseTint = project.images[i].look.raw.tint
            autoWhiteBalanceStatus = ""
            refreshWhiteBalanceReference(for: project.images[i])
            scheduleRender(
                interactive: false,
                longEdgeOverride: project.preferences.previewLongEdge,
                fullResolutionRequest: false,
                cacheResult: true,
                reason: "Custom WB preview",
                useInteractiveRenderPolicy: false
            )
            return
        }

        project.images[i].look.raw.whiteBalanceMode = mode
        project.images[i].look.raw.temperatureOffsetMired = nil
        project.images[i].look.raw.tintOffset = nil
        let image = project.images[i]
        isResolvingWhiteBalanceReference = true

        Task { [weak self] in
            guard let self else { return }
            if mode == .auto {
                await decoder.invalidateAutoWhiteBalance(url: image.url)
                await renderedDiskCache.invalidate(url: image.url)
                removeRenderedFrames(for: image.id)
                let resolution = await decoder.autoWhiteBalanceResolution(
                    url: image.url,
                    lensCorrection: image.look.raw.lensCorrection
                )
                guard project.selectedImageID == image.id else { return }
                autoWhiteBalanceStatus = resolution.method == .cameraNeutral
                    ? "Auto WB · camera-space neutral detected"
                    : "Auto WB · robust working-space fallback"
            } else {
                autoWhiteBalanceStatus = ""
            }

            guard project.selectedImageID == image.id else { return }
            let current = project.images[i]
            let reference = await decoder.whiteBalanceReference(url: current.url, raw: current.look.raw)
            guard project.selectedImageID == image.id else { return }
            whiteBalanceBaseTemperature = PixelBufferF32.clampedKelvin(reference.temperature)
            whiteBalanceBaseTint = reference.tint.isFinite ? reference.tint : 0
            whiteBalanceDisplayTemperature = whiteBalanceBaseTemperature
            whiteBalanceDisplayTint = whiteBalanceBaseTint
            isResolvingWhiteBalanceReference = false
            scheduleRender(
                interactive: false,
                longEdgeOverride: project.preferences.previewLongEdge,
                fullResolutionRequest: false,
                cacheResult: true,
                reason: mode == .auto ? "Auto WB preview" : "As Shot WB preview",
                useInteractiveRenderPolicy: false
            )
        }
    }

    func applyWhiteBalancePreset(baseMode: RawWhiteBalanceMode, preset: WhiteBalanceQuickPreset) {
        guard baseMode != .custom, let i = selectedIndex else { return }
        cancelIdleRefinement()
        whiteBalanceReferenceTask?.cancel()
        whiteBalanceReferenceGeneration += 1
        let generation = whiteBalanceReferenceGeneration

        let previous = project.images[i].look
        undoStack.append(previous)
        redoStack.removeAll()

        project.images[i].look.raw.whiteBalanceMode = baseMode
        project.images[i].look.raw.temperatureOffsetMired = abs(preset.temperatureOffsetMired) < 1.0e-9
            ? nil
            : preset.temperatureOffsetMired
        project.images[i].look.raw.tintOffset = abs(preset.tintOffset) < 1.0e-9
            ? nil
            : preset.tintOffset
        let image = project.images[i]
        isResolvingWhiteBalanceReference = true

        Task { [weak self] in
            guard let self else { return }
            if baseMode == .auto {
                // Reuse the image's cached Auto solution when available. Recalculate remains an
                // explicit user action so applying a quick preset never changes the Auto base
                // underneath the relative preset.
                let resolution = await decoder.autoWhiteBalanceResolution(
                    url: image.url,
                    lensCorrection: image.look.raw.lensCorrection
                )
                guard !Task.isCancelled,
                      generation == whiteBalanceReferenceGeneration,
                      project.selectedImageID == image.id else { return }
                autoWhiteBalanceStatus = resolution.method == .cameraNeutral
                    ? "Auto WB · camera-space neutral detected"
                    : "Auto WB · robust working-space fallback"
            } else {
                autoWhiteBalanceStatus = ""
            }

            guard !Task.isCancelled,
                  generation == whiteBalanceReferenceGeneration,
                  project.selectedImageID == image.id,
                  let current = selectedImage else { return }
            let reference = await decoder.whiteBalanceReference(url: current.url, raw: current.look.raw)
            guard !Task.isCancelled,
                  generation == whiteBalanceReferenceGeneration,
                  project.selectedImageID == image.id else { return }

            whiteBalanceBaseTemperature = PixelBufferF32.clampedKelvin(reference.temperature)
            whiteBalanceBaseTint = reference.tint.isFinite ? reference.tint : 0
            whiteBalanceDisplayTemperature = PixelBufferF32.kelvin(
                baseKelvin: whiteBalanceBaseTemperature,
                miredOffset: preset.temperatureOffsetMired
            )
            whiteBalanceDisplayTint = whiteBalanceBaseTint + preset.tintOffset
            isResolvingWhiteBalanceReference = false
            status = "WB preset · \(baseMode.rawValue) · \(preset.name)"
            scheduleRender(
                interactive: false,
                longEdgeOverride: project.preferences.previewLongEdge,
                fullResolutionRequest: false,
                cacheResult: true,
                reason: "relative WB preset",
                useInteractiveRenderPolicy: false
            )
        }
    }

    func recalculateAutoWhiteBalance() {
        guard let image = selectedImage, image.look.raw.whiteBalanceMode == .auto else { return }
        cancelIdleRefinement()
        isResolvingWhiteBalanceReference = true
        Task { [weak self] in
            guard let self else { return }
            await decoder.invalidateAutoWhiteBalance(url: image.url)
            await renderedDiskCache.invalidate(url: image.url)
            removeRenderedFrames(for: image.id)
            let resolution = await decoder.autoWhiteBalanceResolution(
                url: image.url,
                lensCorrection: image.look.raw.lensCorrection
            )
            guard project.selectedImageID == image.id, let current = selectedImage else { return }
            autoWhiteBalanceStatus = resolution.method == .cameraNeutral
                ? "Auto WB · camera-space neutral detected"
                : "Auto WB · robust working-space fallback"
            let reference = await decoder.whiteBalanceReference(url: current.url, raw: current.look.raw)
            guard project.selectedImageID == image.id else { return }
            whiteBalanceBaseTemperature = PixelBufferF32.clampedKelvin(reference.temperature)
            whiteBalanceBaseTint = reference.tint.isFinite ? reference.tint : 0
            whiteBalanceDisplayTemperature = PixelBufferF32.kelvin(
                baseKelvin: whiteBalanceBaseTemperature,
                miredOffset: current.look.raw.temperatureOffsetMired ?? 0
            )
            whiteBalanceDisplayTint = whiteBalanceBaseTint + (current.look.raw.tintOffset ?? 0)
            isResolvingWhiteBalanceReference = false
            scheduleRender(
                interactive: false,
                longEdgeOverride: project.preferences.previewLongEdge,
                fullResolutionRequest: false,
                cacheResult: true,
                reason: "recalculated Auto WB",
                useInteractiveRenderPolicy: false
            )
        }
    }

    func autoWhiteBalanceToSkin() {
        guard !isSkinWhiteBalanceRunning,
              let i = selectedIndex,
              let exactRenderer else { return }

        let image = project.images[i]
        let originalLook = image.look
        do {
            try SkinToneReference.validate(originalLook)
        } catch {
            skinWhiteBalanceStatus = error.localizedDescription
            status = "Skin WB unavailable · \(error.localizedDescription)"
            return
        }

        cancelIdleRefinement()
        invalidateNativePreviewForInteraction()
        skinWhiteBalanceTask?.cancel()
        skinWhiteBalanceGeneration += 1
        let generation = skinWhiteBalanceGeneration
        let imageID = image.id
        isSkinWhiteBalanceRunning = true
        isResolvingWhiteBalanceReference = true
        skinWhiteBalanceStatus = "Starting from As Shot…"
        status = "Skin WB · measuring As Shot skin…"

        skinWhiteBalanceTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == skinWhiteBalanceGeneration {
                    isSkinWhiteBalanceRunning = false
                    isResolvingWhiteBalanceReference = false
                    skinWhiteBalanceTask = nil
                }
            }

            do {
                var asShotRaw = originalLook.raw
                asShotRaw.whiteBalanceMode = .asShot
                asShotRaw.temperatureOffsetMired = nil
                asShotRaw.tintOffset = nil

                let reference = await decoder.whiteBalanceReference(url: image.url, raw: asShotRaw)
                try Task.checkCancellation()
                guard generation == skinWhiteBalanceGeneration,
                      project.selectedImageID == imageID else { throw CancellationError() }

                let solverEdge = min(720, max(480, project.preferences.previewLongEdge))

                let analyzer = StudioAnalysisEngine()
                var analysisPrefs = project.preferences
                analysisPrefs.clippingEnabled = false
                analysisPrefs.skinCheckEnabled = true
                analysisPrefs.skinCheckMode = .scope

                @MainActor func sample(mired: Double, tint: Double) async throws -> (Double, StudioAnalysisMetrics, RawSettings) {
                    try Task.checkCancellation()
                    guard generation == skinWhiteBalanceGeneration,
                          project.selectedImageID == imageID else { throw CancellationError() }

                    var raw = asShotRaw
                    raw.temperatureOffsetMired = abs(mired) < 1.0e-8 ? nil : max(-80, min(80, mired))
                    raw.tintOffset = abs(tint) < 1.0e-8 ? nil : max(-60, min(60, tint))

                    var look = originalLook
                    look.raw = raw

                    // Probe the same camera-space RAW development that will be
                    // committed. This avoids choosing a tint from the fast RGB
                    // pointer proxy and then snapping green/magenta on settle.
                    let exactLinear = try await decoder.decode(
                        url: image.url,
                        longEdge: solverEdge,
                        raw: raw,
                        bypassImportTransform: project.preferences.bypassImportTransform,
                        cacheMode: .conservative
                    )
                    let prepared = await Task.detached(priority: .userInitiated) {
                        exactLinear.applyingHostGrade(
                            tone: look.tone,
                            density: look.colorDensity
                        )
                    }.value
                    try Task.checkCancellation()
                    let (filmOutput, _) = try await exactRenderer.render(prepared, look: look)
                    try Task.checkCancellation()
                    let final = await Task.detached(priority: .utility) {
                        GeometryEngine.transformed(filmOutput, settings: look.geometry)
                    }.value
                    let payload = try await analyzer.analyze(
                        output: final,
                        look: look,
                        preferences: analysisPrefs,
                        maxLongEdge: 640
                    )
                    return (payload.metrics.skinMeanDeviationDegrees, payload.metrics, raw)
                }

                let baseline = try await sample(mired: 0, tint: 0)
                guard baseline.1.skinCandidatePercent >= 0.02,
                      baseline.1.skinMeasurementConfidencePercent >= 4.0 else {
                    throw NSError(
                        domain: "SpektraFilmFast.SkinWB",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey:
                            "No reliable skin sample was found. Skin WB left the photo unchanged."]
                    )
                }

                let startError = baseline.0
                if abs(startError) <= 1.5 {
                    skinWhiteBalanceStatus = "As Shot is already on the skin line (\(String(format: "%+.1f°", startError)))."
                    status = "Skin WB · As Shot already on target"
                    return
                }

                skinWhiteBalanceStatus = "Probing temperature and tint from As Shot…"
                let temperatureProbe = try await sample(mired: 12, tint: 0)
                let tintProbe = try await sample(mired: 0, tint: 8)

                let gTemp = temperatureProbe.0 - startError
                let gTint = tintProbe.0 - startError
                let denom = gTemp * gTemp + gTint * gTint
                guard denom > 0.01 else {
                    throw NSError(
                        domain: "SpektraFilmFast.SkinWB",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey:
                            "Skin direction was not responsive enough to white balance. No change was made."]
                    )
                }

                var best = baseline
                var bestMired = 0.0
                var bestTint = 0.0

                func consider(_ candidate: (Double, StudioAnalysisMetrics, RawSettings), mired: Double, tint: Double) {
                    let reliable = candidate.1.skinMeasurementConfidencePercent >= 3.0
                    if reliable && abs(candidate.0) < abs(best.0) {
                        best = candidate
                        bestMired = mired
                        bestTint = tint
                    }
                }

                consider(temperatureProbe, mired: 12, tint: 0)
                consider(tintProbe, mired: 0, tint: 8)

                let normalizedTemp = max(-3.5, min(3.5, -startError * gTemp / denom))
                let normalizedTint = max(-3.5, min(3.5, -startError * gTint / denom))
                let proposedMired = max(-80, min(80, normalizedTemp * 12))
                let proposedTint = max(-60, min(60, normalizedTint * 8))

                for fraction in [1.0, 0.65, 0.4] {
                    let mired = proposedMired * fraction
                    let tint = proposedTint * fraction
                    let candidate = try await sample(mired: mired, tint: tint)
                    consider(candidate, mired: mired, tint: tint)
                    if abs(best.0) <= 1.5 { break }
                }

                guard abs(best.0) + 0.5 < abs(startError) else {
                    throw NSError(
                        domain: "SpektraFilmFast.SkinWB",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey:
                            "A safer skin-based WB correction could not improve this frame. No change was made."]
                    )
                }

                try Task.checkCancellation()
                guard generation == skinWhiteBalanceGeneration,
                      project.selectedImageID == imageID,
                      let currentIndex = project.images.firstIndex(where: { $0.id == imageID }) else {
                    throw CancellationError()
                }

                undoStack.append(project.images[currentIndex].look)
                redoStack.removeAll()
                project.images[currentIndex].look.raw = best.2

                whiteBalanceBaseTemperature = PixelBufferF32.clampedKelvin(reference.temperature)
                whiteBalanceBaseTint = reference.tint.isFinite ? reference.tint : 0
                whiteBalanceDisplayTemperature = PixelBufferF32.kelvin(
                    baseKelvin: whiteBalanceBaseTemperature,
                    miredOffset: bestMired
                )
                whiteBalanceDisplayTint = whiteBalanceBaseTint + bestTint
                autoWhiteBalanceStatus = ""

                let tempDirection = bestMired < -0.5 ? "warmer" : (bestMired > 0.5 ? "cooler" : "same temp")
                let tintDirection = bestTint < -0.5 ? "toward green" : (bestTint > 0.5 ? "toward magenta" : "same tint")
                skinWhiteBalanceStatus = String(
                    format: "As Shot → %@, %@ · skin error %+.1f° → %+.1f°",
                    tempDirection, tintDirection, startError, best.0
                )
                status = "Skin WB applied · \(skinWhiteBalanceStatus)"
                scheduleRender(
                    interactive: false,
                    longEdgeOverride: project.preferences.previewLongEdge,
                    fullResolutionRequest: false,
                    cacheResult: true,
                    reason: "Skin WB exact preview",
                    useInteractiveRenderPolicy: false
                )
            } catch is CancellationError {
            } catch {
                skinWhiteBalanceStatus = error.localizedDescription
                status = "Skin WB · \(error.localizedDescription)"
            }
        }
    }

    func setWhiteBalanceTemperature(_ kelvin: Double, interactive: Bool) {
        let target = PixelBufferF32.clampedKelvin(kelvin)
        whiteBalanceDisplayTemperature = target
        setRawSettings({ raw in
            if raw.whiteBalanceMode == .custom {
                raw.temperature = target
            } else {
                raw.temperatureOffsetMired = PixelBufferF32.miredOffset(
                    baseKelvin: self.whiteBalanceBaseTemperature,
                    targetKelvin: target
                )
            }
        }, interactive: interactive, field: .temperature)
    }

    func setWhiteBalanceTint(_ tint: Double, interactive: Bool) {
        let target = min(150, max(-150, tint))
        whiteBalanceDisplayTint = target
        setRawSettings({ raw in
            if raw.whiteBalanceMode == .custom {
                raw.tint = target
            } else {
                raw.tintOffset = target - self.whiteBalanceBaseTint
            }
        }, interactive: interactive, field: .tint)
    }

    func setRawSettings(
        _ mutate: (inout RawSettings) -> Void,
        interactive: Bool,
        field: RawInteractiveField? = nil
    ) {
        guard let i = selectedIndex else { return }
        if interactive {
            if gestureWorkingLook == nil { beginEditGesture() }
            if var working = gestureWorkingLook {
                mutate(&working.raw)
                gestureWorkingLook = working
            }
            switch field {
            case .temperature: activeEditChangedParameter = "rawTemperature"
            case .tint: activeEditChangedParameter = "rawTint"
            case nil: activeEditChangedParameter = nil
            }

            // WB gets a lightweight visual approximation while the pointer is down.
            // Exact RAW/camera-space WB is rebuilt once the gesture settles.
            publishInteractiveProxy(changedParameter: activeEditChangedParameter, rawField: field)
            return
        }

        cancelIdleRefinement()
        if activeEditBaseline == nil {
            undoStack.append(project.images[i].look)
            redoStack.removeAll()
        }
        mutate(&project.images[i].look.raw)
        let batchParameter: String
        switch field {
        case .temperature: batchParameter = "rawTemperature"
        case .tint: batchParameter = "rawTint"
        case nil: batchParameter = "raw"
        }
        propagateBatchEdit(from: project.images[i].look, activeIndex: i, changedParameter: batchParameter)
        refreshWhiteBalanceReference(for: project.images[i])
        scheduleIdleRefinement()
    }

    func resetWhiteBalanceSliders() {
        guard let i = selectedIndex else { return }
        cancelIdleRefinement()
        undoStack.append(project.images[i].look)
        redoStack.removeAll()
        if project.images[i].look.raw.whiteBalanceMode == .custom {
            project.images[i].look.raw.temperature = whiteBalanceBaseTemperature
            project.images[i].look.raw.tint = whiteBalanceBaseTint
        } else {
            project.images[i].look.raw.temperatureOffsetMired = nil
            project.images[i].look.raw.tintOffset = nil
        }
        whiteBalanceDisplayTemperature = whiteBalanceBaseTemperature
        whiteBalanceDisplayTint = whiteBalanceBaseTint
        scheduleIdleRefinement(changedParameter: "whiteBalance", delayMilliseconds: 20)
    }

    func resetRawSection() {
        guard let i = selectedIndex else { return }
        cancelIdleRefinement()
        undoStack.append(project.images[i].look)
        redoStack.removeAll()
        project.images[i].look.raw = RawSettings()
        autoWhiteBalanceStatus = ""
        refreshWhiteBalanceReference(for: project.images[i])
        scheduleIdleRefinement(changedParameter: "raw", delayMilliseconds: 20)
    }

    func resetToneSection() {
        guard let i = selectedIndex else { return }
        cancelIdleRefinement()
        undoStack.append(project.images[i].look)
        redoStack.removeAll()
        project.images[i].look.tone = ToneSettings()
        status = "Exposure & Curves reset"
        scheduleIdleRefinement(changedParameter: "hostTone", delayMilliseconds: 20)
    }

    func resetParameter(_ name: String) {
        guard let descriptor = BridgeCatalog.shared.parameters.first(where: { $0.name == name }) else { return }
        setParameter(name, value: descriptor.defaultValue, interactive: false)
    }

    func resetParameterGroup(_ groupID: String) {
        guard let i = selectedIndex else { return }
        let descriptors = BridgeCatalog.shared.parameters(in: groupID, flavor: .pro)
        guard !descriptors.isEmpty else { return }
        cancelIdleRefinement()
        undoStack.append(project.images[i].look)
        redoStack.removeAll()
        for descriptor in descriptors {
            project.images[i].look.values[descriptor.name] = descriptor.defaultValue
        }
        status = "Section reset"
        scheduleIdleRefinement(changedParameter: groupID, delayMilliseconds: 20)
    }

    func setExposureEV(_ value: Double, interactive: Bool) {
        let target = min(10, max(-10, value))
        mutateTone(interactive: interactive, changedParameter: "hostExposure") { tone in
            tone.exposureEV = target
        }
    }

    func setAutoContrast(_ enabled: Bool) {
        mutateTone(interactive: false, changedParameter: "hostAutoContrast") {
            $0.autoContrast = enabled
        }
    }

    func setToneBrightness(_ value: Double, interactive: Bool) {
        mutateTone(interactive: interactive, changedParameter: "hostBrightness") { $0.brightness = min(100, max(-100, value)) }
    }

    func setToneContrast(_ value: Double, interactive: Bool) {
        mutateTone(interactive: interactive, changedParameter: "hostContrast") { $0.contrast = min(100, max(-100, value)) }
    }

    func setToneMidtones(_ value: Double, interactive: Bool) {
        mutateTone(interactive: interactive, changedParameter: "hostMidtones") { $0.midtones = min(100, max(-100, value)) }
    }

    func setToneHighlights(_ value: Double, interactive: Bool) {
        mutateTone(interactive: interactive, changedParameter: "hostHighlights") { $0.highlights = min(100, max(-100, value)) }
    }

    func setToneShadows(_ value: Double, interactive: Bool) {
        mutateTone(interactive: interactive, changedParameter: "hostShadows") { $0.shadows = min(100, max(-100, value)) }
    }

    func setHighlightRecovery(_ value: Double, interactive: Bool) {
        mutateTone(interactive: interactive, changedParameter: "hostHighlightRecovery") { $0.highlightRecovery = min(100, max(0, value)) }
    }

    func setShadowRecovery(_ value: Double, interactive: Bool) {
        mutateTone(interactive: interactive, changedParameter: "hostShadowRecovery") { $0.shadowRecovery = min(100, max(0, value)) }
    }

    func setToneWhites(_ value: Double, interactive: Bool) {
        mutateTone(interactive: interactive, changedParameter: "hostWhites") { $0.whites = min(100, max(-100, value)) }
    }

    func setToneBlacks(_ value: Double, interactive: Bool) {
        mutateTone(interactive: interactive, changedParameter: "hostBlacks") { $0.blacks = min(100, max(-100, value)) }
    }

    func setWhitePoint(_ value: Double, interactive: Bool) {
        mutateTone(interactive: interactive, changedParameter: "hostWhitePoint") { $0.whitePoint = min(100, max(-100, value)) }
    }

    func setBlackPoint(_ value: Double, interactive: Bool) {
        mutateTone(interactive: interactive, changedParameter: "hostBlackPoint") { $0.blackPoint = min(100, max(-100, value)) }
    }

    func setToneCurvePoints(_ points: [ToneCurvePoint], interactive: Bool) {
        let normalized = ToneCurveMath.normalize(points)
        mutateTone(interactive: interactive, changedParameter: "hostToneCurve") { tone in
            tone.curvePoints = normalized
        }
    }

    func applyToneCurvePreset(_ preset: ToneCurvePreset) {
        guard let i = selectedIndex else { return }
        cancelIdleRefinement()
        undoStack.append(project.images[i].look)
        redoStack.removeAll()
        if project.images[i].look.tone == nil { project.images[i].look.tone = ToneSettings() }
        project.images[i].look.tone?.curvePoints = preset.points
        status = "Curve preset · \(preset.rawValue)"
        scheduleIdleRefinement(changedParameter: "hostToneCurve", delayMilliseconds: 30)
    }

    func resetToneCurve() {
        applyToneCurvePreset(.linear)
    }

    private func mutateTone(
        interactive: Bool,
        changedParameter: String,
        _ mutate: (inout ToneSettings) -> Void
    ) {
        guard let i = selectedIndex else { return }
        if interactive {
            if gestureWorkingLook == nil { beginEditGesture() }
            guard var working = gestureWorkingLook else { return }
            var tone = working.tone ?? ToneSettings()
            mutate(&tone)
            working.tone = tone
            gestureWorkingLook = working
            activeEditChangedParameter = changedParameter
            // Immediate 1080p working-frame feedback; exact spectral work waits for settle.
            publishInteractiveProxy(changedParameter: changedParameter, rawField: nil)
            return
        }

        cancelIdleRefinement()
        if activeEditBaseline == nil {
            undoStack.append(project.images[i].look)
            redoStack.removeAll()
        }
        var tone = project.images[i].look.tone ?? ToneSettings()
        mutate(&tone)
        project.images[i].look.tone = tone
        propagateBatchEdit(from: project.images[i].look, activeIndex: i, changedParameter: changedParameter)
        scheduleIdleRefinement(changedParameter: changedParameter, delayMilliseconds: 30)
    }


    func setColorDensity(
        _ key: String,
        value: Double,
        interactive: Bool
    ) {
        guard let i = selectedIndex else { return }
        let clamped = min(1, max(-1, value))
        if interactive {
            if gestureWorkingLook == nil { beginEditGesture() }
            guard var working = gestureWorkingLook else { return }
            var density = working.colorDensity ?? ColorDensitySettings()
            switch key {
            case "master": density.master = clamped
            case "red": density.red = clamped
            case "yellow": density.yellow = clamped
            case "green": density.green = clamped
            case "cyan": density.cyan = clamped
            case "blue": density.blue = clamped
            case "magenta": density.magenta = clamped
            default: return
            }
            working.colorDensity = density
            gestureWorkingLook = working
            activeEditChangedParameter = "density.\(key)"
            publishInteractiveProxy(changedParameter: activeEditChangedParameter, rawField: nil)
            return
        }

        cancelIdleRefinement()
        if activeEditBaseline == nil {
            undoStack.append(project.images[i].look)
            redoStack.removeAll()
        }
        if project.images[i].look.colorDensity == nil { project.images[i].look.colorDensity = ColorDensitySettings() }
        switch key {
        case "master": project.images[i].look.colorDensity?.master = clamped
        case "red": project.images[i].look.colorDensity?.red = clamped
        case "yellow": project.images[i].look.colorDensity?.yellow = clamped
        case "green": project.images[i].look.colorDensity?.green = clamped
        case "cyan": project.images[i].look.colorDensity?.cyan = clamped
        case "blue": project.images[i].look.colorDensity?.blue = clamped
        case "magenta": project.images[i].look.colorDensity?.magenta = clamped
        default: return
        }
        propagateBatchEdit(
            from: project.images[i].look,
            activeIndex: i,
            changedParameter: "density.\(key)"
        )
        scheduleIdleRefinement(changedParameter: "density.\(key)", delayMilliseconds: 30)
    }

    func setColorDensityPreserveLuma(_ enabled: Bool) {
        guard let i = selectedIndex else { return }
        cancelIdleRefinement()
        undoStack.append(project.images[i].look)
        redoStack.removeAll()
        if project.images[i].look.colorDensity == nil { project.images[i].look.colorDensity = ColorDensitySettings() }
        project.images[i].look.colorDensity?.preserveLuma = enabled
        scheduleIdleRefinement(changedParameter: "density.preserveLuma", delayMilliseconds: 20)
    }

    func resetColorDensity() {
        guard let i = selectedIndex else { return }
        cancelIdleRefinement()
        undoStack.append(project.images[i].look)
        redoStack.removeAll()
        project.images[i].look.colorDensity = ColorDensitySettings()
        status = "Color Density reset"
        scheduleIdleRefinement(changedParameter: "density", delayMilliseconds: 20)
    }

    func setGeometrySettings(
        interactive: Bool,
        changedParameter: String = "geometry",
        _ mutate: (inout GeometrySettings) -> Void
    ) {
        guard let i = selectedIndex else { return }
        if interactive {
            if gestureWorkingLook == nil { beginEditGesture() }
            guard var working = gestureWorkingLook else { return }
            var geometry = working.geometry ?? GeometrySettings()
            mutate(&geometry)
            geometry.crop.clamp()
            working.geometry = geometry
            gestureWorkingLook = working
            activeEditChangedParameter = changedParameter
            if changedParameter == "crop" && isCropToolActive {
                // Crop-frame movement is overlay-only. Rebuilding/resampling the image while a
                // handle follows the pointer made the crop tool feel sticky and unstable.
                // Publish the lightweight model change immediately; the exact crop render happens
                // once at gesture end through the normal latest-wins refinement path.
                objectWillChange.send()
            } else {
                publishGeometryPreview(look: working)
            }
            return
        }

        cancelIdleRefinement()
        if activeEditBaseline == nil {
            undoStack.append(project.images[i].look)
            redoStack.removeAll()
        }
        var geometry = project.images[i].look.geometry ?? GeometrySettings()
        mutate(&geometry)
        geometry.crop.clamp()
        project.images[i].look.geometry = geometry
        propagateBatchEdit(
            from: project.images[i].look,
            activeIndex: i,
            changedParameter: changedParameter
        )
        if isCropToolActive {
            publishGeometryPreview(look: project.images[i].look)
        } else {
            scheduleIdleRefinement(changedParameter: changedParameter, delayMilliseconds: 20)
        }
    }

    func resetGeometry() {
        guard let i = selectedIndex else { return }
        cancelIdleRefinement()
        undoStack.append(project.images[i].look)
        redoStack.removeAll()
        project.images[i].look.geometry = GeometrySettings()
        status = "Crop & Geometry reset"
        scheduleIdleRefinement(changedParameter: "geometry", delayMilliseconds: 20)
    }

    func applyCropPreset(_ preset: CropAspectPreset) {
        guard let source = latestSourceBuffer else {
            setGeometrySettings(interactive: false) { $0.lastAspectPresetID = preset.id }
            return
        }
        setGeometrySettings(interactive: false, changedParameter: "crop") { geometry in
            GeometryEngine.applyAspectPreset(preset, sourceWidth: source.width, sourceHeight: source.height, to: &geometry)
        }
        status = "Crop · \(preset.label)"
    }

    func rotateCropQuarterTurn(clockwise: Bool) {
        setGeometrySettings(interactive: false, changedParameter: "geometryRotation") { geometry in
            geometry.rotationDegrees += clockwise ? 90 : -90
            while geometry.rotationDegrees > 180 { geometry.rotationDegrees -= 360 }
            while geometry.rotationDegrees < -180 { geometry.rotationDegrees += 360 }
        }
    }

    func autoGeometry(_ mode: GeometryAutoMode) {
        guard let image = sourcePreview ?? renderedPreview else {
            status = "No preview available for geometry analysis"
            return
        }
        isGeometryAnalyzing = true
        status = "Analyzing geometry · \(mode.rawValue)…"
        Task { [weak self] in
            guard let self else { return }
            do {
                var analyzed = try await geometryAnalyzer.analyze(cgImage: image, mode: mode)
                guard let i = selectedIndex else { return }
                let current = project.images[i].look.geometry ?? GeometrySettings()
                // Preserve the photographer's crop, offsets, flips, guide overlay, and auto-crop
                // while replacing only the correction fields requested by Upright-style Auto.
                analyzed.crop = current.crop
                analyzed.scale = current.scale
                analyzed.xOffset = current.xOffset
                analyzed.yOffset = current.yOffset
                analyzed.flipHorizontal = current.flipHorizontal
                analyzed.flipVertical = current.flipVertical
                analyzed.autoCrop = current.autoCrop
                analyzed.overlayGuide = current.overlayGuide
                analyzed.guides = current.guides
                analyzed.lastAspectPresetID = current.lastAspectPresetID
                undoStack.append(project.images[i].look)
                redoStack.removeAll()
                project.images[i].look.geometry = analyzed
                isGeometryAnalyzing = false
                status = "Geometry · \(mode.rawValue) applied"
                scheduleIdleRefinement(changedParameter: "geometry", delayMilliseconds: 10)
            } catch {
                isGeometryAnalyzing = false
                status = "Geometry analysis failed · \(error.localizedDescription)"
            }
        }
    }

    func setCropToolActive(_ active: Bool) {
        guard isCropToolActive != active else { return }
        isCropToolActive = active
        showingBefore = false
        if active {
            // Crop is edited against the complete post-film frame. The selected crop is drawn
            // as an overlay instead of baking it into the temporary viewer image.
            publishGeometryPreview(look: selectedLook)
            status = "Crop tool · drag the frame or its handles"
        } else {
            // Return to the exact committed crop through the normal preview path.
            scheduleIdleRefinement(changedParameter: "crop", delayMilliseconds: 0)
            status = "Crop committed"
        }
    }

    private func publishGeometryPreview(look: RenderLook) {
        guard let base = latestWorkingFilmRenderedBuffer ?? latestFilmRenderedBuffer else {
            objectWillChange.send()
            status = "Live geometry · waiting for working frame"
            return
        }
        interactiveProxyTask?.cancel()
        interactiveProxyGeneration += 1
        let generation = interactiveProxyGeneration
        var geometry = look.geometry ?? GeometrySettings()
        if isCropToolActive {
            // Show the complete transformed frame behind the crop overlay, but preserve the
            // Auto Fill zoom required by the photographer's actual crop so black wedges never
            // appear inside the active crop rectangle.
            if geometry.autoCrop {
                geometry.scale = max(
                    geometry.scale,
                    GeometryEngine.minimumScaleToCoverCrop(
                        settings: geometry,
                        width: base.width,
                        height: base.height
                    )
                )
            }
            geometry.crop = NormalizedCropRect()
            geometry.autoCrop = false
        }
        let displayGeometry: GeometrySettings? = geometry
        interactiveProxyTask = Task { [weak self] in
            let transformed = await Task.detached(priority: .userInitiated) {
                GeometryEngine.transformed(base, settings: displayGeometry)
            }.value
            guard let self, !Task.isCancelled, generation == interactiveProxyGeneration else { return }
            let profile = OutputColorProfile.forLook(look)
            let payload = await Task.detached(priority: .userInitiated) { transformed.makeFloatImagePayload() }.value
            guard !Task.isCancelled, generation == interactiveProxyGeneration else { return }
            renderedPreview = payload?.makeCGImage(colorSpace: profile.cgColorSpace)
                ?? transformed.makeCGImage8(colorSpace: profile.cgColorSpace)
            latestRenderedBuffer = transformed
            latestRenderedLook = look
            scheduleEditorScopeUpdate(force: false)
        }
    }

    private var batchEditIDs: Set<UUID> {
        guard let active = project.selectedImageID,
              librarySelection.count > 1,
              librarySelection.contains(active) else {
            return Set([project.selectedImageID].compactMap { $0 })
        }
        return librarySelection
    }

    func lookCopyCategoryEnabled(_ category: LookCopyCategory) -> Bool {
        lookCopyOptions.enabled(category)
    }

    func setLookCopyCategory(_ category: LookCopyCategory, enabled: Bool) {
        var options = lookCopyOptions
        options.set(category, enabled)
        lookCopyOptions = options
    }

    private func propagateBatchEdit(
        from source: RenderLook,
        activeIndex: Int,
        changedParameter: String?
    ) {
        let ids = batchEditIDs
        guard ids.count > 1 else { return }

        for index in project.images.indices
        where index != activeIndex && ids.contains(project.images[index].id) {
            var target = project.images[index].look
            target.normalizeForProOnly()

            switch changedParameter {
            case "rawTemperature", "rawTint", "whiteBalance", "raw":
                let keepLens = target.raw.lensCorrection
                target.raw = source.raw
                target.raw.lensCorrection = keepLens

            case "hostExposure", "hostBrightness", "hostContrast", "hostMidtones",
                 "hostHighlights", "hostShadows", "hostHighlightRecovery",
                 "hostShadowRecovery", "hostWhites", "hostBlacks",
                 "hostWhitePoint", "hostBlackPoint", "hostToneCurve", "hostAutoContrast":
                var t = target.tone ?? ToneSettings()
                let s = source.tone ?? ToneSettings()
                switch changedParameter {
                case "hostExposure": t.exposureEV = s.exposureEV
                case "hostBrightness": t.brightness = s.brightness
                case "hostContrast": t.contrast = s.contrast
                case "hostMidtones": t.midtones = s.midtones
                case "hostHighlights": t.highlights = s.highlights
                case "hostShadows": t.shadows = s.shadows
                case "hostHighlightRecovery": t.highlightRecovery = s.highlightRecovery
                case "hostShadowRecovery": t.shadowRecovery = s.shadowRecovery
                case "hostWhites": t.whites = s.whites
                case "hostBlacks": t.blacks = s.blacks
                case "hostWhitePoint": t.whitePoint = s.whitePoint
                case "hostBlackPoint": t.blackPoint = s.blackPoint
                case "hostToneCurve": t.curvePoints = s.curvePoints
                case "hostAutoContrast": t.autoContrast = s.autoContrast
                default: break
                }
                target.tone = t

            case let parameter? where parameter.hasPrefix("density."):
                var d = target.colorDensity ?? ColorDensitySettings()
                let s = source.colorDensity ?? ColorDensitySettings()
                switch parameter {
                case "density.master": d.master = s.master
                case "density.red": d.red = s.red
                case "density.yellow": d.yellow = s.yellow
                case "density.green": d.green = s.green
                case "density.cyan": d.cyan = s.cyan
                case "density.blue": d.blue = s.blue
                case "density.magenta": d.magenta = s.magenta
                case "density.preserveLuma": d.preserveLuma = s.preserveLuma
                default: break
                }
                target.colorDensity = d

            case "crop", "geometry", "geometryRotation", "geometryVertical",
                 "geometryHorizontal", "geometryAspect", "geometryScale",
                 "geometryXOffset", "geometryYOffset", "geometryAutoCrop",
                 "geometryFlipH", "geometryFlipV":
                target.geometry = source.geometry

            case let parameter?:
                if let value = source.values[parameter] {
                    target.values[parameter] = value
                }

            case nil:
                break
            }

            target.normalizeForProOnly()
            project.images[index].look = target
        }
    }

    private func mergedLookForPaste(source: RenderLook, target original: RenderLook) -> RenderLook {
        var source = source
        var target = original
        source.normalizeForProOnly()
        target.normalizeForProOnly()

        let exposureKeys: Set<String> = ["filmExposureEv", "autoExposure", "autoExposureMethod"]

        if lookCopyOptions.whiteBalance { target.raw = source.raw }

        if lookCopyOptions.film {
            for (key, value) in source.values where !exposureKeys.contains(key) {
                target.values[key] = value
            }
        }

        if lookCopyOptions.exposure {
            for key in exposureKeys {
                if let value = source.values[key] { target.values[key] = value }
            }
            var t = target.tone ?? ToneSettings()
            let s = source.tone ?? ToneSettings()
            t.exposureEV = s.exposureEV
            t.autoContrast = s.autoContrast
            target.tone = t
        }

        if lookCopyOptions.tone {
            let exposureEV = target.tone?.exposureEV ?? 0
            let autoContrast = target.tone?.autoContrast ?? false
            target.tone = source.tone
            if !lookCopyOptions.exposure {
                target.tone?.exposureEV = exposureEV
                target.tone?.autoContrast = autoContrast
            }
        }

        if lookCopyOptions.colorDensity { target.colorDensity = source.colorDensity }
        if lookCopyOptions.geometry { target.geometry = source.geometry }

        target.normalizeForProOnly()
        return target
    }

    func undo() {
        cancelIdleRefinement()
        guard let i = selectedIndex, let previous = undoStack.popLast() else { return }
        redoStack.append(project.images[i].look)
        project.images[i].look = previous
        project.images[i].look.normalizeForProOnly()
        scheduleIdleRefinement()
    }

    func redo() {
        cancelIdleRefinement()
        guard let i = selectedIndex, let next = redoStack.popLast() else { return }
        undoStack.append(project.images[i].look)
        project.images[i].look = next
        project.images[i].look.normalizeForProOnly()
        scheduleIdleRefinement()
    }

    func copyLook() {
        var copy = selectedLook
        copy.normalizeForProOnly()
        copiedLook = copy
        if let image = selectedImage {
            status = "Copied selected edit categories from \(image.fileName)"
        }
    }

    func pasteLook() {
        cancelIdleRefinement()
        guard var copiedLook, let activeIndex = selectedIndex else { return }
        copiedLook.normalizeForProOnly()

        let ids = batchEditIDs
        undoStack.append(project.images[activeIndex].look)
        redoStack.removeAll()

        var pastedCount = 0
        var autoWBTargets: [ProjectImageRecord] = []
        for index in project.images.indices where ids.contains(project.images[index].id) {
            let merged = mergedLookForPaste(source: copiedLook, target: project.images[index].look)
            project.images[index].look = merged
            pastedCount += 1
            if lookCopyOptions.whiteBalance, merged.raw.whiteBalanceMode == .auto {
                autoWBTargets.append(project.images[index])
            }
        }

        Task { [weak self] in
            guard let self else { return }
            for image in autoWBTargets {
                await decoder.invalidateAutoWhiteBalance(url: image.url)
            }
            for image in project.images where ids.contains(image.id) {
                await renderedDiskCache.invalidate(url: image.url)
                removeRenderedFrames(for: image.id)
            }
            if project.selectedImageID != nil {
                refreshWhiteBalanceReference()
                scheduleIdleRefinement(changedParameter: "paste")
            }
        }

        status = "Pasted selected edits to \(pastedCount) photo\(pastedCount == 1 ? "" : "s") · auto settings recalculate per photo"
    }

    func resetLook() {
        cancelIdleRefinement()
        guard let i = selectedIndex else { return }
        undoStack.append(project.images[i].look)
        redoStack.removeAll()
        project.images[i].look = .defaults()
        status = "All edits reset"
        scheduleIdleRefinement()
    }

    // MARK: - Latest-render-wins preview scheduler

    func scheduleRender(
        interactive: Bool,
        changedParameter: String? = nil,
        rawField: RawInteractiveField? = nil,
        longEdgeOverride: Int? = nil,
        fullResolutionRequest: Bool = false,
        cacheResult: Bool = true,
        reason: String = "preview",
        useInteractiveRenderPolicy: Bool = false,
        baselineRawOverride: RawSettings? = nil,
        lookOverride: RenderLook? = nil
    ) {
        guard let image = selectedImage, renderer != nil else { return }
        if interactive { cancelIdleRefinement() }
        renderGeneration += 1
        let request = PreviewRenderRequest(
            generation: renderGeneration,
            imageID: image.id,
            url: image.url,
            look: lookOverride ?? selectedLook,
            preferences: project.preferences,
            cacheMemoryMode: cacheMemoryMode,
            interactive: interactive,
            useInteractiveRenderPolicy: useInteractiveRenderPolicy,
            changedParameter: changedParameter,
            rawField: rawField,
            baselineRaw: baselineRawOverride ?? (interactive && rawField != nil ? activeEditBaseline?.raw : nil),
            longEdgeOverride: longEdgeOverride,
            fullResolutionRequest: fullResolutionRequest,
            cacheResult: cacheResult,
            reason: reason
        )
        pendingRenderRequest = request
        if renderLoopTask == nil { startRenderLoop() }
    }

    private func prepareInteractiveBaseline(from buffer: PixelBufferF32, look: RenderLook) {
        interactiveBaselineTask?.cancel()
        interactiveBaselineGeneration += 1
        let generation = interactiveBaselineGeneration
        let targetEdge = AppPreferences.editProxyLongEdge
        let imageID = project.selectedImageID
        interactiveBaselineTask = Task { [weak self] in
            guard let self else { return }
            let scaled = await Task.detached(priority: .userInitiated) {
                (try? buffer.resized(longEdge: targetEdge)) ?? buffer
            }.value
            guard !Task.isCancelled,
                  generation == interactiveBaselineGeneration,
                  project.selectedImageID == imageID,
                  selectedLook == look else { return }
            latestInteractiveBaseBuffer = scaled
            latestInteractiveBaseLook = look
        }
    }

    /// Pointer-rate feedback never enters the native spectral renderer. RapidRAW/Alcedo-style
    /// responsiveness comes from decoupling interaction from the expensive accuracy pass.
    private func publishInteractiveProxy(changedParameter: String?, rawField: RawInteractiveField?) {
        guard let baseline = gestureBaselineRenderedBuffer,
              let baselineLook = activeEditBaseline,
              let targetLook = gestureWorkingLook else {
            status = "Live edit · waiting for working frame"
            return
        }

        interactiveProxyTask?.cancel()
        interactiveProxyGeneration += 1
        let generation = interactiveProxyGeneration
        let imageID = project.selectedImageID
        let profile = OutputColorProfile.forLook(targetLook)

        interactiveProxyTask = Task { [weak self] in
            guard let self else { return }
            let worker = Task.detached(priority: .userInitiated) { () -> (PixelBufferF32, FloatImagePayload?) in
                let result = InteractivePreviewProxy.render(
                    baseline: baseline,
                    baselineLook: baselineLook,
                    targetLook: targetLook,
                    changedParameter: changedParameter,
                    rawField: rawField
                )
                guard !Task.isCancelled else { return (result, nil) }
                return (result, result.makeFloatImagePayload())
            }
            let (result, payload) = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, generation == interactiveProxyGeneration,
                  project.selectedImageID == imageID, gestureWorkingLook == targetLook else { return }
            guard let image = payload?.makeCGImage(colorSpace: profile.cgColorSpace) else { return }

            renderedPreview = image
            latestRenderedBuffer = result
            latestRenderedLook = targetLook
            // The committed exact preview buffer remains immutable for the duration of the
            // gesture. Otherwise a small transient proxy could become the next gesture's baseline
            // and quality would silently ratchet downward.
            status = "Live proxy · \(max(result.width, result.height)) px"
            if project.preferences.clippingEnabled || project.preferences.skinCheckEnabled {
                diagnosticsAreSettling = true
                diagnosticStatus = "Diagnostics update after the exact render settles"
                analysisTask?.cancel()
                analysisOverlay = nil
                scopeTask?.cancel()
            }
        }
    }

    /// Pointer-rate proxies are never persisted. They are display-only and are replaced by an
    /// exact normal-resolution preview as soon as the edit gesture settles.

    /// Discrete controls (menus, toggles, undo/redo) settle through the same exact normal-preview
    /// renderer used after slider gestures. The delay is cancellable so rapid input never queues
    /// a chain of expensive renders.
    private func schedulePreviewRenderAfterIdle(
        baselineRaw: RawSettings? = nil,
        rawField: RawInteractiveField? = nil,
        changedParameter: String? = nil,
        delayMilliseconds: Int = 110
    ) {
        cancelIdleRefinement()
        refinementGeneration += 1
        let generation = refinementGeneration
        refinementTask = Task { [weak self] in
            guard let self else { return }
            do {
                if delayMilliseconds > 0 { try await Task.sleep(for: .milliseconds(delayMilliseconds)) }
                guard !Task.isCancelled, generation == refinementGeneration, page == .edit else { return }
                scheduleRender(
                    interactive: false,
                    changedParameter: changedParameter,
                    rawField: rawField,
                    longEdgeOverride: project.preferences.previewLongEdge,
                    fullResolutionRequest: false,
                    cacheResult: true,
                    reason: "exact preview",
                    useInteractiveRenderPolicy: false,
                    baselineRawOverride: baselineRaw
                )
            } catch {
                return
            }
        }
    }

    private func scheduleIdleRefinement(
        baselineRaw: RawSettings? = nil,
        rawField: RawInteractiveField? = nil,
        changedParameter: String? = nil,
        delayMilliseconds: Int = 110
    ) {
        schedulePreviewRenderAfterIdle(
            baselineRaw: baselineRaw,
            rawField: rawField,
            changedParameter: changedParameter,
            delayMilliseconds: delayMilliseconds
        )
    }

    private func cancelIdleRefinement() {
        refinementGeneration += 1
        refinementTask?.cancel()
        refinementTask = nil
    }

    private func scheduleEditorScopeUpdate(force: Bool) {
        guard latestRenderedBuffer != nil else { return }
        requestEditorScopeUpdate()
    }

    func requestPreviewRefresh() {
        cancelIdleRefinement()
        project.preferences.fullResolutionPreview = false
        scheduleRender(
            interactive: false,
            longEdgeOverride: project.preferences.previewLongEdge,
            fullResolutionRequest: false,
            cacheResult: true,
            reason: "exact preview",
            useInteractiveRenderPolicy: false
        )
    }

    func requestFullResolutionPreview() {
        cancelIdleRefinement()
        project.preferences.fullResolutionPreview = true
        scheduleRender(
            interactive: false,
            fullResolutionRequest: true,
            cacheResult: false,
            reason: "explicit full-resolution preview"
        )
    }

    private func startRenderLoop() {
        guard renderLoopTask == nil, pendingRenderRequest != nil else { return }
        let loopID = UUID()
        renderLoopID = loopID
        renderLoopTask = Task { [weak self] in
            await self?.runRenderLoop(loopID: loopID)
        }
    }

    private func runRenderLoop(loopID: UUID) async {
        defer {
            if renderLoopID == loopID {
                renderLoopTask = nil
                renderLoopID = nil
                if pendingRenderRequest != nil { startRenderLoop() }
            }
        }

        while !Task.isCancelled, let request = pendingRenderRequest {
            pendingRenderRequest = nil

            if request.interactive {
                // One 60-Hz coalescing window. If a newer slider value arrives during
                // this window, discard this value without decoding or touching Metal.
                try? await Task.sleep(for: .milliseconds(16))
                if Task.isCancelled { break }
                if pendingRenderRequest != nil { continue }
            }

            let isFastPath = request.interactive || request.useInteractiveRenderPolicy
            isRendering = true
            status = request.interactive ? "Interactive preview…" : "Rendering \(request.reason)…"

            do {
                let requestStarted = ProcessInfo.processInfo.systemUptime
                let longEdge = request.longEdgeOverride ?? AppPreferences.editProxyLongEdge
                let useFull = !request.interactive && request.fullResolutionRequest
                let input: PixelBufferF32

                let decodeStarted = ProcessInfo.processInfo.systemUptime
                if isFastPath,
                   request.rawField != nil,
                   let baselineRaw = request.baselineRaw {
                    input = try await decoder.decodeInteractiveWhiteBalance(
                        url: request.url,
                        longEdge: longEdge,
                        baselineRaw: baselineRaw,
                        targetRaw: request.look.raw,
                        bypassImportTransform: request.preferences.bypassImportTransform,
                        cacheMode: request.cacheMemoryMode
                    )
                } else if useFull {
                    input = try await decoder.fullResolution(
                        url: request.url,
                        raw: request.look.raw,
                        bypassImportTransform: request.preferences.bypassImportTransform
                    )
                } else {
                    input = try await decoder.decode(
                        url: request.url,
                        longEdge: longEdge,
                        raw: request.look.raw,
                        bypassImportTransform: request.preferences.bypassImportTransform,
                        cacheMode: request.cacheMemoryMode
                    )
                }
                let decodeMs = (ProcessInfo.processInfo.systemUptime - decodeStarted) * 1000.0

                if Task.isCancelled { break }
                // Never spend a Metal render on an interactive value that already has a
                // newer replacement waiting.
                if request.interactive && pendingRenderRequest != nil { continue }
                guard let activeRenderer = exactRenderer ?? renderer else { break }
                let renderLook = isFastPath
                    ? InteractiveRenderPolicy.previewLook(
                        from: request.look,
                        changedParameter: request.changedParameter,
                        rawField: request.rawField
                    )
                    : request.look
                // Exposure + tone curve are a sourced host grade before the SpektraFilm engine.
                // Before/source preview remains the developed source, while preview/export share
                // the same host-grade -> native-render ordering.
                let renderInput = input.applyingHostGrade(tone: request.look.tone, density: request.look.colorDensity)
                let (filmOutput, d) = try await activeRenderer.render(renderInput, look: renderLook)
                if Task.isCancelled { break }
                // Geometry is deliberately post-render and color-neutral. Crop/straighten/keystone
                // therefore never changes SpektraFilm's spectral processing and can be previewed
                // independently from expensive film renders.
                let output = GeometryEngine.transformed(filmOutput, settings: request.look.geometry)
                if Task.isCancelled { break }

                guard request.generation == renderGeneration,
                      project.selectedImageID == request.imageID else { continue }

                let sourceKey = SourcePreviewKey(
                    path: request.url.path,
                    width: input.width,
                    height: input.height,
                    raw: request.look.raw,
                    bypassImportTransform: request.preferences.bypassImportTransform
                )

                guard request.generation == renderGeneration,
                      project.selectedImageID == request.imageID else { continue }

                var newSourcePreview = sourcePreview
                // Building another float CGImage is unnecessary work during normal slider
                // motion. Refresh Before only when it is visible or when the exact render settles.
                if (!isFastPath || showingBefore || sourcePreview == nil),
                   (sourcePreview == nil || sourceKey != lastSourcePreviewKey) {
                    let sourceForDisplay = GeometryEngine.transformed(input, settings: request.look.geometry)
                    let sourcePayload = await Task.detached(priority: .utility) {
                        sourceForDisplay.makeFloatImagePayload()
                    }.value
                    if Task.isCancelled { break }
                    guard request.generation == renderGeneration,
                          project.selectedImageID == request.imageID else { continue }
                    newSourcePreview = sourcePayload?.makeCGImage(colorSpace: OutputColorProfile.inputLinearRec2020)
                        ?? input.makeCGImage8(colorSpace: OutputColorProfile.inputLinearRec2020)
                    sourcePreview = newSourcePreview
                    lastSourcePreviewKey = sourceKey
                }

                let profile = OutputColorProfile.forLook(request.look)
                // The O(n) float-array -> Data copy is performed off the main actor. Keeping
                // this copy away from the event thread is critical for smooth pointer tracking.
                let renderedPayload = await Task.detached(priority: .userInitiated) {
                    output.makeFloatImagePayload()
                }.value
                if Task.isCancelled { break }
                guard request.generation == renderGeneration,
                      project.selectedImageID == request.imageID else { continue }
                guard let newRenderedPreview = renderedPayload?.makeCGImage(colorSpace: profile.cgColorSpace)
                        ?? output.makeCGImage8(colorSpace: profile.cgColorSpace) else {
                    throw RendererError.renderFailed("Could not create preview image")
                }
                renderedPreview = newRenderedPreview
                latestSourceBuffer = input
                latestSourceRaw = request.look.raw
                latestFilmRenderedBuffer = filmOutput
                latestRenderedBuffer = output
                latestRenderedLook = request.look
                if !useFull {
                    latestWorkingFilmRenderedBuffer = filmOutput
                    latestWorkingRenderedBuffer = output
                    latestWorkingRenderedLook = request.look
                    prepareInteractiveBaseline(from: output, look: request.look)
                }
                diagnostics = d

                if !request.interactive && request.cacheResult {
                    let quality: RenderedPreviewQuality = .accurate
                    cacheRenderedFrame(
                        key: RenderedFrameKey(
                            imageID: request.imageID,
                            sourceFingerprint: sourceFingerprint(for: request.url),
                            look: request.look,
                            previewLongEdge: longEdge,
                            fullResolution: useFull,
                            bypassImportTransform: request.preferences.bypassImportTransform
                        ),
                        rendered: newRenderedPreview,
                        source: nil,
                        buffer: output,
                        quality: quality
                    )
                    if !useFull, longEdge == request.preferences.previewLongEdge, let renderedPayload {
                        Task { [renderedDiskCache] in
                            await renderedDiskCache.store(
                                payload: renderedPayload,
                                url: request.url,
                                look: request.look,
                                longEdge: longEdge,
                                bypassImportTransform: request.preferences.bypassImportTransform,
                                quality: quality
                            )
                        }
                    }
                }

                let wallMs = (ProcessInfo.processInfo.systemUptime - requestStarted) * 1000.0
                if request.interactive {
                    // Adapt to actual pointer-to-frame work, not only native GPU time. WB
                    // preprocessing and display packaging are part of perceived latency too.
                    status = String(
                        format: "Live %.1f ms · decode/prep %.1f · GPU %.1f · %d passes",
                        wallMs, decodeMs, d.commandBufferMs, d.passCount
                    )
                } else {
                    status = String(
                        format: "Preview %.1f ms · decode %.1f · GPU %.1f · %d passes",
                        wallMs, decodeMs, d.commandBufferMs, d.passCount
                    )
                }
                refreshStudioAnalysis(interactive: isFastPath)
                requestEditorScopeUpdate()
            } catch is CancellationError {
                // Cancellation is expected when navigating or closing a project.
            } catch {
                if request.generation == renderGeneration { status = error.localizedDescription }
            }
        }

        if renderLoopID == loopID { isRendering = false }
    }

    /// A Metal command buffer may already be committed and cannot be preempted safely. Starting
    /// a new gesture therefore invalidates its generation immediately. The old work may finish on
    /// the device, but it can never publish over the current pointer-rate proxy frame.
    private func invalidateNativePreviewForInteraction() {
        renderGeneration += 1
        pendingRenderRequest = nil
        renderLoopTask?.cancel()
        renderLoopTask = nil
        renderLoopID = nil
        isRendering = false
    }

    private func cancelPreviewForNavigation() {
        cancelIdleRefinement()
        renderGeneration += 1
        pendingRenderRequest = nil
        renderLoopTask?.cancel()
        renderLoopTask = nil
        renderLoopID = nil
        isRendering = false
        selectionPresentationTask?.cancel()
        skinWhiteBalanceTask?.cancel()
        skinWhiteBalanceTask = nil
        skinWhiteBalanceGeneration += 1
        isSkinWhiteBalanceRunning = false
        interactiveProxyTask?.cancel()
        interactiveProxyTask = nil
        interactiveProxyGeneration += 1
        gestureBaselineRenderedBuffer = nil
    }

    private func invalidateRendering() {
        projectGeneration += 1
        cancelPreviewForNavigation()
        analysisTask?.cancel()
        importHydrationTask?.cancel()
        importHydrationTask = nil
        cullTask?.cancel()
        cullTask = nil
        peopleGroupingTask?.cancel()
        peopleGroupingTask = nil
        proofGenerationTask?.cancel()
        proofGenerationTask = nil
        managedIngestTask?.cancel()
        managedIngestTask = nil
        exportTask?.cancel()
        exportTask = nil
        isGroupingPeople = false
        isGeneratingProofs = false
        isIngesting = false
        isExporting = false
    }

    // MARK: - Studio diagnostics

    func setClippingEnabled(_ enabled: Bool) {
        project.preferences.clippingEnabled = enabled
        refreshStudioAnalysis()
    }

    func setClippingPreviewMode(_ mode: ClippingPreviewMode) {
        project.preferences.clippingPreviewMode = mode
        refreshStudioAnalysis()
    }

    func setSkinCheckEnabled(_ enabled: Bool) {
        project.preferences.skinCheckEnabled = enabled
        refreshStudioAnalysis()
    }

    func setSkinCheckMode(_ mode: SkinCheckMode) {
        project.preferences.skinCheckMode = mode
        refreshStudioAnalysis()
    }

    func setExposureHighlightRiskThreshold(_ value: Double) {
        project.preferences.exposureHighlightRiskThreshold = min(0.995, max(0.50, value))
        refreshStudioAnalysis()
    }

    func setExposureShadowRiskThreshold(_ value: Double) {
        project.preferences.exposureShadowRiskThreshold = min(0.25, max(0.001, value))
        refreshStudioAnalysis()
    }

    func setClippingHighlightThreshold(_ value: Double) {
        project.preferences.clippingHighlightThreshold = min(1.0, max(0.5, value))
        refreshStudioAnalysis()
    }

    func setClippingShadowThreshold(_ value: Double) {
        project.preferences.clippingShadowThreshold = min(0.5, max(0.0, value))
        refreshStudioAnalysis()
    }

    func setSkinTolerance(_ value: Double) {
        project.preferences.skinToleranceDegrees = min(45, max(1, value))
        refreshStudioAnalysis()
    }

    func setSkinOverlayOpacity(_ value: Double) {
        project.preferences.skinOverlayOpacity = min(0.85, max(0.05, value))
        refreshStudioAnalysis()
    }

    func refreshStudioAnalysis(interactive: Bool = false) {
        // Pointer-rate frames are approximate display proxies. Only the exact settled frame owns
        // clipping and skin measurements.
        if interactive { return }
        analysisTask?.cancel()
        analysisGeneration += 1
        let generation = analysisGeneration
        let prefs = project.preferences

        guard prefs.clippingEnabled || prefs.skinCheckEnabled || prefs.scopeMode == .skinVectorscope,
              let buffer = latestRenderedBuffer else {
            clearStudioAnalysis()
            return
        }

        isAnalyzing = true
        analysisTask = Task { [weak self] in
            guard let self else { return }
            do {
                let analysisLook = latestRenderedLook ?? selectedLook
                let payload = try await analysisEngine.analyze(
                    output: buffer,
                    look: analysisLook,
                    preferences: prefs,
                    maxLongEdge: interactive ? 480 : 1200
                )
                guard !Task.isCancelled, generation == analysisGeneration else { return }
                analysisOverlay = CGImage.fromRGBA8(width: payload.overlayWidth, height: payload.overlayHeight, bytes: payload.overlayRGBA)
                scopeTrace = payload.scopeWidth > 0
                    ? CGImage.fromRGBA8(width: payload.scopeWidth, height: payload.scopeHeight, bytes: payload.scopeRGBA)
                    : nil
                latestSkinMaskWidth = payload.skinMaskWidth
                latestSkinMaskHeight = payload.skinMaskHeight
                latestSkinMaskAlpha = payload.skinMaskAlpha
                analysisMetrics = payload.metrics
                diagnosticStatus = ""
                isAnalyzing = false
                requestEditorScopeUpdate()
            } catch {
                if generation == analysisGeneration {
                    isAnalyzing = false
                    analysisOverlay = nil
                    scopeTrace = nil
                    latestSkinMaskWidth = 0
                    latestSkinMaskHeight = 0
                    latestSkinMaskAlpha = []
                    analysisMetrics = StudioAnalysisMetrics()
                    diagnosticStatus = error.localizedDescription
                }
            }
        }
    }

    private func clearStudioAnalysis() {
        analysisTask?.cancel()
        analysisOverlay = nil
        scopeTrace = nil
        latestSkinMaskWidth = 0
        latestSkinMaskHeight = 0
        latestSkinMaskAlpha = []
        analysisMetrics = StudioAnalysisMetrics()
        isAnalyzing = false
    }

    private func sourceFingerprint(for url: URL) -> String {
        (try? CacheSourceFingerprint.value(for: url)) ?? url.standardizedFileURL.path
    }

    private func removeRenderedFrames(for imageID: UUID) {
        let keys = renderedFrameCache.keys.filter { $0.imageID == imageID }
        for key in keys { removeRenderedFrameCache(key) }
    }

    private func cacheRenderedFrame(
        key: RenderedFrameKey,
        rendered: CGImage,
        source: CGImage?,
        buffer: PixelBufferF32,
        quality: RenderedPreviewQuality
    ) {
        let staleKeys = renderedFrameCache.keys.filter { $0.imageID == key.imageID && $0 != key }
        for stale in staleKeys { removeRenderedFrameCache(stale) }
        if renderedFrameCache[key] != nil { removeRenderedFrameCache(key) }
        renderedFrameCache[key] = CachedRenderedFrame(rendered: rendered, source: source, buffer: buffer, quality: quality)
        renderedFrameCacheBytes += renderedFrameBytes(rendered: rendered, source: source, buffer: buffer)
        touchRenderedFrameCache(key)
        let normalBudget = CacheBudget.renderedFrameBytes(mode: cacheMemoryMode)
        let budget = memoryPressureConstrained ? min(normalBudget, CacheBudget.renderedFrameBytes(mode: .conservative)) : normalBudget
        trimRenderedFrameCache(to: budget)
    }

    private func renderedFrameBytes(rendered: CGImage, source: CGImage?, buffer: PixelBufferF32) -> Int {
        var bytes = rendered.bytesPerRow * rendered.height
        bytes += buffer.pixels.count * MemoryLayout<Float>.size
        if let source { bytes += source.bytesPerRow * source.height }
        return bytes
    }

    private func removeRenderedFrameCache(_ key: RenderedFrameKey) {
        if let frame = renderedFrameCache.removeValue(forKey: key) {
            renderedFrameCacheBytes -= renderedFrameBytes(rendered: frame.rendered, source: frame.source, buffer: frame.buffer)
        }
        renderedFrameCacheOrder.removeAll { $0 == key }
    }

    private func trimRenderedFrameCache(to budget: Int) {
        while renderedFrameCacheBytes > budget, let old = renderedFrameCacheOrder.first {
            removeRenderedFrameCache(old)
        }
    }

    private func touchRenderedFrameCache(_ key: RenderedFrameKey) {
        renderedFrameCacheOrder.removeAll { $0 == key }
        renderedFrameCacheOrder.append(key)
    }

    // MARK: - Reliability, autosave, cache, and media relink

    private func projectDidChange() {
        isProjectDirty = true
        configureCaches()
        scheduleAutosave()
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        guard project.preferences.autosaveEnabled else { return }

        autosaveGeneration += 1
        let generation = autosaveGeneration
        let imageCount = project.images.count
        let recoveryDelay = imageCount >= 2500 ? 2.8 : (imageCount >= 1000 ? 2.0 : 1.2)

        autosaveTask = Task { [weak self, recoveryStore] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(recoveryDelay))
                try Task.checkCancellation()
                guard generation == autosaveGeneration else { return }

                // Snapshot only after the debounce wins. Previously this value-type copy happened
                // immediately on every project mutation, including slider-driven changes.
                let snapshot = project
                let target = projectURL
                try await recoveryStore.save(project: snapshot, projectURL: target)

                if let target {
                    let namedDelay = imageCount >= 2500 ? 4.0 : 2.0
                    try await Task.sleep(for: .seconds(namedDelay))
                    try Task.checkCancellation()
                    guard generation == autosaveGeneration else { return }

                    try await Task.detached(priority: .utility) {
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        encoder.dateEncodingStrategy = .iso8601
                        let data = try encoder.encode(snapshot)
                        try data.write(to: target, options: .atomic)
                    }.value

                    guard !Task.isCancelled, generation == autosaveGeneration else { return }
                    isProjectDirty = false
                    await recoveryStore.clear()
                    status = "Autosaved"
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                status = "Autosave warning: \(error.localizedDescription)"
            }
        }
    }

    func promptForRecoveryIfAvailable() async {
        guard !didCheckRecovery else { return }
        didCheckRecovery = true
        guard let recovery = await recoveryStore.latest() else { return }
        // Ignore a recovery file that is older than the already-saved project it points to.
        if let path = recovery.originalProjectPath,
           let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let modified = attrs[.modificationDate] as? Date,
           modified >= recovery.savedAt {
            await recoveryStore.clear()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Recover unsaved SpektraFilm work?"
        alert.informativeText = "A recovery snapshot from \(recovery.savedAt.formatted()) was found. Recover it or discard the snapshot."
        alert.addButton(withTitle: "Recover")
        alert.addButton(withTitle: "Discard")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            invalidateRendering()
            suppressDirtyTracking = true
            project = recovery.project
            project.migrateForV2()
            suppressDirtyTracking = false
            if let path = recovery.originalProjectPath, FileManager.default.fileExists(atPath: path) {
                projectURL = URL(fileURLWithPath: path)
            } else {
                projectURL = nil
            }
            isProjectDirty = true
            page = project.images.isEmpty ? .library : .edit
            if project.selectedImageID == nil { project.selectedImageID = project.images.first?.id }
            if let image = selectedImage, FileManager.default.fileExists(atPath: image.sourcePath) {
                presentFastSelectionPreview(for: image)
                workspaceDidChange(.edit)
            }
            status = "Recovered unsaved work"
        } else {
            await recoveryStore.clear()
        }
    }

    func prepareForTermination() -> Bool {
        guard isProjectDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes before quitting?"
        alert.informativeText = "Unsaved changes are still in this SpektraFilm project."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveProject()
        case .alertSecondButtonReturn:
            return false
        default:
            ProjectRecoveryStore.clearSynchronously()
            return true
        }
    }

    private func confirmDestructiveTransitionIfNeeded() -> Bool {
        guard isProjectDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save the current project first?"
        alert.informativeText = "Opening or creating another project will replace the current workspace."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return saveProject()
        case .alertSecondButtonReturn: return false
        default:
            ProjectRecoveryStore.clearSynchronously()
            return true
        }
    }

    private func configureCaches(force: Bool = false) {
        let mode = cacheMemoryMode
        let diskGB = localDiskCacheGB
        let parentPath = cacheDirectoryParentPath
        guard force || configuredCacheMemoryMode != mode || configuredDiskCacheGB != diskGB || configuredCacheDirectoryPath != parentPath else { return }
        configuredCacheMemoryMode = mode
        configuredDiskCacheGB = diskGB
        configuredCacheDirectoryPath = parentPath

        let root: URL?
        do {
            root = try CacheLocation.root(parentPath: parentPath)
            cacheRootPath = root?.path ?? CacheLocation.describe(parentPath: parentPath)
            cacheLocationAvailable = true
        } catch {
            root = nil
            cacheRootPath = CacheLocation.describe(parentPath: parentPath)
            cacheLocationAvailable = false
            cacheStatus = "Cache drive unavailable · RAM caching remains active"
        }

        Task { [thumbnails, developedSourceDiskCache, renderedDiskCache, cullDiskCache] in
            await thumbnails.configure(memoryMode: mode, totalDiskCacheGB: diskGB, root: root)
            await developedSourceDiskCache.configure(totalDiskCacheGB: diskGB, root: root)
            await renderedDiskCache.configure(totalDiskCacheGB: diskGB, root: root)
            await cullDiskCache.configure(totalDiskCacheGB: diskGB, root: root)
        }
        trimRenderedFrameCache(to: CacheBudget.renderedFrameBytes(mode: mode))
    }

    private func handleMemoryPressure(_ level: CachePressureLevel) {
        memoryPressureConstrained = level != .normal
        if level == .warning {
            trimRenderedFrameCache(to: CacheBudget.renderedFrameBytes(mode: .conservative))
            cacheStatus = "Memory pressure · preview caches reduced"
        } else if level == .critical {
            renderedFrameCache.removeAll(keepingCapacity: true)
            renderedFrameCacheOrder.removeAll(keepingCapacity: true)
            renderedFrameCacheBytes = 0
            latestInteractiveBaseBuffer = nil
            latestInteractiveBaseLook = nil
            gestureSettleBaselineBuffer = nil
            gestureBaselineRenderedBuffer = nil
            latestSourceBuffer = nil
            latestSourceRaw = nil
            latestFilmRenderedBuffer = nil
            if let working = latestWorkingRenderedBuffer {
                latestRenderedBuffer = working
                latestRenderedLook = latestWorkingRenderedLook
            } else {
                latestRenderedBuffer = nil
                latestRenderedLook = nil
            }
            interactiveBaselineTask?.cancel()
            cacheStatus = "Critical memory pressure · full-resolution/transient buffers released"
        }
        Task { [decoder, thumbnails] in
            await decoder.handleMemoryPressure(level)
            await thumbnails.handleMemoryPressure(level)
        }
    }

    func chooseCacheFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use for Cache"
        panel.message = "Choose any writable local or mounted external-drive folder. SpektraFilmFast will create a visible ‘SpektraFilmFast Cache’ folder inside it."
        if !cacheDirectoryParentPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: cacheDirectoryParentPath, isDirectory: true)
        }
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        do {
            _ = try CacheLocation.root(parentPath: parent.path)
            cacheDirectoryParentPath = parent.path
            UserDefaults.standard.set(parent.path, forKey: "SpektraFilmFast.cacheDirectoryParentPath")
            configureCaches(force: true)
            cacheStatus = "Cache location changed · existing cache remains at its previous location until you delete it"
            refreshCacheStatus()
        } catch {
            cacheStatus = error.localizedDescription
            cacheLocationAvailable = false
        }
    }

    func useDefaultCacheFolder() {
        cacheDirectoryParentPath = ""
        UserDefaults.standard.removeObject(forKey: "SpektraFilmFast.cacheDirectoryParentPath")
        configureCaches(force: true)
        cacheStatus = "Using macOS default cache folder"
        refreshCacheStatus()
    }

    func setCacheMemoryMode(_ mode: PreviewCacheMemoryMode) {
        guard cacheMemoryMode != mode else { return }
        cacheMemoryMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "SpektraFilmFast.cacheMemoryMode")
        configureCaches(force: true)
        cacheStatus = "RAM cache policy updated"
        refreshCacheStatus()
    }

    func setLocalDiskCacheGB(_ value: Int) {
        let clamped = min(100, max(2, value))
        guard localDiskCacheGB != clamped else { return }
        localDiskCacheGB = clamped
        UserDefaults.standard.set(clamped, forKey: "SpektraFilmFast.localDiskCacheGB")
        configureCaches(force: true)
        cacheStatus = "Local cache budget updated"
        refreshCacheStatus()
    }

    func revealCacheInFinder() {
        do {
            let root = try CacheLocation.root(parentPath: cacheDirectoryParentPath)
            cacheRootPath = root.path
            cacheLocationAvailable = true
            NSWorkspace.shared.activateFileViewerSelecting([root])
        } catch {
            cacheStatus = error.localizedDescription
            cacheLocationAvailable = false
        }
    }

    func clearThumbnailCache() {
        Task { [weak self, thumbnails] in
            await thumbnails.clearMemory()
            await thumbnails.clearDisk()
            self?.cacheStatus = "Thumbnail cache cleared"
            self?.refreshCacheStatus()
        }
    }

    func clearAdjustedPreviewCache() {
        renderedFrameCache.removeAll()
        renderedFrameCacheOrder.removeAll()
        renderedFrameCacheBytes = 0
        Task { [weak self, renderedDiskCache] in
            await renderedDiskCache.clear()
            self?.cacheStatus = "Adjusted preview cache cleared"
            self?.refreshCacheStatus()
        }
    }

    func clearDevelopedSourceCache() {
        Task { [weak self, decoder, developedSourceDiskCache] in
            await decoder.clear()
            await developedSourceDiskCache.clear()
            self?.cacheStatus = "Developed RAW/source cache cleared"
            self?.refreshCacheStatus()
        }
    }

    func clearCullAnalysisCache() {
        Task { [weak self, cullDiskCache] in
            await cullDiskCache.clear()
            self?.cacheStatus = "Smart Cull cache cleared"
            self?.refreshCacheStatus()
        }
    }

    func clearLocalCaches() {
        renderedFrameCache.removeAll()
        renderedFrameCacheOrder.removeAll()
        renderedFrameCacheBytes = 0
        Task { [weak self, decoder, thumbnails, developedSourceDiskCache, renderedDiskCache, cullDiskCache] in
            await decoder.clear()
            await thumbnails.clearMemory()
            await thumbnails.clearDisk()
            await developedSourceDiskCache.clear()
            await renderedDiskCache.clear()
            await cullDiskCache.clear()
            self?.cacheStatus = "All local caches cleared"
            self?.refreshCacheStatus()
        }
    }

    func refreshCacheStatus() {
        let parentPath = cacheDirectoryParentPath
        let describedPath = CacheLocation.describe(parentPath: parentPath)
        let root = try? CacheLocation.root(parentPath: parentPath)
        cacheRootPath = root?.path ?? describedPath
        cacheLocationAvailable = root != nil
        let mode = cacheMemoryMode
        let diskGB = localDiskCacheGB
        Task { [weak self, decoder, thumbnails, developedSourceDiskCache, renderedDiskCache, cullDiskCache] in
            guard let self else { return }
            // Refresh also reconnects a removable cache drive that was absent earlier.
            await thumbnails.configure(memoryMode: mode, totalDiskCacheGB: diskGB, root: root)
            await developedSourceDiskCache.configure(totalDiskCacheGB: diskGB, root: root)
            await renderedDiskCache.configure(totalDiskCacheGB: diskGB, root: root)
            await cullDiskCache.configure(totalDiskCacheGB: diskGB, root: root)
            let decoded = await decoder.snapshot()
            let thumb = await thumbnails.snapshot()
            let developed = await developedSourceDiskCache.snapshot()
            let adjusted = await renderedDiskCache.snapshot()
            let cull = await cullDiskCache.snapshot()
            let totalHits = decoded.hits + thumb.hits + developed.hits + adjusted.hits + cull.hits
            let totalMisses = decoded.misses + thumb.misses + developed.misses + adjusted.misses + cull.misses
            let denominator = max(1, totalHits + totalMisses)
            let hitRate = Double(totalHits) / Double(denominator) * 100.0
            let disk = thumb.diskBytes + developed.diskBytes + adjusted.diskBytes + cull.diskBytes
            let ram = decoded.memoryBytes + thumb.memoryBytes + Int64(self.renderedFrameCacheBytes)
            self.cacheStatus = String(
                format: "%@ · RAM %.0f MB · disk %.2f/%.0f GB · total %dH/%dM (%.0f%%)\nRAW RAM %dH/%dM · developed SSD %dH/%dM · thumbnails %dH/%dM · adjusted previews %dH/%dM · Smart Cull %dH/%dM · writes %d",
                self.cacheLocationAvailable ? "Cache online" : "Cache drive unavailable",
                Double(ram) / 1_048_576.0,
                Double(disk) / 1_073_741_824.0,
                Double(self.localDiskCacheGB),
                totalHits,
                totalMisses,
                hitRate,
                decoded.hits, decoded.misses,
                developed.hits, developed.misses,
                thumb.hits, thumb.misses,
                adjusted.hits, adjusted.misses,
                cull.hits, cull.misses,
                decoded.writes + thumb.writes + developed.writes + adjusted.writes + cull.writes
            )
        }
    }

    func relinkMissingMedia() {
        let missing = project.images.filter { !FileManager.default.fileExists(atPath: $0.sourcePath) }
        guard !missing.isEmpty else { status = "No missing media"; return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Search Folder"
        guard panel.runModal() == .OK, let root = panel.url else { return }
        status = "Scanning for \(missing.count) missing file\(missing.count == 1 ? "" : "s")…"

        Task { [weak self, missing, root] in
            guard let self else { return }
            let candidates = await Task.detached(priority: .userInitiated) {
                let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
                let wantedNames = Set(missing.map(\.fileName))
                var found: [String: [(URL, Int64?, TimeInterval?)]] = [:]
                if let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) {
                    // Materialize URLs synchronously to avoid async iteration issues in Swift 6.
                    var urls: [URL] = []
                    while let url = enumerator.nextObject() as? URL {
                        urls.append(url)
                    }
                    for url in urls {
                        if Task.isCancelled { break }
                        guard wantedNames.contains(url.lastPathComponent),
                              let values = try? url.resourceValues(forKeys: keys),
                              values.isRegularFile == true else { continue }
                        found[url.lastPathComponent, default: []].append((
                            url,
                            values.fileSize.map(Int64.init),
                            values.contentModificationDate?.timeIntervalSince1970
                        ))
                    }
                }
                return found
            }.value

            guard !Task.isCancelled else { return }
            var relinked = 0
            var ambiguous = 0
            self.suppressDirtyTracking = true
            for i in self.project.images.indices where !FileManager.default.fileExists(atPath: self.project.images[i].sourcePath) {
                let record = self.project.images[i]
                let matches = candidates[record.fileName] ?? []
                let best: (URL, Int64?, TimeInterval?)?
                if matches.count == 1 {
                    best = matches.first
                } else if let size = record.sourceFileSize {
                    let sized = matches.filter { $0.1 == size }
                    if sized.count == 1 {
                        best = sized.first
                    } else if let stamp = record.sourceModificationTime {
                        let stamped = sized.filter { candidate in
                            guard let candidateStamp = candidate.2 else { return false }
                            return abs(candidateStamp - stamp) <= 1.0
                        }
                        best = stamped.count == 1 ? stamped.first : nil
                    } else {
                        best = nil
                    }
                } else {
                    best = nil
                }
                if let best {
                    self.project.images[i].sourcePath = best.0.path
                    self.project.images[i].sourceFileSize = best.1
                    self.project.images[i].sourceModificationTime = best.2
                    relinked += 1
                } else if !matches.isEmpty {
                    ambiguous += 1
                }
            }
            self.suppressDirtyTracking = false
            if relinked > 0 { self.projectDidChange() }
            self.status = "Relinked \(relinked) · \(self.missingMediaCount) still missing\(ambiguous > 0 ? " · \(ambiguous) ambiguous" : "")"
            if let image = self.selectedImage, FileManager.default.fileExists(atPath: image.sourcePath) {
                self.presentFastSelectionPreview(for: image)
                self.scheduleIdleRefinement()
            }
        }
    }

    // MARK: - Project and presets

    @discardableResult
    func saveProject(asNew: Bool = false) -> Bool {
        var target = projectURL
        if asNew || target == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(exportedAs: "org.spektrafilm.project", conformingTo: .data)]
            panel.nameFieldStringValue = "\(project.name).\(UTTypeNames.projectExtension)"
            guard panel.runModal() == .OK else { return false }
            target = panel.url
        }
        guard let target else { return false }
        do {
            suppressDirtyTracking = true
            project.migrateForV2()
            suppressDirtyTracking = false
            let data = try Self.encoder.encode(project)
            try data.write(to: target, options: .atomic)
            projectURL = target
            isProjectDirty = false
            autosaveTask?.cancel()
            ProjectRecoveryStore.clearSynchronously()
            status = "Saved \(target.lastPathComponent)"
            return true
        } catch {
            suppressDirtyTracking = false
            status = "Save failed: \(error.localizedDescription)"
            return false
        }
    }

    func openProject() {
        guard confirmDestructiveTransitionIfNeeded() else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.spektrafilmProject]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            invalidateRendering()
            var opened = try Self.decoderJSON.decode(SpektraProjectDocument.self, from: Data(contentsOf: url))
            opened.migrateForV2()
            suppressDirtyTracking = true
            project = opened
            suppressDirtyTracking = false
            projectURL = url
            isProjectDirty = false
            Task { [recoveryStore] in await recoveryStore.clear() }
            configureCaches()
            page = .edit
            if project.selectedImageID == nil { project.selectedImageID = project.images.first?.id }
            if let image = selectedImage { presentFastSelectionPreview(for: image) }
            workspaceDidChange(.edit)
            status = "Opened \(url.lastPathComponent)"
        } catch { status = "Open failed: \(error.localizedDescription)" }
    }

    func savePreset(name: String, category: String) {
        guard selectedImage != nil else { return }
        var look = selectedLook
        look.normalizeForProOnly()
        let preset = SpektraPreset(name: name.isEmpty ? "Untitled Preset" : name,
                                   category: category.isEmpty ? "Custom" : category,
                                   look: look)
        presets.append(preset)
        persistPresetLibrary()
        status = "Saved preset \(preset.name)"
    }

    func applyPreset(_ preset: SpektraPreset) {
        cancelIdleRefinement()
        guard let i = selectedIndex else { return }
        var look = preset.look
        look.normalizeForProOnly()
        undoStack.append(project.images[i].look)
        redoStack.removeAll()
        project.images[i].look = look
        status = "Applied preset \(preset.name)"
        scheduleIdleRefinement()
    }

    func deletePreset(_ preset: SpektraPreset) {
        presets.removeAll { $0.id == preset.id }
        persistPresetLibrary()
    }

    func exportPreset(_ preset: SpektraPreset) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.spektrafilmPreset]
        panel.nameFieldStringValue = "\(preset.name).\(UTTypeNames.presetExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var value = preset
            value.look.normalizeForProOnly()
            try Self.encoder.encode(value).write(to: url, options: .atomic)
            status = "Exported preset \(preset.name)"
        } catch { status = "Preset export failed: \(error.localizedDescription)" }
    }

    func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.spektrafilmPreset]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        do {
            for url in panel.urls {
                var preset = try Self.decoderJSON.decode(SpektraPreset.self, from: Data(contentsOf: url))
                preset.look.normalizeForProOnly()
                presets.append(preset)
            }
            persistPresetLibrary()
            status = "Imported \(panel.urls.count) preset(s)"
        } catch { status = "Preset import failed: \(error.localizedDescription)" }
    }

    // MARK: - Export

    func chooseExportDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        project.exportSettings.destinationPath = url.path
    }

    func applyExportPreset(_ presetID: String) {
        guard let preset = ExportPresetDefinition.preset(id: presetID) else { return }
        project.exportSettings = preset.applying(to: project.exportSettings)
        project.exportSettings.colorMode =
            preset.id == "tiff16-master" ? .matchRenderer : .sRGB
        status = "Export preset · \(preset.name)"
    }

    var selectedExportCount: Int {
        project.images.lazy.filter(\.selectedForExport).count
    }

    func setAllExportSelection(_ selected: Bool) {
        for index in project.images.indices {
            project.images[index].selectedForExport = selected
        }
    }

    func selectExportPicksOnly() {
        for index in project.images.indices {
            project.images[index].selectedForExport =
                project.images[index].flag == .picked
        }
    }

    func selectExportClientPicksOnly() {
        for index in project.images.indices {
            project.images[index].selectedForExport =
                project.images[index].clientPicked
        }
    }

    func selectExportRating(atLeast minimum: Int) {
        let threshold = max(0, min(5, minimum))
        for index in project.images.indices {
            project.images[index].selectedForExport =
                project.images[index].rating >= threshold
        }
    }

    var exportPreflightNames: [String] {
        ExportJobPlanner.previewNames(
            images: project.images.filter(\.selectedForExport),
            settings: project.exportSettings,
            limit: 5
        )
    }

    func exportSelected() {
        guard !isExporting, exactRenderer != nil else { return }
        let selected = project.images.filter(\.selectedForExport)
        guard !selected.isEmpty else { status = "No images selected for export"; return }
        if project.exportSettings.destinationPath.isEmpty { chooseExportDestination() }
        guard !project.exportSettings.destinationPath.isEmpty else { return }

        do {
            let job = try ExportJobPlanner.makeJob(
                images: selected,
                settings: project.exportSettings,
                bypassImportTransform: project.preferences.bypassImportTransform
            )
            activeExportJob = job
            startExport(job)
        } catch {
            status = "Export setup failed · \(error.localizedDescription)"
        }
    }

    func stopExport() {
        guard isExporting, !isStoppingExport else { return }
        isStoppingExport = true
        status = "Stopping export…"
        if var job = activeExportJob {
            job.state = .stopping
            job.updatedAt = Date()
            activeExportJob = job
            Task { try? await ExportJobJournal.shared.save(job) }
        }
        exportTask?.cancel()
    }

    func resumeExport() {
        guard !isExporting, var job = activeExportJob, job.remainingCount > 0 else { return }
        for index in job.items.indices where job.items[index].state == .rendering || job.items[index].state == .writing {
            job.items[index].state = .pending
            job.items[index].errorMessage = nil
        }
        activeExportJob = job
        startExport(job)
    }

    func retryFailedExports() {
        guard !isExporting, var job = activeExportJob else { return }
        var changed = false
        for index in job.items.indices where job.items[index].state == .failed {
            job.items[index].state = .pending
            job.items[index].errorMessage = nil
            changed = true
        }
        guard changed else { return }
        job.state = .stopped
        job.updatedAt = Date()
        activeExportJob = job
        startExport(job)
    }

    func discardRecoveredExportJob() {
        guard !isExporting else { return }
        activeExportJob = nil
        exportProgress = 0
        exportCurrentFileName = ""
        Task { await ExportJobJournal.shared.clear() }
        status = "Export recovery discarded"
    }

    private func restoreExportJobIfNeeded() async {
        guard var job = await ExportJobJournal.shared.load() else { return }
        job.normalizeAfterInterruptedLaunch()
        if job.state == .completed {
            await ExportJobJournal.shared.clear()
            return
        }
        activeExportJob = job
        exportProgress = job.fractionComplete
        status = "Unfinished export available · \(job.remainingCount) remaining"
        try? await ExportJobJournal.shared.save(job)
    }

    private func startExport(_ initialJob: ExportJob) {
        exportTask?.cancel()
        isExporting = true
        isStoppingExport = false
        exportFailures = []
        exportProgress = initialJob.fractionComplete
        status = "Preparing export queue…"
        exportTask = Task { [weak self] in
            await self?.runExportJob(initialJob)
        }
    }

    private func runExportJob(_ initialJob: ExportJob) async {
        guard let exactRenderer else {
            isExporting = false
            status = "Export renderer unavailable"
            return
        }

        var job = initialJob
        job.state = .running
        job.updatedAt = Date()
        activeExportJob = job
        try? await ExportJobJournal.shared.save(job)

        defer {
            isExporting = false
            isStoppingExport = false
            exportCurrentFileName = ""
            exportTask = nil
        }

        let workIndices = job.items.indices.filter {
            job.items[$0].state != .completed &&
            job.items[$0].state != .failed
        }

        var decodeAhead: Task<ExportDecodedFrame, Error>?
        var decodeAheadIndex: Int?
        var pendingWrite: PendingExportWrite?

        defer {
            decodeAhead?.cancel()
            pendingWrite?.task.cancel()
        }

        @MainActor func startDecode(index: Int) -> Task<ExportDecodedFrame, Error> {
            let item = job.items[index]
            let url = URL(fileURLWithPath: item.sourcePath)
            let raw = item.look.raw
            let bypass = job.bypassImportTransform
            let decoderActor = decoder

            return Task {
                let started = ProcessInfo.processInfo.systemUptime
                let buffer = try await decoderActor.fullResolution(
                    url: url,
                    raw: raw,
                    bypassImportTransform: bypass
                )
                return ExportDecodedFrame(
                    buffer: buffer,
                    decodeMs: Self.msSince(started)
                )
            }
        }

        @MainActor func settlePendingWrite() async throws {
            guard let pending = pendingWrite else { return }
            defer { pendingWrite = nil }

            do {
                let writeMs = try await pending.task.value
                var timings = pending.timings
                timings.writeMs = writeMs
                timings.wallMs =
                    (ProcessInfo.processInfo.systemUptime - pending.itemStarted) * 1000.0

                let destination = URL(
                    fileURLWithPath: job.items[pending.index].destinationPath
                )
                let attrs = try? FileManager.default.attributesOfItem(
                    atPath: destination.path
                )
                let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                timings.outputBytes = bytes

                job.items[pending.index].outputBytes = bytes
                job.items[pending.index].timings = timings
                job.items[pending.index].state = .completed
                job.items[pending.index].errorMessage = nil
                await ExportTimingLog.shared.record(job.items[pending.index])
            } catch is CancellationError {
                job.items[pending.index].state = .pending
                job.items[pending.index].errorMessage = nil
                throw CancellationError()
            } catch {
                job.items[pending.index].state = .failed
                job.items[pending.index].errorMessage = error.localizedDescription
                exportFailures.append(
                    ExportFailure(
                        fileName: job.items[pending.index].sourceFileName,
                        message: error.localizedDescription
                    )
                )
            }

            job.updatedAt = Date()
            activeExportJob = job
            exportProgress = job.fractionComplete
            try? await ExportJobJournal.shared.save(job)
        }

        for (position, index) in workIndices.enumerated() {
            do {
                try Task.checkCancellation()
                let item = job.items[index]
                let sourceURL = URL(fileURLWithPath: item.sourcePath)

                job.items[index].state = .rendering
                job.items[index].errorMessage = nil
                job.updatedAt = Date()
                activeExportJob = job
                exportCurrentFileName = item.sourceFileName
                exportProgress = job.fractionComplete
                status = "Rendering \(item.sourceFileName)…"
                try await ExportJobJournal.shared.save(job)

                let itemStarted = ProcessInfo.processInfo.systemUptime
                var timings = ExportItemTimings()

                let decoded: ExportDecodedFrame
                if decodeAheadIndex == index, let task = decodeAhead {
                    decoded = try await task.value
                    timings.decodePrefetched = true
                } else {
                    decoded = try await startDecode(index: index).value
                    timings.decodePrefetched = false
                }
                decodeAhead = nil
                decodeAheadIndex = nil

                timings.decodeMs = decoded.decodeMs
                timings.sourceWidth = decoded.buffer.width
                timings.sourceHeight = decoded.buffer.height
                try Task.checkCancellation()

                // Decode N+1 while N grades/renders. Admission is based on the
                // bytes macOS says this process can still allocate, not MP count.
                if position + 1 < workIndices.count {
                    let nextIndex = workIndices[position + 1]
                    let nextURL = URL(
                        fileURLWithPath: job.items[nextIndex].sourcePath
                    )
                    if Self.shouldPrefetchExportDecode(nextURL) {
                        decodeAheadIndex = nextIndex
                        decodeAhead = startDecode(index: nextIndex)
                    }
                }

                let gradeStarted = ProcessInfo.processInfo.systemUptime
                let renderInput = await Task.detached(priority: .userInitiated) {
                    decoded.buffer.applyingHostGrade(
                        tone: item.look.tone,
                        density: item.look.colorDensity
                    )
                }.value
                timings.gradeMs = Self.msSince(gradeStarted)
                try Task.checkCancellation()

                var exportLook = item.look
                if job.settings.colorMode == .sRGB {
                    // Real sRGB renderer output for web/phone delivery.
                    // This is not an ICC retag of Rec.709 Gamma 2.4 pixels.
                    exportLook.values["outputColorSpace"] = .int(17)
                    exportLook.values["outputRole"] = .int(0)
                }

                let renderStarted = ProcessInfo.processInfo.systemUptime
                let (filmOutput, renderDiagnostics) =
                    try await exactRenderer.render(renderInput, look: exportLook)
                timings.renderMs = Self.msSince(renderStarted)
                timings.renderGpuMs = renderDiagnostics.commandBufferMs
                timings.renderPassCount = renderDiagnostics.passCount
                try Task.checkCancellation()

                // Keep these captures outside the @Sendable closure. The source
                // gate explicitly protects this Swift 6.2 concurrency pattern.
                let geometrySettings = item.look.geometry
                let exportSettings = job.settings
                let geometryStarted = ProcessInfo.processInfo.systemUptime
                let output = try await Task.detached(priority: .utility) {
                    let geometryOutput = GeometryEngine.transformed(
                        filmOutput,
                        settings: geometrySettings
                    )
                    return try geometryOutput.resizedForExport(
                        settings: exportSettings
                    )
                }.value
                timings.geometryResizeMs = Self.msSince(geometryStarted)
                timings.outputWidth = output.width
                timings.outputHeight = output.height
                try Task.checkCancellation()

                // Writer N-1 has overlapped decode + render N. Drain the single
                // writer slot before launching writer N; this bounds retained RAM.
                try await settlePendingWrite()

                job.items[index].state = .writing
                job.updatedAt = Date()
                activeExportJob = job
                status =
                    "Writing \(URL(fileURLWithPath: item.destinationPath).lastPathComponent)…"
                try await ExportJobJournal.shared.save(job)

                let destination = URL(fileURLWithPath: item.destinationPath)
                let writer = exportEngine
                let sourceForWriter = sourceURL
                let settingsForWriter = job.settings
                let lookForWriter = exportLook

                let writerTask = Task.detached(priority: .utility) {
                    let started = ProcessInfo.processInfo.systemUptime
                    try await writer.write(
                        output: output,
                        look: lookForWriter,
                        sourceURL: sourceForWriter,
                        destination: destination,
                        settings: settingsForWriter
                    )
                    return (ProcessInfo.processInfo.systemUptime - started) * 1000.0
                }

                pendingWrite = PendingExportWrite(
                    index: index,
                    itemStarted: itemStarted,
                    timings: timings,
                    task: writerTask
                )

            } catch is CancellationError {
                decodeAhead?.cancel()
                pendingWrite?.task.cancel()
                decodeAhead = nil
                decodeAheadIndex = nil
                pendingWrite = nil

                for i in job.items.indices
                where job.items[i].state == .rendering ||
                      job.items[i].state == .writing {
                    job.items[i].state = .pending
                    job.items[i].errorMessage = nil
                }

                job.state = .stopped
                job.updatedAt = Date()
                activeExportJob = job
                exportProgress = job.fractionComplete
                try? await ExportJobJournal.shared.save(job)
                status = "Export stopped · \(job.remainingCount) remaining"
                return

            } catch {
                job.items[index].state = .failed
                job.items[index].errorMessage = error.localizedDescription
                job.updatedAt = Date()
                exportFailures.append(
                    ExportFailure(
                        fileName: job.items[index].sourceFileName,
                        message: error.localizedDescription
                    )
                )
                activeExportJob = job
                exportProgress = job.fractionComplete
                try? await ExportJobJournal.shared.save(job)
            }
        }

        do {
            try await settlePendingWrite()
        } catch is CancellationError {
            job.state = .stopped
            job.updatedAt = Date()
            activeExportJob = job
            try? await ExportJobJournal.shared.save(job)
            status = "Export stopped · \(job.remainingCount) remaining"
            return
        } catch {
            // settlePendingWrite records normal writer failures itself.
        }

        job.state = .completed
        job.updatedAt = Date()
        activeExportJob = job
        exportProgress = 1

        if job.failedCount == 0 {
            status =
                "Export complete · \(job.completedCount) files · timings in \(Self.exportTimingLogPath)"
            await ExportJobJournal.shared.clear()
        } else {
            status =
                "Export finished · \(job.completedCount) complete · \(job.failedCount) failed · timings in \(Self.exportTimingLogPath)"
            try? await ExportJobJournal.shared.save(job)
        }
    }

    // macOS has no os_proc_available_memory(); that symbol is
    // API_UNAVAILABLE(macos) in os/proc.h. Free + inactive + purgeable is the
    // usual stand-in for "what the allocator can still hand out".
    // ponytail: returns 0 on failure so a bad read skips prefetch instead of
    // over-committing; prefetch is an optimization, not a requirement.
    private static func availableMemoryBytes() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let status = withUnsafeMutablePointer(to: &stats) { raw in
            raw.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard status == KERN_SUCCESS else { return 0 }
        // getpagesize(), not vm_kernel_page_size: the latter is a mutable C global
        // and Swift 6 concurrency rejects reading it.
        let page = UInt64(getpagesize())
        let free = UInt64(stats.free_count)
        let inactive = UInt64(stats.inactive_count)
        let purgeable = UInt64(stats.purgeable_count)
        return (free + inactive + purgeable) * page
    }

    private static func shouldPrefetchExportDecode(_ url: URL) -> Bool {
        let pixels = approximatePixelCount(url)
        guard pixels > 0 else { return false }

        // Float RGBA = 16 B/px. Reserve another 16 B/px for Core Image /
        // decoder scratch and keep at least 512 MiB or one third of currently
        // available allocation headroom untouched.
        let estimate = UInt64(pixels) * 32
        let available = availableMemoryBytes()
        guard available > 0 else { return false }
        let reserve = max(UInt64(512 * 1024 * 1024), available / 3)

        guard available > reserve else { return false }
        return estimate <= available - reserve
    }

    // MARK: - Helpers

    private func mutateSelected(_ body: (inout ProjectImageRecord) -> Void) {
        guard let i = selectedIndex else { return }
        body(&project.images[i])
    }

    private func loadPresetLibrary() {
        guard let data = try? Data(contentsOf: Self.presetLibraryURL),
              var value = try? Self.decoderJSON.decode([SpektraPreset].self, from: data) else { return }
        for index in value.indices { value[index].look.normalizeForProOnly() }
        presets = value
    }

    private func persistPresetLibrary() {
        do {
            try FileManager.default.createDirectory(at: Self.appSupportURL, withIntermediateDirectories: true)
            try Self.encoder.encode(presets).write(to: Self.presetLibraryURL, options: .atomic)
        } catch { status = "Save preset failed: \(error.localizedDescription)" }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoderJSON: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static var appSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SpektraFilm")
    }

    private static var presetLibraryURL: URL { appSupportURL.appendingPathComponent("presets.json") }



    var missingMediaCount: Int {
        project.images.reduce(into: 0) { count, image in
            if !FileManager.default.fileExists(atPath: image.sourcePath) { count += 1 }
        }
    }

    private static func makeImageRecord(url: URL) -> ProjectImageRecord {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return ProjectImageRecord(
            sourcePath: url.path,
            sourceFileSize: values?.fileSize.map(Int64.init),
            sourceModificationTime: values?.contentModificationDate?.timeIntervalSince1970
        )
    }

    private static func exportName(image: ProjectImageRecord, sequence: Int, settings: ExportSettings) -> String {
        let base = image.url.deletingPathExtension().lastPathComponent
        let sequenceText = String(format: "%04d", sequence)
        let template = settings.filenameTemplate
        var expanded = template
            .replacingOccurrences(of: "{name}", with: base)
            .replacingOccurrences(of: "{sequence}", with: sequenceText)

        if !template.contains("{name}") && !template.contains("{sequence}") {
            expanded += "_\(sequenceText)"
        }

        let invalid = CharacterSet(charactersIn: "/:\\").union(.newlines).union(.controlCharacters)
        let safe = expanded.components(separatedBy: invalid).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty ? "SpektraFilm_\(sequenceText)" : safe
    }

    private static func exportDestination(
        image: ProjectImageRecord,
        sequence: Int,
        settings: ExportSettings,
        reservedPaths: inout Set<String>
    ) -> URL {
        let directory = URL(fileURLWithPath: settings.destinationPath)
        let sequenceText = String(format: "%04d", sequence)
        let baseName = exportName(image: image, sequence: sequence, settings: settings)
        var candidate = directory.appendingPathComponent(baseName)
            .appendingPathExtension(settings.format.fileExtension)

        if reservedPaths.contains(candidate.standardizedFileURL.path) {
            candidate = directory.appendingPathComponent("\(baseName)_\(sequenceText)")
                .appendingPathExtension(settings.format.fileExtension)
        }
        var collision = 2
        while reservedPaths.contains(candidate.standardizedFileURL.path) {
            candidate = directory.appendingPathComponent("\(baseName)_\(sequenceText)_\(collision)")
                .appendingPathExtension(settings.format.fileExtension)
            collision += 1
        }
        reservedPaths.insert(candidate.standardizedFileURL.path)
        return candidate
    }

    private static func msSince(_ start: TimeInterval) -> Double {
        (ProcessInfo.processInfo.systemUptime - start) * 1000.0
    }

    static var exportTimingLogPath: String { ExportTimingLog.fileURL.path }

private static func approximatePixelCount(_ url: URL) -> Int64 {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? NSNumber,
              let h = props[kCGImagePropertyPixelHeight] as? NSNumber else { return 0 }
        return Int64(w.intValue) * Int64(h.intValue)
    }
}
