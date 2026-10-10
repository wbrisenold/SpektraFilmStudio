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
    let originalForMetadata: URL
}

private struct ExportPostprocessResult: Sendable {
    let geometryResizeMs: Double
    let writeMs: Double
    let outputWidth: Int
    let outputHeight: Int
    let outputBytes: Int64
    let completedUptime: TimeInterval
}

private struct PendingExportPostprocess {
    let index: Int
    let retainedBytes: UInt64
    let itemStarted: TimeInterval
    var timings: ExportItemTimings
    let task: Task<ExportPostprocessResult, Error>
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
    @Published var page: WorkspacePage = .library {
        didSet { if page != .library { showProjectHome = false } }
    }
    @Published var project = SpektraProjectDocument()
    var workspaceGeneration = UUID()
    private var projectOpenGeneration = UUID()
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
        // New installations show the Presets / Photos tabbed sidebar by default;
        // existing users' explicit sidebar choice is preserved.
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
    // Project launchers are always available, even with a populated photo library.
    @Published var showProjectHome = true
    // Lightroom opens its existing guided import sheet; file picking is centralized
    // in SpektraFilePanel, not independent Published booleans on ContentView.
    @Published var showingLightroomImportWizard = false
    // Prevent delayed startup iCloud autorestore from replacing a user-selected project.
    var didStartProjectWorkflow = false
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
    @Published var bestPicksPendingFolder: String?
    @Published var bestPicksPercent: Double = 0.25
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

    @Published var cloudLibraryStatus = "Not connected"
    @Published var externalOriginalScratchParent =
        UserDefaults.standard.string(forKey: "SpektraFilmStudio.externalOriginalScratchParent") ?? ""
    @Published var stagedCloudOriginals: [UUID: URL] = [:]
    @Published var cloudLibraryRootPath =
        UserDefaults.standard.string(forKey: "SpektraFilmStudio.cloudLibraryRootPath") ?? ""
    @Published var isCloudSyncing = false
    @Published var cloudSyncProgress = 0.0
    @Published var cloudLastSync: Date?
    var cloudLibrary: SpektraCloudLibrary?
    var cloudSyncLoopTask: Task<Void, Never>?
    var cloudPublishTask: Task<Void, Never>?

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

    // The source and local grade live BEFORE crop, rotation and keystone.
    // A displayed Before frame is already geometrically transformed: its size cannot
    // serve as the authoritative pre-geometry mask dimensions.
    var maskSourceDimensions: (width: Int, height: Int)? {
        if let source = latestSourceBuffer { return (source.width, source.height) }
        if let film = latestWorkingFilmRenderedBuffer ?? latestFilmRenderedBuffer {
            return (film.width, film.height)
        }
        return nil
    }
    private var latestWorkingRenderedLook: RenderLook?
    private var lastSourcePreviewKey: SourcePreviewKey?

    private var importHydrationTask: Task<Void, Never>?
    private var selectionPresentationTask: Task<Void, Never>?
    private var editorWarmupTask: Task<Void, Never>?
    private var selectionPresentationGeneration = 0
    private var renderedFrameCache: [RenderedFrameKey: CachedRenderedFrame] = [:]
    private var renderedFrameCacheOrder: [RenderedFrameKey] = []
    private var renderedFrameCacheBytes = 0
    private var presetThumbnailCache: [String: CGImage] = [:]
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
    // Latest-only GPU render queue, independent of CPU image packaging.
    @Published var liveGPUFrame: GPULiveFrame?
    @Published var rendererPathStatus = "Native spectral Metal · exact"
    @Published var lutPreparationStatus = ""
    @Published var lutIsPreparing = false
    private var lutPrewarmTask: Task<Void, Never>?
    private let gpuLivePipeline = GPULiveFramePipeline()
    private var pendingGPUPreview: GPULivePreviewRequest?
    private var gpuPreviewTask: Task<Void, Never>?
    private var gpuPreviewGeneration = 0
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
    var suppressDirtyTracking = false
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

        if CommandLine.arguments.contains(where: { ["--picker-smoke-test", "--ux-smoke-test", "--export-smoke-test", "--self-test", "--studio-soak-test"].contains($0) }) {
            didStartProjectWorkflow = true
            return
        }

        Task { [weak self] in
            guard let self else { return }
            await restoreExportJobIfNeeded()
            await refreshRecoverableIngestState()
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self, self.project.images.isEmpty, !self.isProjectDirty,
                  !self.didStartProjectWorkflow else { return }
            await self.restoreCloudLibraryIfPossible()
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

    /// Redlamp's InspectorFooter "Previous": apply this photo's settings to the
    /// previously viewed one. Adjacent in selection order, excluding itself.
    var previousLookTargetID: UUID? {
        guard let index = selectedIndex, project.images.indices.contains(index - 1) else { return nil }
        return project.images[index - 1].id
    }

    func applyLookToPreviousImage() {
        guard let target = previousLookTargetID,
              let source = selectedImage,
              let index = project.images.firstIndex(where: { $0.id == target }) else { return }
        project.images[index].look = source.look
        status = "Settings applied to the previous photo"
        requestPreviewRefresh()
    }

    var selectedImage: ProjectImageRecord? {
        guard let i = selectedIndex else { return nil }
        var image = project.images[i]
        if image.cloudRelativePath != nil,
           let external = stagedCloudOriginals[image.id],
           FileManager.default.fileExists(atPath: external.path) {
            // Transient session location: NEVER write this local path to the synced catalog.
            image.sourcePath = external.path
        }
        return image
    }

    var selectedLook: RenderLook {
        if let gestureWorkingLook { return gestureWorkingLook }
        return selectedImage?.look ?? .defaults()
    }

    var isInteractiveEditActive: Bool {
        activeEditBaseline != nil
    }


    func resetLibraryFilters() {
        librarySearch = ""
        libraryFilter = .all
        libraryFolderFilter = nil
        libraryAlbumFilter = nil
        librarySmartCollectionFilter = nil
        libraryPeopleGroupFilter = nil
        project.filterRating = 0
        project.filterFlag = nil
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
        if let focal = image.metadata?.focalLengthMM, focal.isFinite, focal >= 0, focal < 1_000_000,
           "\(Int(focal.rounded()))mm".contains(query) { return true }
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
        confirmDestructiveTransitionIfNeeded { [weak self] allowed in
            if allowed { self?.createNewProject() }
        }
    }

    private func createNewProject() {
        workspaceGeneration = UUID()
        projectOpenGeneration = UUID()
        disconnectCloudLibrary()
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
        latestFilmRenderedBuffer = nil
        latestWorkingFilmRenderedBuffer = nil
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
        showProjectHome = true
        didStartProjectWorkflow = true
        status = "New project"
    }

    func standalonePhotoMode() {
        SpektraFilePanel.chooseFiles(title: "Open Standalone Photo", types: [.image, .rawImage]) { [weak self] urls in
            guard let self, let url = urls.first else { return }
            self.standalonePhotoMode(at: url)
        }
    }

    func standalonePhotoMode(at url: URL) {
        confirmDestructiveTransitionIfNeeded { [weak self] allowed in
            if allowed { self?.openStandalonePhoto(at: url) }
        }
    }

    private func openStandalonePhoto(at url: URL) {
        workspaceGeneration = UUID()
        projectOpenGeneration = UUID()
        disconnectCloudLibrary()
        invalidateRendering()
        project = SpektraProjectDocument()
        project.migrateForV2()
        project.workspaceMode = .standalone
        project.name = url.deletingPathExtension().lastPathComponent
        project.images = [Self.makeImageRecord(url: url)]
        project.selectedImageID = project.images[0].id
        projectURL = nil
        page = .edit
        showProjectHome = false
        didStartProjectWorkflow = true
        isProjectDirty = true
        status = "Standalone photo mode"
        presentFastSelectionPreview(for: project.images[0])
        workspaceDidChange(.edit)
    }

    func importImages() {
        SpektraFilePanel.chooseFiles(title: "Import Photos", types: [.image, .rawImage], multiple: true) { [weak self] urls in
            guard let self, !urls.isEmpty else { return }
            self.addImages(urls: urls)
        }
    }

    /// Imports an entire shoot without asking the user to select thousands of files.
    /// Enumeration and type filtering happen off the main actor; adding records remains one
    /// project publication followed by the existing bounded thumbnail/metadata hydration path.
    func importFolder() {
        SpektraFilePanel.chooseFolder(title: "Import Photo Folder") { [weak self] folder in
            self?.importFolder(at: folder)
        }
    }

    /// Source-aware import for the guided wizard. Uses the existing non-blocking scanner.
    func importFolder(at folder: URL, cloudParent: URL? = nil) {
        status = "Scanning \(folder.lastPathComponent)…"
        let workspace = workspaceGeneration
        Task { [weak self] in
            guard let self else { return }
            let urls = await Task.detached(priority: .userInitiated) {
                Self.photoURLs(in: folder)
            }.value
            guard !Task.isCancelled, workspaceGeneration == workspace else { return }
            if urls.isEmpty {
                status = "No supported photos found in \(folder.lastPathComponent)"
                return
            }
            addImages(urls: urls)
            if let cloudParent {
                moveCurrentLibraryToICloud(parent: cloudParent)
            }
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
            // Import is library/document work only. Do not wake preview, RAW decode,
            // masks, scopes or the film renderer while hydration is still starting.
            project.selectedImageID = first.id
            renderedPreview = nil
            sourcePreview = nil
            latestSourceBuffer = nil
            latestSourceRaw = nil
            latestRenderedBuffer = nil
            latestRenderedLook = nil
            latestWorkingRenderedBuffer = nil
            latestWorkingRenderedLook = nil
            latestInteractiveBaseBuffer = nil
            latestInteractiveBaseLook = nil
            clearStudioAnalysis()
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
                let metadataService = self.metadataService
                let xmpService = self.xmpService
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
        if destination != .edit { isCropToolActive = false }
        if page != destination { page = destination }
        switch destination {
        case .library, .cull, .proofs, .export:
            if !stagedCloudOriginals.isEmpty {
                stagedCloudOriginals.removeAll()
                Task { await ExternalOriginalScratch.shared.setEditing(nil) }
            }
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
            if deferPreviewForCloudOriginalIfNeeded(image, renderPreview: true) { return }
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
            if !stagedCloudOriginals.isEmpty {
                stagedCloudOriginals = stagedCloudOriginals.filter { $0.key == id }
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    await ExternalOriginalScratch.shared.setEditing(page == .edit ? id : nil)
                }
            }
            isGradientMaskEditing = false
            activeLocalGradeID = nil
            isLensCenterEditing = false
            selectedGradientMaskID = nil
            // Canonical masks belong to a single photo. Reusing them corrupts skin WB,
            // overlay and vectorscope when moving through the filmstrip.
            semanticMaskTask?.cancel()
            semanticMaskTask = nil
            semanticMasks = nil
            semanticAnalysisDeferred = false
            pendingNewSemanticKind = nil
            pendingSemanticComponent = nil
            latestSkinMaskWidth = 0
            latestSkinMaskHeight = 0
            latestSkinMaskAlpha = []
            cancelPreviewForNavigation()
            gpuPreviewGeneration &+= 1
            pendingGPUPreview = nil
            gpuPreviewTask?.cancel()
            liveGPUFrame = nil
            gestureWorkingLook = nil
            activeEditBaseline = nil
            project.selectedImageID = id
            // Never display the previous photo while a cloud download/source warmup runs.
            renderedPreview = nil
            sourcePreview = nil
            undoStack.removeAll()
            redoStack.removeAll()
            latestSourceBuffer = nil
            latestSourceRaw = nil
            latestFilmRenderedBuffer = nil
            latestWorkingFilmRenderedBuffer = nil
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
        if deferPreviewForCloudOriginalIfNeeded(image, renderPreview: renderPreview) { return }
        refreshWhiteBalanceReference(for: image)
        guard FileManager.default.fileExists(atPath: image.sourcePath) else {
            renderedPreview = nil
            sourcePreview = nil
            status = "Missing media · use Relink Missing Media…"
            return
        }
        if renderPreview {
            if changed || renderedPreview == nil {
                presentFastSelectionPreview(for: image, renderOnMiss: true)
            } else if !restoreLatestWorkingStateFromMemoryCache(for: image) {
                presentFastSelectionPreview(for: image, renderOnMiss: true)
            }
        } else {
            // Library/Cull selection must stay decode-free. ThumbnailService owns
            // browsing; source development begins only after entering Edit.
            editorWarmupTask?.cancel()
            status = "Selected \(image.fileName)"
        }
    }

    /// Library/Cull selection quietly develops only the selected photo after a short idle.
    /// Rapid navigation cancels older warmups, so a 2,000-photo shoot cannot create a RAW
    /// decode backlog. When the user enters Edit, the normal preview source is usually already
    /// resident and the first Spektrafilm frame can start immediately.
    private func warmEditorSourceAfterSelectionIdle(_ image: ProjectImageRecord) {
        editorWarmupTask?.cancel()
        // Library/Cull must never trigger iCloud File Provider RAW downloads.
        if image.cloudRelativePath != nil { return }
        let prefs = project.preferences
        // Only the focused local photo is warmed, never its neighbors.
        let candidates: [ProjectImageRecord] = [image]
        let memoryMode = cacheMemoryMode
        editorWarmupTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(240))
                guard !Task.isCancelled, project.selectedImageID == image.id, page != .edit else { return }
                // Build the persistent linear workfile for the active photo and its nearest
                // neighbors. These are temporary cache files only; the originals stay untouched.
                let decoder = self.decoder
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
                  (page == .edit || (page == .export && isCropToolActive)) else { return }
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
            maskOverlayRevision &+= 1  // Recompose a cached viewer frame with valid source dimensions.
        }
    }

    func selectRelative(_ delta: Int, renderPreview: Bool? = nil) {
        guard !visibleImages.isEmpty else { return }
        let ids = visibleImages.map(\.id)
        let current = project.selectedImageID.flatMap { ids.firstIndex(of: $0) } ?? 0
        let next = max(0, min(ids.count - 1, current + delta))
        let nextID = ids[next]
        if librarySelection.count <= 1 {
            librarySelection = [nextID]
            librarySelectionAnchor = nextID
        }
        selectImage(nextID, renderPreview: renderPreview ?? (page == .edit))
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
        lutPrewarmTask?.cancel() // Prevent a new LUT bake from contending with live input.
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
        gpuPreviewGeneration &+= 1
        pendingGPUPreview = nil
        gpuPreviewTask?.cancel()
        // Keep the cancelled task reference until its defer releases it.
        // A new pointer gesture then remains coalesced behind the old GPU fence.

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
            if name == "filmExposureEv" || name == "autoExposure" {
                gestureWorkingLook?.tone?.autoContrast = false
                gestureWorkingLook?.filmTone?.autoContrast = false
            }
            activeEditChangedParameter = name
            // Proxy first. Native film exposure is not equivalent to a display gain, so
            // coalesce a small exact render through the real film pipeline while dragging.
            publishInteractiveProxy(changedParameter: name, rawField: nil)
            if name == "filmExposureEv" || name == "autoExposure" {
                scheduleRender(
                    interactive: true,
                    changedParameter: name,
                    longEdgeOverride: min(720, project.preferences.previewLongEdge),
                    cacheResult: false,
                    reason: "accurate film exposure preview",
                    useInteractiveRenderPolicy: false,
                    lookOverride: gestureWorkingLook
                )
            }
            return
        }

        cancelIdleRefinement()
        if activeEditBaseline == nil {
            undoStack.append(project.images[i].look)
            redoStack.removeAll()
        }
        project.images[i].look.values[name] = value
        if name == "filmExposureEv" || name == "autoExposure" {
            project.images[i].look.tone?.autoContrast = false
            project.images[i].look.filmTone?.autoContrast = false
        }
        project.images[i].look.normalizeForProOnly()
        propagateBatchEdit(from: project.images[i].look, activeIndex: i, changedParameter: name)
        scheduleIdleRefinement(changedParameter: name)
    }

    // MARK: - Local grades / masks (Stage 2)

    @discardableResult
    func addLocalGrade() -> UUID {
        guard let i = selectedIndex else { return UUID() }
        undoStack.append(project.images[i].look)
        redoStack.removeAll()
        var grade = LocalGradeRecord(name: "Local Grade \((project.images[i].look.localGrades?.count ?? 0) + 1)")
        grade.normalize()
        if project.images[i].look.localGrades == nil { project.images[i].look.localGrades = [] }
        project.images[i].look.localGrades?.append(grade)
        maskOverlayRevision &+= 1
        requestPreviewRefresh()
        return grade.id
    }

    func removeLocalGrade(_ gradeID: UUID) {
        mutateMaskLook { look in look.localGrades?.removeAll { $0.id == gradeID } }
    }

    func setLocalGradeEnabled(_ gradeID: UUID, _ enabled: Bool) { mutateGrade(gradeID) { $0.enabled = enabled } }
    func setLocalGradeOpacity(_ gradeID: UUID, _ value: Double) { mutateGrade(gradeID) { $0.opacity = min(1, max(0, value)) } }
    var activeLocalGrade: LocalGradeRecord? {
        guard let id = activeLocalGradeID else { return nil }
        return (selectedLook.localGrades ?? []).first(where: { $0.id == id })
    }

    func selectLocalGrade(_ id: UUID?) {
        activeLocalGradeID = id
        if id == nil {
            isGradientMaskEditing = false
            selectedGradientMaskID = nil
        }
    }

    private func assignLocalTone(_ tone: inout ToneSettings, key: String, value: Double) {
        switch key {
        case "exposure": tone.exposureEV = max(-5, min(5, value))
        case "brightness": tone.brightness = max(-100, min(100, value))
        case "contrast": tone.contrast = max(-100, min(100, value))
        case "midtones": tone.midtones = max(-100, min(100, value))
        case "highlights": tone.highlights = max(-100, min(100, value))
        case "highlightRecovery": tone.highlightRecovery = max(0, min(100, value))
        case "shadows": tone.shadows = max(-100, min(100, value))
        case "shadowRecovery": tone.shadowRecovery = max(0, min(100, value))
        case "whites": tone.whites = max(-100, min(100, value))
        case "blacks": tone.blacks = max(-100, min(100, value))
        default: break
        }
    }

    func setLocalTone(_ gradeID: UUID, _ key: String, _ value: Double, interactive: Bool = false) {
        if interactive {
            if gestureWorkingLook == nil { beginEditGesture() }
            guard var working = gestureWorkingLook,
                  let index = working.localGrades?.firstIndex(where: { $0.id == gradeID }) else { return }
            var tone = working.localGrades![index].tone ?? ToneSettings()
            assignLocalTone(&tone, key: key, value: value)
            working.localGrades![index].tone = tone
            working.localGrades![index].normalize()
            gestureWorkingLook = working
            activeEditChangedParameter = "localTone.\(key)"
            publishLocalGradePreview(look: working)
            return
        }
        mutateGrade(gradeID) { grade in
            var tone = grade.tone ?? ToneSettings()
            assignLocalTone(&tone, key: key, value: value)
            grade.tone = tone
        }
    }

    private func publishLocalGradePreview(look: RenderLook) {
        guard let film = latestWorkingFilmRenderedBuffer ?? latestFilmRenderedBuffer else {
            requestPreviewRefresh()
            return
        }
        interactiveProxyTask?.cancel()
        interactiveProxyGeneration += 1
        let generation = interactiveProxyGeneration
        let imageID = project.selectedImageID
        let prefs = project.preferences
        let profile = OutputColorProfile.forLook(look)
        interactiveProxyTask = Task { [weak self] in
            guard let self else { return }
            let checkpoint = GPUProcessingFailure.checkpoint()
            let worker = Task.detached(priority: .userInitiated) { () -> (PixelBufferF32, FloatImagePayload?) in
                let local = MaskedLocalGradeEngine.apply(film, grades: look.localGrades)
                let lens = LensCharacterEngine.apply(local, settings: look.lensEffects)
                let geometry = GeometryEngine.transformed(lens, settings: look.geometry)
                let output = ExposureBoundaryEngine.apply(geometry, look: look, preferences: prefs)
                return (output, output.makeFloatImagePayload())
            }
            let (output, payload) = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard (try? GPUProcessingFailure.requireSuccess(after: checkpoint)) != nil,
                  !Task.isCancelled, generation == interactiveProxyGeneration,
                  project.selectedImageID == imageID, gestureWorkingLook == look,
                  let image = payload?.makeCGImage(colorSpace: profile.cgColorSpace) else { return }
            renderedPreview = image
            latestRenderedBuffer = output
            latestRenderedLook = look
            status = "Live masked adjustment"
            requestEditorScopeUpdate()
        }
    }
    func setLocalDensity(_ gradeID: UUID, _ value: Double) {
        mutateGrade(gradeID) { grade in
            var density = grade.colorDensity ?? ColorDensitySettings()
            density.master = max(-1, min(1, value))
            grade.colorDensity = density
        }
    }

    func addMaskSource(gradeID: UUID, kind: MaskSourceKind) {
        mutateGrade(gradeID) { grade in
            var source = MaskSourceRecord(name: kind.rawValue, kind: kind)
            switch kind {
            case .radial: source.radial = RadialMaskGeometry(); source.linearGradient = nil; source.raster = nil
            case .linearGradient: source.radial = nil; source.linearGradient = LinearGradientMaskGeometry(); source.raster = nil
            case .raster: source.radial = nil; source.linearGradient = nil; source.raster = RasterMaskPayload(width: 1, height: 1, alpha: [0])
            }
            grade.masks.sources.append(source)
        }
    }

    func removeMaskSource(gradeID: UUID, maskID: UUID) { mutateGrade(gradeID) { $0.masks.sources.removeAll { $0.id == maskID } } }
    func setMaskEnabled(gradeID: UUID, maskID: UUID, _ value: Bool) { mutateMask(gradeID, maskID) { $0.enabled = value } }
    func setGradientEndpoints(gradeID: UUID, maskID: UUID, start: NormalizedPoint, end: NormalizedPoint) {
        mutateMask(gradeID, maskID) { source in
            guard source.kind == .linearGradient else { return }
            var geometry = source.linearGradient ?? LinearGradientMaskGeometry()
            geometry.start = start
            geometry.end = end
            source.linearGradient = geometry
        }
    }
    func setGradientCoordinate(gradeID: UUID, maskID: UUID, axis: String, value: Double) {
        mutateMask(gradeID, maskID) { source in
            guard source.kind == .linearGradient else { return }
            var geometry = source.linearGradient ?? LinearGradientMaskGeometry()
            let amount = max(0, min(1, value))
            switch axis {
            case "startX": geometry.start.x = amount
            case "startY": geometry.start.y = amount
            case "endX": geometry.end.x = amount
            case "endY": geometry.end.y = amount
            default: return
            }
            source.linearGradient = geometry
        }
    }
    @Published var isGradientMaskEditing = false
    @Published var activeLocalGradeID: UUID?
    @Published var isLensCenterEditing = false
    @Published var selectedGradientMaskID: UUID?

    func setMaskInverted(gradeID: UUID, maskID: UUID, _ value: Bool) { mutateMask(gradeID, maskID) { $0.inverted = value } }
    func setMaskOpacity(gradeID: UUID, maskID: UUID, _ value: Double) { mutateMask(gradeID, maskID) { $0.opacity = min(1, max(0, value)) } }
    func setMaskFeather(gradeID: UUID, maskID: UUID, _ value: Double) { mutateMask(gradeID, maskID) { $0.feather = min(1, max(0, value)) } }
    func setMaskBlendMode(gradeID: UUID, maskID: UUID, _ value: MaskBlendMode) { mutateMask(gradeID, maskID) { $0.blendMode = value } }

    func setRasterMask(gradeID: UUID, maskID: UUID, width: Int, height: Int, alpha: [UInt8]) {
        mutateMask(gradeID, maskID) { source in
            source.kind = .raster
            source.raster = RasterMaskPayload(width: width, height: height, alpha: alpha)
        }
    }

    private func mutateMask(_ gradeID: UUID, _ maskID: UUID, _ body: (inout MaskSourceRecord) -> Void) {
        mutateGrade(gradeID) { grade in
            guard let index = grade.masks.sources.firstIndex(where: { $0.id == maskID }) else { return }
            body(&grade.masks.sources[index])
            grade.masks.sources[index].normalize()
        }
    }

    private func mutateGrade(_ gradeID: UUID, _ body: (inout LocalGradeRecord) -> Void) {
        mutateMaskLook { look in
            guard let index = look.localGrades?.firstIndex(where: { $0.id == gradeID }) else { return }
            body(&look.localGrades![index])
            look.localGrades![index].normalize()
        }
    }

    private func mutateMaskLook(_ body: (inout RenderLook) -> Void) {
        guard let i = selectedIndex else { return }
        undoStack.append(project.images[i].look)
        redoStack.removeAll()
        body(&project.images[i].look)
        project.images[i].look.normalizeForProOnly()
        maskOverlayRevision &+= 1
        requestPreviewRefresh()
    }

    // MARK: - Stage 3 canonical semantic masks
    // Monotonic mask-geometry revision. Do NOT use the large raster arrays as a SwiftUI
    // task/hash identity: that rehashes megabytes of mask data on every viewer update.
    @Published var maskOverlayRevision = 0
    private var pendingNewSemanticKind: SemanticMaskKind?
    private var pendingSemanticComponent: (kind: SemanticMaskKind, gradeID: UUID, blend: MaskBlendMode)?
    @Published var semanticMaskStatus = "AI masks idle"
    @Published var semanticMasks: CanonicalSemanticMaskSet?
    @Published var objectMaskPickGradeID: UUID?
    @Published var objectMaskPickBlendMode: MaskBlendMode = .add
    private let semanticMaskEngine = SemanticMaskEngine()
    private var semanticMaskTask: Task<Void, Never>?
    // A disk/memory preview cache hit may display before the original source buffer
    // is decoded. Queue analysis for the NEXT true pre-geometry source frame.
    private var semanticAnalysisDeferred = false

    var isObjectMaskPicking: Bool { objectMaskPickGradeID != nil }

    // Called from the Masks tab. Does not require returning to Main Image.
    func createSemanticLocalGrade(_ kind: SemanticMaskKind) {
        guard semanticMasks?.alpha(kind) != nil else {
            pendingNewSemanticKind = kind
            pendingSemanticComponent = nil
            refreshCanonicalSemanticMasks()
            return
        }
        let gradeID = addLocalGrade()
        selectLocalGrade(gradeID)
        UserDefaults.standard.set(true, forKey: "SpektraFilmFast.maskOverlayEnabled")
        addSemanticMask(kind, to: gradeID)
    }

    func requestSemanticMask(_ kind: SemanticMaskKind, gradeID: UUID, blend: MaskBlendMode) {
        guard semanticMasks?.alpha(kind) != nil else {
            pendingNewSemanticKind = nil
            pendingSemanticComponent = (kind, gradeID, blend)
            refreshCanonicalSemanticMasks()
            return
        }
        addSemanticMask(kind, to: gradeID, blendMode: blend)
    }

    func refreshCanonicalSemanticMasks() {
        semanticMaskTask?.cancel()
        guard let image = selectedImage else {
            semanticMaskStatus = "Select a photo first"
            return
        }
        // NEVER segment displayed sourcePreview/renderedPreview: both already contain
        // the crop/perspective transform, while masks modify pixels before that transform.
        // The semantic model must see source pixels at the exact mask coordinate origin.
        guard let source = latestSourceBuffer else {
            semanticAnalysisDeferred = true
            semanticMaskStatus = "Preparing untransformed source for AI selection…"
            requestPreviewRefresh()
            return
        }
        guard let cg = source.makeCGImage8(colorSpace: OutputColorProfile.inputLinearRec2020) else {
            semanticMaskStatus = "Could not create pre-geometry AI input image"
            return
        }
        semanticAnalysisDeferred = false
        let imageID = image.id
        // This CGImage uses the same PRE-geometry coordinates as local grade and export.
        semanticMaskStatus = "Analyzing skin / requested selection…"
        var requested: Set<SemanticMaskKind> = [.skin]
        if let kind = pendingNewSemanticKind { requested.insert(kind) }
        if let component = pendingSemanticComponent { requested.insert(component.kind) }
        semanticMaskTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await semanticMaskEngine.analyze(imageURL: image.url, cgImage: cg, requested: requested)
                guard !Task.isCancelled, project.selectedImageID == imageID else { return }
                semanticMasks = result
                if let skin = result.alpha(.skin) {
                    latestSkinMaskWidth = result.width
                    latestSkinMaskHeight = result.height
                    latestSkinMaskAlpha = skin
                }
                semanticMaskStatus = "AI masks ready · \(result.provenance.joined(separator: " + "))"
                if let requested = pendingNewSemanticKind {
                    pendingNewSemanticKind = nil
                    if result.alpha(requested) != nil { createSemanticLocalGrade(requested) }
                    else { semanticMaskStatus = "\(requested.rawValue) unavailable; model is missing" }
                }
                if let component = pendingSemanticComponent {
                    pendingSemanticComponent = nil
                    if result.alpha(component.kind) != nil {
                        addSemanticMask(component.kind, to: component.gradeID, blendMode: component.blend)
                    } else {
                        semanticMaskStatus = "\(component.kind.rawValue) unavailable; model is missing"
                    }
                }
                refreshStudioAnalysis()
                requestEditorScopeUpdate()
            } catch {
                pendingNewSemanticKind = nil
                pendingSemanticComponent = nil
                semanticMaskStatus = "AI masks unavailable · \(error.localizedDescription)"
            }
        }
    }

    func addSemanticMask(_ kind: SemanticMaskKind, to gradeID: UUID, blendMode: MaskBlendMode = .add) {
        guard let set = semanticMasks, let alpha = set.alpha(kind) else {
            semanticMaskStatus = "Run Analyze Masks first"
            return
        }
        // The canonical SemanticMaskEngine already refines skin where appropriate.
        // A second generic blur/erode pass destroys hair strands, fingers and small gaps.
        // Local editing and viewer overlay must use the exact same immutable alpha.
        let refined = alpha
        mutateGrade(gradeID) { grade in
            var source = MaskSourceRecord(name: kind.rawValue, kind: .raster)
            source.blendMode = blendMode
            source.raster = RasterMaskPayload(width: set.width, height: set.height, alpha: refined)
            grade.masks.sources.append(source)
        }
    }

    @Published var maskBrushSize = 0.025
    private var maskBrushTask: Task<Void, Never>?

    func beginMaskBrush(gradeID: UUID? = nil, blend: MaskBlendMode = .add, newGrade: Bool = false) {
        let id = gradeID ?? (newGrade ? nil : activeLocalGradeID) ?? addLocalGrade()
        selectLocalGrade(id)
        beginObjectMaskPick(gradeID: id, blendMode: blend)
        objectSelectionTool = "Paint"
        UserDefaults.standard.set(true, forKey: "SpektraFilmFast.maskOverlayEnabled")
        semanticMaskStatus = "Paint to add coverage · Option to subtract · Done to finish"
    }

    private func paintMaskStroke(_ points: [ImagePoint], gradeID: UUID, subtract: Bool) {
        guard let input = latestSourceBuffer else { return }
        let blend: MaskBlendMode = subtract ? .subtract : objectMaskPickBlendMode
        let name = blend == .subtract ? "Brush Subtract" : "Brush Add"
        let imageID = project.selectedImageID
        let radius = maskBrushSize
        let previous = maskBrushTask
        maskBrushTask = Task { [weak self] in
            await previous?.value
            guard let self, project.selectedImageID == imageID,
                  let grade = selectedLook.localGrades?.first(where: { $0.id == gradeID }) else { return }
            let existing = grade.masks.sources.last(where: { $0.name == name && $0.aiRecipe == nil && $0.kind == .raster })
            let oppositeName = blend == .subtract ? "Brush Add" : "Brush Subtract"
            let opposite = grade.masks.sources.last(where: { $0.name == oppositeName && $0.aiRecipe == nil && $0.kind == .raster })
            let scale = min(1, 2048.0 / Double(max(input.width, input.height)))
            let width = existing?.raster?.width ?? max(1, Int(Double(input.width) * scale))
            let height = existing?.raster?.height ?? max(1, Int(Double(input.height) * scale))
            do {
                let (raster, clearedOpposite) = try await Task.detached(priority: .userInitiated) {
                    let raster = try MaskBrushEngine.shared.paint(existing?.raster, width: width, height: height, points: points, radius: radius)
                    let cleared = try opposite?.raster.map { prior in
                        try MaskBrushEngine.shared.paint(prior, width: prior.width, height: prior.height, points: points, radius: radius, erase: true)
                    }
                    return (raster, cleared)
                }.value
                guard project.selectedImageID == imageID else { return }
                mutateGrade(gradeID) { grade in
                    if let id = opposite?.id, let clearedOpposite, let index = grade.masks.sources.firstIndex(where: { $0.id == id }) {
                        grade.masks.sources[index].raster = clearedOpposite
                    }
                    if let id = existing?.id, let index = grade.masks.sources.firstIndex(where: { $0.id == id }) {
                        grade.masks.sources[index].raster = raster
                    } else {
                        var source = MaskSourceRecord(name: name, kind: .raster)
                        source.feather = 0; source.blendMode = blend; source.raster = raster
                        grade.masks.sources.append(source)
                    }
                }
                semanticMaskStatus = "Brush saved · paint again or choose Done"
            } catch { semanticMaskStatus = error.localizedDescription }
        }
    }

    func beginObjectMaskPick(gradeID: UUID, blendMode: MaskBlendMode) {
        guard frameState.renderedPreview != nil else {
            semanticMaskStatus = "Render a preview before selecting an object"
            return
        }
        objectMaskPickGradeID = gradeID
        objectMaskPickBlendMode = blendMode
        semanticMaskStatus = "Hover to preview · Click, box or brush to add · Option removes · Done to finish"
    }

    func cancelObjectMaskPick() {
        objectMaskPickGradeID = nil
        previewObjectMask(at: nil)
        semanticMaskStatus = "Object selection finished"
    }

    @Published var objectSelectionTool = "Click"
    @Published var objectHoverMask: RasterMaskPayload?
    private var objectHoverTask: Task<Void, Never>?
    private var objectHoverGeneration = 0

    private func maskSourcePoint(_ point: CGPoint) -> ImagePoint? {
        guard let source = latestSourceBuffer,
              let converted = GeometryEngine.sourceNormalizedPoint(fromDisplay: point,
                sourceWidth: source.width, sourceHeight: source.height, settings: selectedLook.geometry) else { return nil }
        return ImagePoint(x: converted.x, y: converted.y)
    }

    func previewObjectMask(at point: CGPoint?) {
        objectHoverTask?.cancel()
        objectHoverGeneration &+= 1
        let generation = objectHoverGeneration
        guard let point, let source = maskSourcePoint(point), let image = selectedImage else {
            objectHoverMask = nil; return
        }
        objectHoverTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(160))
                let mask = try await RedlampMaskService.shared.previewObject(AIMaskRecipe(kind: .objects, prompts: [source]), url: image.url)
                guard !Task.isCancelled, generation == objectHoverGeneration, project.selectedImageID == image.id else { return }
                objectHoverMask = RasterMaskPayload(width: mask.width, height: mask.height, alpha: mask.pixels)
            } catch { /* Hover is provisional; clicking reports actionable errors. */ }
        }
    }

    func completeObjectMaskPick(normalizedPoint: CGPoint) {
        completeObjectMaskGesture(points: [normalizedPoint], box: false, subtract: false)
    }

    func completeObjectMaskGesture(points: [CGPoint], box: Bool, subtract: Bool) {
        guard let gradeID = objectMaskPickGradeID else { return }
        let converted = points.compactMap(maskSourcePoint)
        guard !converted.isEmpty else { return }
        previewObjectMask(at: nil)
        if objectSelectionTool == "Paint" || objectSelectionTool == "Brush" {
            paintMaskStroke(converted, gradeID: gradeID, subtract: subtract)
            return
        }
        
        if objectSelectionTool == "Refine Edge" {
            guard let source = activeLocalGrade?.masks.sources.last(where: { $0.aiRecipe != nil }) else { return }
            refineAIMask(gradeID: gradeID, sourceID: source.id,
                         stroke: BrushStroke(points: converted, size: 0.025))
            return
        }
        if !box, let existing = activeLocalGrade?.masks.sources.last(where: { $0.aiRecipe?.kind == .objects }),
           var recipe = existing.aiRecipe {
            let count = min(8, converted.count)
            let samples = (0..<count).map { converted[$0 * max(1, converted.count - 1) / max(1, count - 1)] }
            if subtract { recipe.excluded.append(contentsOf: samples) }
            else { recipe.prompts.append(contentsOf: samples) }
            let reserved = recipe.box == nil ? 0 : 2
            recipe.excluded = Array(recipe.excluded.suffix(7))
            let room = max(1, 16 - reserved - recipe.excluded.count)
            if recipe.prompts.count > room { recipe.prompts = [recipe.prompts[0]] + recipe.prompts.suffix(room - 1) }
            createAIMask(recipe, gradeID: gradeID, sourceID: existing.id)
            return
        }
        var recipe = AIMaskRecipe(kind: .objects)
        if box, converted.count >= 2 {
            let xs = converted.map(\.x), ys = converted.map(\.y)
            recipe.box = ImageRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        } else {
            // SAM accepts at most 16 prompts. Spread brush samples over the stroke.
            let count = min(16, converted.count)
            recipe.prompts = (0..<count).map { converted[$0 * max(1, converted.count - 1) / max(1, count - 1)] }
        }
        createAIMask(recipe, gradeID: gradeID, blend: subtract ? .subtract : objectMaskPickBlendMode)
    }

    func createAIMask(_ recipe: AIMaskRecipe, gradeID: UUID? = nil, blend: MaskBlendMode = .add, presetTone: ToneSettings? = nil, sourceID: UUID? = nil) {
        guard let image = selectedImage else { semanticMaskStatus = "Select a photo first"; return }
        semanticMaskTask?.cancel()
        semanticMaskStatus = "Computing \(recipe.kind.name)…"
        semanticMaskTask = Task { [weak self] in
            guard let self else { return }
            do {
                let results = try await RedlampMaskService.shared.compute(recipe, url: image.url)
                guard !Task.isCancelled, project.selectedImageID == image.id else { return }
                for result in results {
                    let target = gradeID ?? addLocalGrade()
                    selectLocalGrade(target)
                    mutateGrade(target) { grade in
                        if gradeID == nil { grade.name = recipe.kind == .people ? (recipe.part.name + (result.instance.map { " \($0)" } ?? "")) : recipe.kind.name }
                        if let presetTone { grade.tone = presetTone }
                        var source = MaskSourceRecord(name: recipe.kind.name, kind: .raster)
                        var stored = recipe
                        stored.instance = result.instance; stored.provider = result.provider
                        source.aiRecipe = stored; source.feather = 0; source.blendMode = blend
                        source.raster = RasterMaskPayload(width: result.mask.width, height: result.mask.height, alpha: result.mask.pixels)
                        if let sourceID, let index = grade.masks.sources.firstIndex(where: { $0.id == sourceID }) {
                            source.id = sourceID
                            source.opacity = grade.masks.sources[index].opacity
                            source.inverted = grade.masks.sources[index].inverted
                            source.blendMode = grade.masks.sources[index].blendMode
                            grade.masks.sources[index] = source
                        } else { grade.masks.sources.append(source) }
                    }
                }
                semanticMaskStatus = "\(recipe.kind.name) ready · saved with the photo"
            } catch { if !Task.isCancelled { semanticMaskStatus = String(describing: error) } }
        }
    }

    func updateAIMasks() {
        guard let image = selectedImage else { return }
        let grades = image.look.localGrades ?? []
        semanticMaskTask?.cancel()
        semanticMaskStatus = "Updating AI masks…"
        semanticMaskTask = Task { [weak self] in
            guard let self else { return }
            do {
                await RedlampMaskService.shared.invalidateComputedMasks()
                var replacements: [(UUID, UUID, RasterMaskPayload)] = []
                for grade in grades { for source in grade.masks.sources {
                    guard let recipe = source.aiRecipe else { continue }
                    let masks = try await RedlampMaskService.shared.compute(recipe, url: image.url)
                    guard let mask = masks.first(where: { $0.instance == recipe.instance })?.mask ?? masks.first?.mask else { continue }
                    replacements.append((grade.id, source.id, RasterMaskPayload(width: mask.width, height: mask.height, alpha: mask.pixels)))
                    try Task.checkCancellation()
                } }
                guard project.selectedImageID == image.id else { return }
                // Commit the complete update atomically, with one undo step.
                mutateMaskLook { look in
                    for (gradeID, sourceID, payload) in replacements {
                        guard let g = look.localGrades?.firstIndex(where: { $0.id == gradeID }),
                              let m = look.localGrades?[g].masks.sources.firstIndex(where: { $0.id == sourceID }) else { continue }
                        look.localGrades![g].masks.sources[m].raster = payload
                    }
                }
                semanticMaskStatus = "Updated \(replacements.count) AI masks"
            } catch { if !Task.isCancelled { semanticMaskStatus = "Masks kept · \(error)" } }
        }
    }

    func applyMaskPreset(_ preset: StudioMaskPreset) {
        guard let image = selectedImage else { return }
        // Fail fast with the real reason instead of starting a task that ends in a
        // generic "Preset unavailable" after a long wait.
        if let reason = preset.unavailableReason {
            semanticMaskStatus = "\(preset.name) unavailable · \(reason)"
            return
        }
        semanticMaskTask?.cancel()
        semanticMaskStatus = "Computing \(preset.name)…"
        semanticMaskTask = Task { [weak self] in
            guard let self else { return }
            do {
                var grade = preset.grade
                grade.id = UUID(); grade.name = preset.name
                for index in grade.masks.sources.indices {
                    grade.masks.sources[index].id = UUID()
                    guard let recipe = grade.masks.sources[index].aiRecipe else { continue }
                    let masks = try await RedlampMaskService.shared.compute(recipe, url: image.url)
                    guard let first = masks.first?.mask else { throw MaskComputationError.nothingFound(recipe.kind) }
                    let combined = masks.dropFirst().reduce(first) { $0.union($1.mask) }
                    grade.masks.sources[index].raster = RasterMaskPayload(width: combined.width, height: combined.height, alpha: combined.pixels)
                }
                try Task.checkCancellation()
                guard project.selectedImageID == image.id else { return }
                let completed = grade
                mutateMaskLook { look in
                    if look.localGrades == nil { look.localGrades = [] }
                    look.localGrades!.append(completed)
                }
                selectLocalGrade(grade.id)
                semanticMaskStatus = "\(preset.name) applied"
            } catch { if !Task.isCancelled { semanticMaskStatus = "Preset unavailable · \(error)" } }
        }
    }

    func setLocalMaskColor(_ gradeID: UUID, key: String, value: Double) {
        mutateGrade(gradeID) { grade in
            var colour = grade.localColor ?? LocalMaskColorSettings()
            let value = min(100, max(-100, value))
            switch key {
            case "Saturation": colour.saturation = value
            case "Temperature": colour.temperature = value
            case "Texture": colour.texture = value
            default: colour.clarity = value
            }
            grade.localColor = colour
        }
    }

    func setDepthMaskRange(gradeID: UUID, sourceID: UUID, lower: Double? = nil, upper: Double? = nil) {
        mutateGrade(gradeID) { grade in
            guard let index = grade.masks.sources.firstIndex(where: { $0.id == sourceID }),
                  var recipe = grade.masks.sources[index].aiRecipe else { return }
            if let lower { recipe.depthLower = min(recipe.depthUpper, max(0, lower)) }
            if let upper { recipe.depthUpper = max(recipe.depthLower, min(1, upper)) }
            grade.masks.sources[index].aiRecipe = recipe
        }
    }

    func setAIMaskShape(gradeID: UUID, sourceID: UUID, feather: Double? = nil, edge: Double? = nil) {
        mutateGrade(gradeID) { grade in
            guard let m = grade.masks.sources.firstIndex(where: { $0.id == sourceID }),
                  var recipe = grade.masks.sources[m].aiRecipe else { return }
            if let feather { recipe.feather = min(100, max(0, feather)) }
            if let edge { recipe.edge = min(100, max(-100, edge)) }
            grade.masks.sources[m].aiRecipe = recipe
        }
    }

    func refineAIMask(gradeID: UUID, sourceID: UUID, stroke: BrushStroke? = nil) {
        guard let image = selectedImage,
              let source = image.look.localGrades?.first(where: { $0.id == gradeID })?.masks.sources.first(where: { $0.id == sourceID }),
              let raster = source.raster, var recipe = source.aiRecipe else { return }
        if let stroke { recipe.refineStrokes.append(stroke) }
        semanticMaskTask?.cancel()
        semanticMaskStatus = "Refining edges…"
        let savedRecipe = recipe
        semanticMaskTask = Task { [weak self] in
            guard let self else { return }
            do {
                let refined = try await RedlampMaskService.shared.refine(raster, recipe: savedRecipe, url: image.url, onlyStrokes: stroke != nil)
                guard !Task.isCancelled, project.selectedImageID == image.id else { return }
                mutateGrade(gradeID) { grade in
                    guard let index = grade.masks.sources.firstIndex(where: { $0.id == sourceID }) else { return }
                    grade.masks.sources[index].raster = RasterMaskPayload(width: refined.width, height: refined.height, alpha: refined.pixels)
                    grade.masks.sources[index].aiRecipe = savedRecipe
                }
                semanticMaskStatus = "Edges refined"
            } catch { if !Task.isCancelled { semanticMaskStatus = "Edges kept · \(error)" } }
        }
    }

    @Published var rawDenoiseStatus = ""
    @Published var isPreparingRawDenoise = false
    @Published var cacheHealthStatus = ""
    let rawDenoiseService = RawForgeDenoiseService()

    func prepareRawDenoiseForSelected() {
        guard !isPreparingRawDenoise, let image = selectedImage, image.look.raw.denoiseMode != .off else { return }
        isPreparingRawDenoise = true
        rawDenoiseStatus = "Preparing RAW-domain denoise…"
        let imageID = image.id
        Task { [weak self] in
            guard let self else { return }
            defer { if project.selectedImageID == imageID { isPreparingRawDenoise = false } }
            do {
                let url = try await rawDenoiseService.prepare(source: image.url, raw: image.look.raw, iso: image.metadata?.iso)
                guard project.selectedImageID == imageID else { return }
                rawDenoiseStatus = "Prepared \(url.lastPathComponent) · exact preview/export now use the denoised CFA DNG"
                semanticMasks = nil
                await semanticMaskEngine.invalidate(imageURL: image.url)
                removeRenderedFrames(for: imageID)
                scheduleRender(interactive: false, reason: "RAW denoise prepared")
            } catch { rawDenoiseStatus = error.localizedDescription }
        }
    }

    func clearRawDenoiseCache() {
        Task { [weak self] in
            guard let self else { return }
            do { try await rawDenoiseService.clear(); rawDenoiseStatus = "RAW denoise cache cleared"; if let id=project.selectedImageID { removeRenderedFrames(for:id) }; requestPreviewRefresh() }
            catch { rawDenoiseStatus = error.localizedDescription }
        }
    }

    func effectiveSourceURL(for image: ProjectImageRecord) -> URL {
        RawForgeDenoiseService.cacheURL(source: image.url, raw: image.look.raw, iso: image.metadata?.iso) ?? image.url
    }

    func setRawDenoiseMode(_ mode: RawDenoiseMode) {
        setRawSettings({ $0.denoiseMode = mode }, interactive: false)
        semanticMasks = nil
        if let image = selectedImage { Task { await semanticMaskEngine.invalidate(imageURL: image.url) } }
        rawDenoiseStatus = mode == .off ? "RAW denoise off" : "Denoise settings changed · prepare cache to activate"
        if mode == .auto { prepareRawDenoiseForSelected() }
    }
    func setRawDenoiseLuma(_ value: Double) { setRawSettings({ $0.denoiseLuma = min(1,max(0,value)) }, interactive:false) }
    func setRawDenoiseChroma(_ value: Double) { setRawSettings({ $0.denoiseChroma = min(1,max(0,value)) }, interactive:false) }

    func setLensEffectsSettings(interactive: Bool = false, _ body: (inout LensEffectsSettings) -> Void) {
        guard let i = selectedIndex else { return }
        if interactive {
            if gestureWorkingLook == nil { beginEditGesture() }
            if gestureWorkingLook?.lensEffects == nil { gestureWorkingLook?.lensEffects = LensEffectsSettings() }
            body(&gestureWorkingLook!.lensEffects!)
            activeEditChangedParameter = "lensEffects"
            publishInteractiveProxy(changedParameter: "lensEffects", rawField: nil)
            return
        }
        undoStack.append(project.images[i].look); redoStack.removeAll()
        if project.images[i].look.lensEffects == nil { project.images[i].look.lensEffects = LensEffectsSettings() }
        body(&project.images[i].look.lensEffects!)
        semanticMasks = nil
        let imageURL = project.images[i].url
        Task { await semanticMaskEngine.invalidate(imageURL: imageURL) }
        scheduleIdleRefinement(changedParameter: "lensEffects")
    }

    func setFilmEffectsSettings(interactive: Bool = false, _ body: (inout FilmEffectsSettings) -> Void) {
        guard let i = selectedIndex else { return }
        if interactive {
            if gestureWorkingLook == nil { beginEditGesture() }
            if gestureWorkingLook?.filmEffects == nil { gestureWorkingLook?.filmEffects = FilmEffectsSettings() }
            body(&gestureWorkingLook!.filmEffects!)
            activeEditChangedParameter = "filmEffects"
            if let look = gestureWorkingLook { publishLocalGradePreview(look: look) }
            return
        }
        undoStack.append(project.images[i].look); redoStack.removeAll()
        if project.images[i].look.filmEffects == nil { project.images[i].look.filmEffects = FilmEffectsSettings() }
        body(&project.images[i].look.filmEffects!)
        semanticMasks = nil
        let imageURL = project.images[i].url
        Task { await semanticMaskEngine.invalidate(imageURL: imageURL) }
        scheduleIdleRefinement(changedParameter: "filmEffects")
    }

    func validateCacheHealth() {
        let fm = FileManager.default
        let renderRoot = cacheRootPath.isEmpty ? nil : URL(fileURLWithPath: cacheRootPath)
        let rawRoot = RawForgeDenoiseService.cacheRoot()
        let aiRoot = Bundle.main.resourceURL?.appendingPathComponent("AIModels")
        var parts:[String]=[]
        if let renderRoot { parts.append(fm.isWritableFile(atPath:renderRoot.path) ? "render cache writable" : "render cache NOT writable") }
        parts.append(renderRoot?.standardizedFileURL.path == rawRoot.standardizedFileURL.path ? "ERROR: RawForge overlaps render cache" : "RawForge cache isolated")
        if let aiRoot { parts.append(aiRoot.standardizedFileURL.path == rawRoot.standardizedFileURL.path ? "ERROR: AI models overlap RawForge cache" : "AI models isolated") }
        parts.append("semantic masks: memory-only cache")
        cacheHealthStatus = parts.joined(separator: " · ")
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

                var solverSemantic = semanticMasks
                if solverSemantic == nil, let preview = frameState.renderedPreview {
                    solverSemantic = try await semanticMaskEngine.analyze(imageURL: image.url, cgImage: preview)
                    semanticMasks = solverSemantic
                }
                guard let solverSet = solverSemantic, let solverSkin = solverSet.alpha(.skin) else {
                    throw NSError(domain: "SpektraFilmFast.SkinWB", code: 10, userInfo: [NSLocalizedDescriptionKey: "Canonical Skin Only mask is unavailable. Run Analyze Masks first."])
                }
                let solverSkinPayload = CanonicalSkinMaskPayload(width: solverSet.width, height: solverSet.height, alpha: solverSkin)

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
                        exactLinear.applyingHostAndFilmGrade(
                            tone: look.tone,
                            density: look.colorDensity, film: look.filmTone)
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
                        maxLongEdge: 640,
                        canonicalSkinMask: solverSkinPayload
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

    private func mutateRawDevelop(interactive: Bool, changedParameter: String, _ mutate: (inout RawSettings) -> Void) {
        guard let i = selectedIndex else { return }
        if interactive {
            if gestureWorkingLook == nil { beginEditGesture() }
            guard var working = gestureWorkingLook else { return }
            mutate(&working.raw)
            gestureWorkingLook = working
            activeEditChangedParameter = changedParameter
            publishInteractiveProxy(changedParameter: changedParameter, rawField: nil)
            scheduleRender(interactive: true, changedParameter: changedParameter, longEdgeOverride: min(720, project.preferences.previewLongEdge), cacheResult: false, reason: "RAW develop interactive", useInteractiveRenderPolicy: false, lookOverride: working)
            return
        }
        cancelIdleRefinement()
        if activeEditBaseline == nil { undoStack.append(project.images[i].look); redoStack.removeAll() }
        mutate(&project.images[i].look.raw)
        propagateBatchEdit(from: project.images[i].look, activeIndex: i, changedParameter: changedParameter)
        scheduleIdleRefinement(changedParameter: changedParameter, delayMilliseconds: 20)
    }

    func setRawDevelopExposure(_ value: Double, interactive: Bool) { mutateRawDevelop(interactive: interactive, changedParameter: "rawDevelopExposure") { $0.developExposureEV=min(5,max(-5,value)) } }
    func setRawDevelopGlobalTone(_ value: Double, interactive: Bool) { mutateRawDevelop(interactive: interactive, changedParameter: "rawDevelopGlobalTone") { $0.developGlobalTone=min(1,max(0,value)) } }
    func setRawDevelopShadowBoost(_ value: Double, interactive: Bool) { mutateRawDevelop(interactive: interactive, changedParameter: "rawDevelopShadowBoost") { $0.developShadowBoost=min(2,max(0,value)) } }
    func setRawDevelopHighlightHeadroom(_ value: Double, interactive: Bool) { mutateRawDevelop(interactive: interactive, changedParameter: "rawDevelopHeadroom") { $0.developHighlightHeadroom=min(2,max(0,value)) } }
    func setRawDevelopCurvePoints(_ points: [ToneCurvePoint], interactive: Bool) { let n=ToneCurveMath.normalize(points); mutateRawDevelop(interactive: interactive, changedParameter: "rawDevelopCurve") { $0.developCurvePoints=n } }
    func applyRawDevelopCurvePreset(_ preset: ToneCurvePreset) { setRawDevelopCurvePoints(preset.points, interactive: false) }
    func resetRawDevelopCurve() { setRawDevelopCurvePoints([.init(x:0,y:0),.init(x:1,y:1)], interactive:false) }
    func resetRawDevelop() {
        guard let i=selectedIndex else { return }
        cancelIdleRefinement(); undoStack.append(project.images[i].look); redoStack.removeAll()
        project.images[i].look.raw.developExposureEV=0; project.images[i].look.raw.developGlobalTone=1; project.images[i].look.raw.developShadowBoost=1; project.images[i].look.raw.developHighlightHeadroom=0; project.images[i].look.raw.developCurvePoints=[.init(x:0,y:0),.init(x:1,y:1)]; project.images[i].look.tone=ToneSettings()
        scheduleIdleRefinement(changedParameter:"rawDevelopReset",delayMilliseconds:20)
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


    // Film-feed adjustments are intentionally distinct from the scene grade.
    // They settle through the exact spectral renderer; never persist a proxy.
    func setFilmToneValue(_ key: String, value: Double, interactive: Bool) {
        guard let i = selectedIndex else { return }
        func change(_ tone: inout ToneSettings) {
            switch key {
            case "highlights": tone.highlights = min(100, max(-100, value))
            case "highlightRecovery": tone.highlightRecovery = min(100, max(0, value))
            case "shadows": tone.shadows = min(100, max(-100, value))
            case "shadowRecovery": tone.shadowRecovery = min(100, max(0, value))
            case "whites": tone.whites = min(100, max(-100, value))
            case "blacks": tone.blacks = min(100, max(-100, value))
            case "contrast": tone.contrast = min(100, max(-100, value))
            case "brightness": tone.brightness = min(100, max(-100, value))
            case "autoContrast": tone.autoContrast = value > 0.5
            default: return
            }
        }
        if interactive {
            if gestureWorkingLook == nil { beginEditGesture() }
            guard var working = gestureWorkingLook else { return }
            var film = working.filmTone ?? ToneSettings()
            change(&film)
            if key != "autoContrast" { film.autoContrast = false; working.tone?.autoContrast = false }
            working.filmTone = film
            gestureWorkingLook = working
            activeEditChangedParameter = "filmStockShape." + key
            // Immediate proxy, followed by an accurate coalesced render through the same
            // scene-linear host grade + native film path used by the settled frame.
            publishInteractiveProxy(changedParameter: activeEditChangedParameter, rawField: nil)
            if key != "autoContrast" {
                scheduleRender(
                    interactive: true,
                    changedParameter: activeEditChangedParameter,
                    longEdgeOverride: min(720, project.preferences.previewLongEdge),
                    cacheResult: false,
                    reason: "accurate film feed preview",
                    useInteractiveRenderPolicy: false,
                    lookOverride: working
                )
            }
            status = "Film feed · accurate preview updating"
            return
        }
        cancelIdleRefinement()
        if activeEditBaseline == nil {
            undoStack.append(project.images[i].look)
            redoStack.removeAll()
        }
        var film = project.images[i].look.filmTone ?? ToneSettings()
        change(&film)
        if key != "autoContrast" { film.autoContrast = false; project.images[i].look.tone?.autoContrast = false }
        project.images[i].look.filmTone = film
        scheduleIdleRefinement(changedParameter: "filmStockShape." + key, delayMilliseconds: 40)
    }

    func resetFilmTone() {
        guard let i = selectedIndex else { return }
        cancelIdleRefinement()
        undoStack.append(project.images[i].look)
        redoStack.removeAll()
        project.images[i].look.filmTone = ToneSettings()
        scheduleIdleRefinement(changedParameter: "filmStockShape.reset")
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
            if changedParameter != "hostAutoContrast" { tone.autoContrast = false }
            working.tone = tone
            gestureWorkingLook = working
            activeEditChangedParameter = changedParameter
            // Scene Exposure EV has an exact multiplicative proxy. Zone-dependent controls
            // need the true pre-film working buffer or they can look dead/snap on release.
            publishInteractiveProxy(changedParameter: changedParameter, rawField: nil)
            if changedParameter != "hostExposure" && changedParameter != "hostAutoContrast" {
                scheduleRender(
                    interactive: true,
                    changedParameter: changedParameter,
                    longEdgeOverride: min(720, project.preferences.previewLongEdge),
                    cacheResult: false,
                    reason: "accurate scene tone preview",
                    useInteractiveRenderPolicy: false,
                    lookOverride: working
                )
            }
            return
        }

        cancelIdleRefinement()
        if activeEditBaseline == nil {
            undoStack.append(project.images[i].look)
            redoStack.removeAll()
        }
        var tone = project.images[i].look.tone ?? ToneSettings()
        mutate(&tone)
        if changedParameter != "hostAutoContrast" { tone.autoContrast = false }
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
        let clamped = min(0, max(-1, value))
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

        if lookCopyOptions.film { target.filmTone = source.filmTone; target.filmEffects = source.filmEffects }
        if lookCopyOptions.colorDensity { target.colorDensity = source.colorDensity }
        if lookCopyOptions.geometry { target.geometry = source.geometry }
        if lookCopyOptions.film { target.lensEffects = source.lensEffects }
        if lookCopyOptions.tone {
            target.localGrades = source.localGrades
            for g in target.localGrades?.indices ?? 0..<0 {
                for m in target.localGrades![g].masks.sources.indices where target.localGrades![g].masks.sources[m].aiRecipe != nil {
                    target.localGrades![g].masks.sources[m].raster = nil
                }
            }
        }

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
        guard var copiedLook, let activeIndex = selectedIndex else {
            status = "Copy edits first (⌘C), then paste (⌘V)"
            return
        }
        copiedLook.normalizeForProOnly()
        let ids = batchEditIDs
        undoStack.append(project.images[activeIndex].look)
        redoStack.removeAll()
        let autoWBSources = project.images.indices.filter { ids.contains(project.images[$0].id) &&
            lookCopyOptions.whiteBalance && copiedLook.raw.whiteBalanceMode == .auto }
        for index in project.images.indices where ids.contains(project.images[index].id) {
            // Copies editing MODE and relative offsets, never freezes a source photo's
            // measured auto WB, auto exposure, or auto contrast into a different photo.
            let merged = mergedLookForPaste(source: copiedLook, target: project.images[index].look)
            project.images[index].look = merged
        }
        let affected = project.images.filter { ids.contains($0.id) }
        let autoURLs = autoWBSources.map { project.images[$0].url }
        // A previous preview could race the cache reset and reuse stale auto values.
        // Invalidate *all* destination caches before scheduling the settled render.
        status = "Pasting to \(affected.count) photo(s) · recalculating automatic edits…"
        let selectedAtPaste = project.selectedImageID
        Task { [weak self] in
            guard let self else { return }
            for url in autoURLs { await decoder.invalidateAutoWhiteBalance(url: url) }
            for image in affected {
                for grade in image.look.localGrades ?? [] { for source in grade.masks.sources {
                    guard let recipe = source.aiRecipe else { continue }
                    do {
                        let results = try await RedlampMaskService.shared.compute(recipe, url: image.url)
                        guard let mask = results.first?.mask,
                              let p = project.images.firstIndex(where: { $0.id == image.id }),
                              let g = project.images[p].look.localGrades?.firstIndex(where: { $0.id == grade.id }),
                              let m = project.images[p].look.localGrades?[g].masks.sources.firstIndex(where: { $0.id == source.id }),
                              project.images[p].look.localGrades?[g].masks.sources[m].aiRecipe == recipe else { continue }
                        project.images[p].look.localGrades![g].masks.sources[m].raster = RasterMaskPayload(width: mask.width, height: mask.height, alpha: mask.pixels)
                    } catch { semanticMaskStatus = "Some pasted masks need a model: \(error)" }
                } }
                await renderedDiskCache.invalidate(url: image.url)
                removeRenderedFrames(for: image.id)
            }
            if project.selectedImageID == selectedAtPaste {
                refreshWhiteBalanceReference()
                scheduleIdleRefinement(changedParameter: "paste", delayMilliseconds: 30)
            }
            status = "Pasted \(affected.count) photo(s) · Auto WB/Exposure/Contrast evaluated per image"
        }
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

    private func scheduleLUTPrewarm(look: RenderLook, imageID: UUID, immediate: Bool = false) {
        lutPrewarmTask?.cancel()
        lutIsPreparing = false
        guard StudioSpectralLUT.selectedResolution() != nil else {
            lutPreparationStatus = "Native mode selected"
            return
        }
        guard GPULiveFramePipeline.supports(look), currentSourceSupportsGPULive,
              !project.preferences.bypassImportTransform else {
            lutPreparationStatus = "LUT unavailable for this RAW/effect configuration"
            return
        }
        // Automatic prep yields to interaction; pressing Prepare checks now.
        // Neither path ever runs from the pointer-rate live render callback.
        lutPreparationStatus = immediate ? "Checking LUT eligibility…" : "LUT queued for idle check"
        lutIsPreparing = true
        lutPrewarmTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                if !immediate { try await Task.sleep(for: .milliseconds(750)) }
                guard !Task.isCancelled, project.selectedImageID == imageID else { return }
                if let reason = try await gpuLivePipeline.lutBlockReason(look: look) {
                    guard !Task.isCancelled else { return }
                    lutPreparationStatus = "Cannot bake this look: \(reason). Native spectral processing remains active."
                    lutIsPreparing = false
                    return
                }
                lutPreparationStatus = "Loading cached LUT or generating film LUT…"
                let prepared = try await gpuLivePipeline.prewarmLUT(look: look)
                guard !Task.isCancelled, project.selectedImageID == imageID else { return }
                switch prepared {
                case .inMemory?: lutPreparationStatus = "Ready: GPU LUT already resident · next live edit"
                case .loadedFromDisk?: lutPreparationStatus = "Ready: LUT loaded from disk to GPU · next live edit"
                case .generatedAndSaved?: lutPreparationStatus = "Ready: LUT generated and saved · next live edit"
                case .generatedButNotSaved?: lutPreparationStatus = "Ready: GPU LUT generated; disk save failed"
                case nil: lutPreparationStatus = "Cannot use LUT for current look; see native renderer settings"
                }
                lutIsPreparing = false
            } catch is CancellationError {
                // Superseded by a newer edit or photo selection.
                if !Task.isCancelled { lutIsPreparing = false }
            } catch {
                if !Task.isCancelled && project.selectedImageID == imageID {
                    lutPreparationStatus = "LUT preparation failed: \(error.localizedDescription)"
                    lutIsPreparing = false
                }
            }
        }
    }

    func rendererPolicyDidChange() {
        cancelIdleRefinement()
        if selectedImage != nil { requestPreviewRefresh() }
        if StudioImportedLUT.isSelected {
            lutPreparationStatus = StudioImportedLUT.selectedURL() == nil
                ? "Imported LUT missing: choose a file in Settings"
                : "Imported LUT selected · active on next render"
            return
        }
        lutPrewarmTask?.cancel()
        lutPrewarmTask = nil
        lutIsPreparing = false
        guard let selected = selectedImage else {
            lutPreparationStatus = "Select a photograph to prepare a LUT"
            return
        }
        scheduleLUTPrewarm(look: selectedLook, imageID: selected.id)
    }

    /// Explicit Settings action: starts immediately and reports the exact reason
    /// it cannot run; unlike the automatic idle scheduler, it does not sleep.
    func prepareSelectedFilmLUT() {
        guard let selected = selectedImage else {
            lutPreparationStatus = "Select a photo first"
            return
        }
        scheduleLUTPrewarm(look: selectedLook, imageID: selected.id, immediate: true)
    }

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
        if interactive && currentSourceSupportsGPULive &&
           GPULiveFramePipeline.supports(lookOverride ?? gestureWorkingLook ?? selectedLook) {
            // AppModel's live Metal queue supersedes the 720px CPU-packaged
            // interactive exact render. The normal settled exact render remains.
            return
        }
        if interactive { cancelIdleRefinement() }
        renderGeneration += 1
        let request = PreviewRenderRequest(
            generation: renderGeneration,
            imageID: image.id,
            url: effectiveSourceURL(for: image),
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

    private struct GPULivePreviewRequest: Sendable {
        let generation: Int
        let imageID: UUID
        let url: URL
        let look: RenderLook
        let bypassImportTransform: Bool
    }

    private var currentSourceSupportsGPULive: Bool {
        guard let image = selectedImage else { return false }
        // JPEG/HEIC/TIFF cannot use the camera-space CIRAWFilter input path.
        // Those images remain editable through their existing exact pipeline.
        let rawExtensions: Set<String> = [
            "arw", "nef", "raf", "rw2", "orf", "dng", "cr2", "cr3", "pef",
            "srw", "iiq", "3fr", "fff", "erf", "mos", "mrw", "nrw"
        ]
        return rawExtensions.contains(URL(fileURLWithPath: image.sourcePath).pathExtension.lowercased())
    }

    private func scheduleGPULivePreview(look: RenderLook) {
        guard let image = selectedImage else { return }
        gpuPreviewGeneration &+= 1
        pendingGPUPreview = GPULivePreviewRequest(
            generation: gpuPreviewGeneration,
            imageID: image.id,
            url: effectiveSourceURL(for: image),
            look: look,
            bypassImportTransform: project.preferences.bypassImportTransform
        )
        if gpuPreviewTask == nil {
            gpuPreviewTask = Task { [weak self] in
                guard let self else { return }
                await self.runGPULiveLoop()
            }
        }
    }

    private func runGPULiveLoop() async {
        defer {
            gpuPreviewTask = nil
            if pendingGPUPreview != nil {
                gpuPreviewTask = Task { [weak self] in
                guard let self else { return }
                await self.runGPULiveLoop()
            }
            }
        }
        while !Task.isCancelled, let request = pendingGPUPreview {
            pendingGPUPreview = nil
            // Coalesce pointer-rate input; at most one native live render is
            // in progress, with only one replaceable pending slider state.
            try? await Task.sleep(for: .milliseconds(16))
            if Task.isCancelled { break }
            if pendingGPUPreview != nil { continue }
            do {
                let frame = try await gpuLivePipeline.render(
                    url: request.url,
                    look: request.look,
                    bypassImportTransform: request.bypassImportTransform,
                    decoder: decoder, longEdge: AppPreferences.editProxyLongEdge
                )
                guard !Task.isCancelled, request.generation == gpuPreviewGeneration,
                      request.imageID == project.selectedImageID,
                      gestureWorkingLook == request.look else { continue }
                liveGPUFrame = frame
                rendererPathStatus = frame.rendererLabel
                status = "\(frame.rendererLabel) · \(frame.texture.width) × \(frame.texture.height)"
                requestEditorScopeUpdate()
            } catch is CancellationError {
                break
            } catch {
                if request.generation == gpuPreviewGeneration {
                    status = "Metal live unavailable: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Pointer-rate feedback never enters the native spectral renderer. RapidRAW/Alcedo-style
    /// responsiveness comes from decoupling interaction from the expensive accuracy pass.
    private func publishInteractiveProxy(changedParameter: String?, rawField: RawInteractiveField?) {
        // The GPU path renders the actual film pipeline from cached camera RAW,
        // not a CPU pixel-level visual guess. Unported advanced stages retain
        // the existing exact pipeline until GPU parity is demonstrated.
        // The Metal CI render cannot express "no color match" (nil), so bypass
        // import transform keeps the existing exact interactive proxy.
        if let look = gestureWorkingLook, currentSourceSupportsGPULive,
           !project.preferences.bypassImportTransform,
           GPULiveFramePipeline.supports(look) {
            scheduleGPULivePreview(look: look)
            return
        }
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
            let checkpoint = GPUProcessingFailure.checkpoint()
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
            guard (try? GPUProcessingFailure.requireSuccess(after: checkpoint)) != nil,
                  !Task.isCancelled, generation == interactiveProxyGeneration,
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
                diagnosticStatus = "Full diagnostics settle with the exact render"
                analysisTask?.cancel()
            }
            requestEditorScopeUpdate()
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
                let hostCheckpoint = GPUProcessingFailure.checkpoint()
                let renderInput = try await Task.detached(priority: .userInitiated) {
                    let checkpoint = GPUProcessingFailure.checkpoint()
                    let graded = input.applyingHostAndFilmGrade(tone: request.look.tone, density: request.look.colorDensity, film: request.look.filmTone)
                    try GPUProcessingFailure.requireSuccess(after: checkpoint)
                    return graded
                }.value
                try GPUProcessingFailure.requireSuccess(after: hostCheckpoint)
                let filmOutput: PixelBufferF32
                let d: RenderDiagnosticsView
                if StudioImportedLUT.isSelected {
                    guard let file = StudioImportedLUT.selectedURL() else {
                        throw StudioImportedLUT.Failure.invalid("Link and select a LUT in Settings.")
                    }
                    let lutStarted = ProcessInfo.processInfo.systemUptime
                    filmOutput = try await StudioImportedLUTOffline.shared.render(renderInput, file: file)
                    d = RenderDiagnosticsView(cpuSetupMs: 0, sourceCopyMs: 0,
                         commandBufferMs: (ProcessInfo.processInfo.systemUptime - lutStarted) * 1000,
                         outputCopyMs: 0, passCount: 1, uploadBytes: 0)
                } else {
                    let exact = try await activeRenderer.render(renderInput, look: renderLook)
                    filmOutput = exact.0
                    d = exact.1
                }
                if Task.isCancelled { break }
                // Geometry is deliberately post-render and color-neutral. Crop/straighten/keystone
                // therefore never changes SpektraFilm's spectral processing and can be previewed
                // independently from expensive film renders.
                let output = try await Task.detached(priority: .userInitiated) {
                    let gpuCheckpoint = GPUProcessingFailure.checkpoint()
                    let localOutput = MaskedLocalGradeEngine.apply(filmOutput, grades: request.look.localGrades)
                    let lensOutput = LensCharacterEngine.apply(localOutput, settings: request.look.lensEffects)
                    let geometryOutput = GeometryEngine.transformed(lensOutput, settings: request.look.geometry)
                    let result = ExposureBoundaryEngine.apply(geometryOutput, look: request.look, preferences: request.preferences)
                    try GPUProcessingFailure.requireSuccess(after: gpuCheckpoint)
                    return result
                }.value
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

                let profile = StudioImportedLUT.isSelected ? CGColorSpace(name: CGColorSpace.sRGB)! : OutputColorProfile.forLook(request.look).cgColorSpace
                // The O(n) float-array -> Data copy is performed off the main actor. Keeping
                // this copy away from the event thread is critical for smooth pointer tracking.
                let renderedPayload = await Task.detached(priority: .userInitiated) {
                    output.makeFloatImagePayload()
                }.value
                if Task.isCancelled { break }
                guard request.generation == renderGeneration,
                      project.selectedImageID == request.imageID else { continue }
                guard let newRenderedPreview = renderedPayload?.makeCGImage(colorSpace: profile)
                        ?? output.makeCGImage8(colorSpace: profile) else {
                    throw RendererError.renderFailed("Could not create preview image")
                }
                renderedPreview = newRenderedPreview
                // An exact settled render must never be labeled as a live LUT frame.
                rendererPathStatus = "Native spectral Metal · settled exact"
                liveGPUFrame = nil
                if !request.interactive {
                    updateCloudPreview(photoID: request.imageID, image: newRenderedPreview)
                }
                latestSourceBuffer = input
                latestSourceRaw = request.look.raw
                maskOverlayRevision &+= 1  // Source coordinates are now authoritative.
                // A cached on-screen image can arrive before source pixels. Resume only
                // after the matching source frame is committed by the render loop.
                if semanticAnalysisDeferred && project.selectedImageID == request.imageID {
                    semanticAnalysisDeferred = false
                    refreshCanonicalSemanticMasks()
                }
                latestFilmRenderedBuffer = filmOutput
                latestRenderedBuffer = output
                latestRenderedLook = request.look
                if !useFull {
                    latestWorkingFilmRenderedBuffer = filmOutput
                    latestWorkingRenderedBuffer = output
                    latestWorkingRenderedLook = request.look
                    prepareInteractiveBaseline(from: output, look: request.look)
                }
                // Diagnostics update after the exact render settles. Transient pointer-rate
                // frames feed the throttled scope loop but never own clipping/skin measurements.
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
                if !request.interactive && !useFull {
                    scheduleLUTPrewarm(look: request.look, imageID: request.imageID)
                }
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
        lutPrewarmTask?.cancel()
        lutPrewarmTask = nil
        lutIsPreparing = false
        rendererPathStatus = "No active frame"
        lutPreparationStatus = ""
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
        // One image-specific semantic provider powers every skin-consuming tool.
        if (prefs.skinCheckEnabled || prefs.scopeMode == .skinVectorscope),
           semanticMasks == nil, semanticMaskTask == nil,
           (frameState.sourcePreview ?? frameState.renderedPreview) != nil {
            refreshCanonicalSemanticMasks()
        }

        guard prefs.clippingEnabled || prefs.skinCheckEnabled || prefs.scopeMode == .skinVectorscope || prefs.scopeMode == .histogram,
              let buffer = latestRenderedBuffer else {
            clearStudioAnalysis()
            return
        }

        isAnalyzing = true
        analysisTask = Task { [weak self] in
            guard let self else { return }
            do {
                let analysisLook = latestRenderedLook ?? selectedLook
                let sourceSkin = semanticMasks.flatMap { set in
                    set.alpha(.skin).map { CanonicalSkinMaskPayload(width: set.width, height: set.height, alpha: $0) }
                }
                let canonicalSkin = await Task.detached(priority: .userInitiated) {
                    sourceSkin?.transformed(settings: analysisLook.geometry)
                }.value
                guard !Task.isCancelled, generation == analysisGeneration else { return }
                let payload = try await analysisEngine.analyze(
                    output: buffer,
                    look: analysisLook,
                    preferences: prefs,
                    maxLongEdge: interactive ? 480 : 1200,
                    canonicalSkinMask: canonicalSkin
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
        scheduleCloudPublish()
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
        alert.messageText = "Recover unsaved SpektraFilm Studio work?"
        alert.informativeText = "A recovery snapshot from \(recovery.savedAt.formatted()) was found. Recover it or discard the snapshot."
        alert.addButton(withTitle: "Recover")
        alert.addButton(withTitle: "Discard")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            workspaceGeneration = UUID()
            projectOpenGeneration = UUID()
            disconnectCloudLibrary()
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
            page = .library
            if project.selectedImageID == nil { project.selectedImageID = project.images.first?.id }
            renderedPreview = nil
            sourcePreview = nil
            latestSourceBuffer = nil
            latestSourceRaw = nil
            latestRenderedBuffer = nil
            latestRenderedLook = nil
            latestWorkingRenderedBuffer = nil
            latestWorkingRenderedLook = nil
            latestInteractiveBaseBuffer = nil
            latestInteractiveBaseLook = nil
            editorWarmupTask?.cancel()
            clearStudioAnalysis()
            status = "Recovered unsaved work · select Edit when ready"
        } else {
            await recoveryStore.clear()
        }
    }

    func prepareForTermination(completion: @escaping (Bool) -> Void) {
        guard isProjectDirty else { completion(true); return }
        let alert = NSAlert()
        alert.messageText = "Save changes before quitting?"
        alert.informativeText = "Unsaved changes are still in this SpektraFilm Studio project."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveProject(completion: completion)
        case .alertSecondButtonReturn:
            completion(false)
        default:
            ProjectRecoveryStore.clearSynchronously()
            completion(true)
        }
    }

    private func confirmDestructiveTransitionIfNeeded(completion: @escaping (Bool) -> Void) {
        guard isProjectDirty else { completion(true); return }
        let alert = NSAlert()
        alert.messageText = "Save the current project first?"
        alert.informativeText = "Opening or creating another project will replace the current workspace."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: saveProject(completion: completion)
        case .alertSecondButtonReturn: completion(false)
        default:
            ProjectRecoveryStore.clearSynchronously()
            completion(true)
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
        if level != .normal {
            Task { [exactRenderer] in
                await exactRenderer?.releaseTransientResources()
            }
        }
        Task { [decoder, thumbnails] in
            await decoder.handleMemoryPressure(level)
            await thumbnails.handleMemoryPressure(level)
        }
    }

    func chooseCacheFolder() {
        SpektraFilePanel.chooseFolder(title: "Choose Cache Folder") { [weak self] parent in
            self?.setCacheFolder(parent)
        }
    }

    private func setCacheFolder(_ parent: URL) {
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
        SpektraFilePanel.chooseFolder(title: "Search for Missing Media") { [weak self] root in
            self?.relinkMissingMedia(in: root, missing: missing)
        }
    }

    private func relinkMissingMedia(in root: URL, missing: [ProjectImageRecord]) {
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

    // A cloud library replaces the complete photo document. An old preview/mask render
    // must never outlive that replacement or publish a frame for a no-longer-selected image.
    func prepareForCloudProjectReplacement() {
        invalidateRendering()
        autosaveTask?.cancel()
        editorWarmupTask?.cancel()
        selectionPresentationTask?.cancel()
        importHydrationTask?.cancel()
        renderedPreview = nil
        sourcePreview = nil
        latestSourceBuffer = nil
        latestSourceRaw = nil
        latestRenderedBuffer = nil
        latestRenderedLook = nil
        latestFilmRenderedBuffer = nil
        latestWorkingFilmRenderedBuffer = nil
        latestWorkingRenderedBuffer = nil
        latestWorkingRenderedLook = nil
        latestInteractiveBaseBuffer = nil
        latestInteractiveBaseLook = nil
        renderedFrameCache.removeAll()
        renderedFrameCacheOrder.removeAll()
        renderedFrameCacheBytes = 0
        clearStudioAnalysis()
    }

    func confirmCloudLibraryTransition(completion: @escaping (Bool) -> Void) {
        confirmDestructiveTransitionIfNeeded(completion: completion)
    }

    // MARK: - Project and presets

    func saveProject(asNew: Bool = false, completion: @escaping (Bool) -> Void = { _ in }) {
        if !asNew, let target = projectURL {
            completion(writeProject(to: target))
            return
        }
        SpektraFilePanel.saveFile(title: "Save Project", types: [.spektrafilmProject],
                                  filename: "\(project.name).\(UTTypeNames.projectExtension)") { [weak self] target in
            guard let self, let target else { completion(false); return }
            completion(self.writeProject(to: target))
        }
    }

    private func writeProject(to target: URL) -> Bool {
        do {
            suppressDirtyTracking = true
            project.migrateForV2()
            suppressDirtyTracking = false
            let data = try Self.encoder.encode(project)
            try data.write(to: target, options: .atomic)
            projectURL = target
            RecentSpektraProjects.record(target)
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

    // Loading old projects can decode thousands of images and RLE mask payloads.
    // Never parse/migrate them on the UI actor, and never replace the current
    // document unless the whole decode and validation succeeds.
    func openProject() {
        didStartProjectWorkflow = true
        SpektraFilePanel.chooseFiles(title: "Open SpektraFilm Project", types: [.spektrafilmProject]) { [weak self] urls in
            guard let self, let url = urls.first else { return }
            self.openProject(at: url)
        }
    }

    func openProject(at url: URL) {
        didStartProjectWorkflow = true
        guard url.isFileURL, url.pathExtension.lowercased() == UTTypeNames.projectExtension else {
            status = "Choose a .spektrafilm project file"
            return
        }
        confirmDestructiveTransitionIfNeeded { [weak self] allowed in
            if allowed { self?.loadProject(at: url) }
        }
    }

    private func loadProject(at url: URL) {
        let request = UUID()
        projectOpenGeneration = request
        let workspace = workspaceGeneration
        let previousProject = project
        status = "Opening \(url.lastPathComponent)…"
        Task { [weak self] in
            guard let self else { return }
            do {
                // A fresh decoder is confined to this worker; JSONDecoder is
                // not shared across concurrent project/open/autosave tasks.
                let opened = try await Task.detached(priority: .userInitiated) {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    try Task.checkCancellation()
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    var loaded = try decoder.decode(SpektraProjectDocument.self, from: data)
                    loaded.migrateForV2()
                    if loaded.selectedImageID == nil { loaded.selectedImageID = loaded.images.first?.id }
                    try Task.checkCancellation()
                    return loaded
                }.value
                guard projectOpenGeneration == request, workspaceGeneration == workspace else { return }
                guard project == previousProject else {
                    status = "Open cancelled because the current project changed. Retry when ready."
                    return
                }
                workspaceGeneration = UUID()
                // Do not detach the existing cloud session until the replacement project
                // has decoded successfully; a malformed file must leave the current session intact.
                disconnectCloudLibrary()
                // Cancel old rendering only after a fully successful decode.
                invalidateRendering()
                autosaveTask?.cancel()
                suppressDirtyTracking = true
                project = opened
                projectURL = url
                RecentSpektraProjects.record(url)
                isProjectDirty = false
                suppressDirtyTracking = false
                undoStack.removeAll()
                redoStack.removeAll()
                renderedFrameCache.removeAll()
                renderedFrameCacheOrder.removeAll()
                renderedFrameCacheBytes = 0
                Task { [recoveryStore] in await recoveryStore.clear() }
                configureCaches()

                // Opening a project replaces a large amount of observable state. Land in
                // Library first and keep the renderer asleep until Edit is explicitly entered.
                showProjectHome = false
                page = .library
                renderedPreview = nil
                sourcePreview = nil
                latestSourceBuffer = nil
                latestSourceRaw = nil
                latestRenderedBuffer = nil
                latestRenderedLook = nil
                latestWorkingRenderedBuffer = nil
                latestWorkingRenderedLook = nil
                latestInteractiveBaseBuffer = nil
                latestInteractiveBaseLook = nil
                editorWarmupTask?.cancel()
                clearStudioAnalysis()

                if let image = selectedImage,
                   !FileManager.default.fileExists(atPath: image.sourcePath) {
                    status = "Opened \(url.lastPathComponent) · selected media missing · Relink Missing Media…"
                } else {
                    status = "Opened \(url.lastPathComponent) · select Edit when ready"
                }
            } catch is CancellationError {
                guard projectOpenGeneration == request, workspaceGeneration == workspace else { return }
                status = "Project open cancelled"
            } catch {
                guard projectOpenGeneration == request, workspaceGeneration == workspace else { return }
                // The existing workspace remains untouched on a decoding error.
                status = "Open failed: \(error.localizedDescription)"
            }
        }
    }


    func presetThumbnail(
        _ preset: SpektraPreset,
        longEdge: Int = 360
    ) async -> CGImage? {
        guard let image = selectedImage,
              let activeRenderer = exactRenderer ?? renderer else {
            return nil
        }

        var look = preset.look
        look.normalizeForProOnly()

        let cacheKey =
            "\(image.id.uuidString)|\(preset.id.uuidString)|\(longEdge)|\(sourceFingerprint(for: image.url))"

        if let cached = presetThumbnailCache[cacheKey] {
            return cached
        }

        do {
            let input = try await decoder.decode(
                url: image.url,
                longEdge: max(160, min(720, longEdge)),
                raw: look.raw,
                bypassImportTransform: project.preferences.bypassImportTransform,
                cacheMode: cacheMemoryMode
            )

            let renderInput = try await Task.detached(priority: .utility) {
                let checkpoint = GPUProcessingFailure.checkpoint()
                let graded = input.applyingHostAndFilmGrade(
                    tone: look.tone,
                    density: look.colorDensity, film: look.filmTone)
                try GPUProcessingFailure.requireSuccess(after: checkpoint)
                return graded
            }.value

            let (filmOutput, _) = try await activeRenderer.render(
                renderInput,
                look: look
            )

            let exportPreviewPrefs = project.preferences
            let output = await Task.detached(priority: .utility) {
                ExposureBoundaryEngine.apply(GeometryEngine.transformed(
                    LensCharacterEngine.apply(
                        MaskedLocalGradeEngine.apply(filmOutput, grades: look.localGrades),
                        settings: look.lensEffects
                    ),
                    settings: look.geometry
                ), look: look, preferences: exportPreviewPrefs)
            }.value

            let payload = await Task.detached(priority: .utility) {
                output.makeFloatImagePayload()
            }.value

            guard project.selectedImageID == image.id else { return nil }

            let colorSpace = OutputColorProfile.forLook(look).cgColorSpace
            guard let cgImage =
                payload?.makeCGImage(colorSpace: colorSpace)
                ?? output.makeCGImage8(colorSpace: colorSpace)
            else {
                return nil
            }

            if presetThumbnailCache.count >= 96 {
                presetThumbnailCache.remove(at: presetThumbnailCache.startIndex)
            }
            presetThumbnailCache[cacheKey] = cgImage
            return cgImage
        } catch {
            return nil
        }
    }

    func previewPreset(_ preset: SpektraPreset) {
        var look = preset.look
        look.normalizeForProOnly()
        cancelIdleRefinement()
        scheduleRender(
            interactive: false,
            longEdgeOverride: project.preferences.previewLongEdge,
            fullResolutionRequest: false,
            cacheResult: false,
            reason: "preset preview",
            useInteractiveRenderPolicy: false,
            lookOverride: look
        )
    }

    func endPresetPreview() {
        cancelIdleRefinement()
        scheduleRender(
            interactive: false,
            longEdgeOverride: project.preferences.previewLongEdge,
            fullResolutionRequest: false,
            cacheResult: false,
            reason: "preset restore",
            useInteractiveRenderPolicy: false,
            lookOverride: selectedLook
        )
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
        SpektraFilePanel.saveFile(title: "Export Preset", types: [.spektrafilmPreset],
                                  filename: "\(preset.name).\(UTTypeNames.presetExtension)") { [weak self] url in
            guard let self, let url else { return }
            self.exportPreset(preset, to: url)
        }
    }

    private func exportPreset(_ preset: SpektraPreset, to url: URL) {
        do {
            var value = preset
            value.look.normalizeForProOnly()
            try Self.encoder.encode(value).write(to: url, options: .atomic)
            status = "Exported preset \(preset.name)"
        } catch { status = "Preset export failed: \(error.localizedDescription)" }
    }

    func importPreset() {
        SpektraFilePanel.chooseFiles(title: "Import Presets", types: [.spektrafilmPreset], multiple: true) { [weak self] urls in
            self?.importPresets(at: urls)
        }
    }

    private func importPresets(at urls: [URL]) {
        do {
            for url in urls {
                var preset = try Self.decoderJSON.decode(SpektraPreset.self, from: Data(contentsOf: url))
                preset.look.normalizeForProOnly()
                presets.append(preset)
            }
            persistPresetLibrary()
            status = "Imported \(urls.count) preset(s)"
        } catch { status = "Preset import failed: \(error.localizedDescription)" }
    }

    // MARK: - Export

    func chooseExportDestination() {
        SpektraFilePanel.chooseFolder(title: "Choose Export Folder") { [weak self] url in
            self?.project.exportSettings.destinationPath = url.path
        }
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

    func exportImage(_ id: UUID) {
        exportImage(id, settings: project.exportSettings)
    }

    func exportImage(_ id: UUID, settings: ExportSettings) {
        guard !isExporting, exactRenderer != nil,
              let image = project.images.first(where: { $0.id == id }) else { return }
        var effective = settings
        if effective.destinationPath.isEmpty {
            chooseExportDestination()
            effective.destinationPath = project.exportSettings.destinationPath
        }
        guard !effective.destinationPath.isEmpty else { return }

        do {
            let job = try ExportJobPlanner.makeJob(
                images: [image],
                settings: effective,
                bypassImportTransform: project.preferences.bypassImportTransform
            )
            project.exportSettings = effective
            activeExportJob = job
            status = "Exporting \(image.fileName)…"
            startExport(job)
        } catch {
            status = "Single-photo export setup failed · \(error.localizedDescription)"
        }
    }

    func focusPhoto(_ id: UUID, destination: WorkspacePage) {
        librarySelection = [id]
        librarySelectionAnchor = id
        selectImage(id, renderPreview: false)
        workspaceDidChange(destination)
    }

    func beginExportCrop(_ id: UUID) {
        focusPhoto(id, destination: .export)
        isCropToolActive = true
        selectImage(id, renderPreview: true)
    }

    func finishExportCrop() {
        isCropToolActive = false
        cancelIdleRefinement()
        status = "Export crop updated"
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

    var exportQueueSettingsDiffer: Bool {
        guard let job = activeExportJob else { return false }
        return job.settings != project.exportSettings
    }

    private func requireQueuedExportSettings() -> Bool {
        guard !exportQueueSettingsDiffer else {
            status = "Export settings changed · start a new export to use the current settings. The saved queue was kept."
            return false
        }
        return true
    }

    func resumeExport() {
        guard !isExporting, var job = activeExportJob, job.remainingCount > 0, requireQueuedExportSettings() else { return }
        for index in job.items.indices where job.items[index].state == .rendering || job.items[index].state == .writing {
            job.items[index].state = .pending
            job.items[index].errorMessage = nil
        }
        activeExportJob = job
        startExport(job)
    }

    func retryFailedExports() {
        guard !isExporting, var job = activeExportJob, requireQueuedExportSettings() else { return }
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

    @Published var exportPerformanceSummary = ""

    private func startExport(_ initialJob: ExportJob) {
        exportPerformanceSummary = ""
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
        var pendingPostprocess: [PendingExportPostprocess] = []

        defer {
            decodeAhead?.cancel()
            for pending in pendingPostprocess {
                pending.task.cancel()
            }
        }

        @MainActor
        func startDecode(index: Int) -> Task<ExportDecodedFrame, Error> {
            let item = job.items[index]
            let url = URL(fileURLWithPath: item.sourcePath)
            let raw = item.look.raw
            let bypass = job.bypassImportTransform
            let decoderActor = decoder
            let denoiseService = rawDenoiseService
            let cloudRelative = project.images.first(where: { $0.id == item.sourceImageID })?.cloudRelativePath
            let library = cloudLibrary
            let scratchPath = externalOriginalScratchParent

            return Task {
                let started = ProcessInfo.processInfo.systemUptime
                let original: URL
                if let cloudRelative {
                    guard let library, !scratchPath.isEmpty else {
                        throw ExternalOriginalScratch.ScratchError.notConfigured
                    }
                    let scratch = ExternalOriginalScratch.shared
                    await scratch.holdExport(item.sourceImageID)
                    do {
                        original = try await scratch.stage(
                            photoID: item.sourceImageID,
                            fileName: item.sourceFileName,
                            original: url,
                            relativePath: cloudRelative,
                            library: library,
                            parent: URL(fileURLWithPath: scratchPath, isDirectory: true)
                        )
                    } catch {
                        await scratch.releaseExport(item.sourceImageID)
                        throw error
                    }
                } else {
                    try await SpektraCloudLibrary.materializeIfNeeded(url)
                    original = url
                }
                let renderURL = try await denoiseService.prepare(source: original, raw: raw, iso: nil)
                let buffer = try await decoderActor.fullResolution(
                    url: renderURL,
                    raw: raw,
                    bypassImportTransform: bypass
                )
                return ExportDecodedFrame(
                    buffer: buffer,
                    decodeMs: Self.msSince(started),
                    originalForMetadata: original
                )
            }
        }

        @MainActor
        func settlePostprocess(at position: Int = 0) async throws {
            guard pendingPostprocess.indices.contains(position) else { return }
            let pending = pendingPostprocess.remove(at: position)

            do {
                let result = try await pending.task.value
                var timings = pending.timings
                timings.geometryResizeMs = result.geometryResizeMs
                timings.writeMs = result.writeMs
                timings.outputWidth = result.outputWidth
                timings.outputHeight = result.outputHeight
                timings.outputBytes = result.outputBytes
                timings.wallMs = max(
                    0,
                    (result.completedUptime - pending.itemStarted) * 1000.0
                )

                job.items[pending.index].outputBytes = result.outputBytes
                job.items[pending.index].timings = timings
                job.items[pending.index].state = .completed
                job.items[pending.index].errorMessage = nil
                await ExportTimingLog.shared.record(job.items[pending.index])
                exportPerformanceSummary = String(
                    format: "Decode %.1fs · Host %.1fs · Film %.1fs · Post %.1fs · JPEG/write %.1fs",
                    timings.decodeMs / 1000, timings.gradeMs / 1000,
                    timings.renderMs / 1000, timings.geometryResizeMs / 1000,
                    timings.writeMs / 1000
                )

            } catch is CancellationError {
                let destination = URL(
                    fileURLWithPath: job.items[pending.index].destinationPath
                )
                if let attrs = try? FileManager.default.attributesOfItem(
                    atPath: destination.path
                ),
                   let size = attrs[.size] as? NSNumber,
                   size.int64Value > 0 {
                    job.items[pending.index].state = .completed
                    job.items[pending.index].outputBytes = size.int64Value
                    job.items[pending.index].errorMessage = nil
                } else {
                    job.items[pending.index].state = .pending
                    job.items[pending.index].outputBytes = nil
                    job.items[pending.index].errorMessage = nil
                }

                job.updatedAt = Date()
                activeExportJob = job
                exportProgress = job.fractionComplete
                try? await ExportJobJournal.shared.save(job)
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

            if project.images.first(where: { $0.id == job.items[pending.index].sourceImageID })?.cloudRelativePath != nil {
                await ExternalOriginalScratch.shared.releaseExport(job.items[pending.index].sourceImageID)
            }
            job.updatedAt = Date()
            activeExportJob = job
            exportProgress = job.fractionComplete
            try? await ExportJobJournal.shared.save(job)
        }

        @MainActor
        func makePostprocessHeadroom(for estimatedBytes: UInt64) async throws {
            while !pendingPostprocess.isEmpty {
                let bytesInFlight = pendingPostprocess.reduce(UInt64(0)) {
                    $0 &+ $1.retainedBytes
                }
                let budget = Self.exportPostprocessBudgetBytes()
                let workerLimitReached =
                    pendingPostprocess.count >= Self.exportPostprocessWorkerLimit(
                        estimatedBytes: estimatedBytes
                    )
                let memoryLimitReached =
                    bytesInFlight > 0 &&
                    (
                        estimatedBytes > budget ||
                        bytesInFlight > budget - min(budget, estimatedBytes)
                    )

                guard workerLimitReached || memoryLimitReached else { break }
                try await settlePostprocess(at: 0)
            }
        }

        @MainActor
        func stopAndDrainPostprocess() async {
            for pending in pendingPostprocess {
                pending.task.cancel()
            }

            while !pendingPostprocess.isEmpty {
                do {
                    try await settlePostprocess(at: 0)
                } catch {
                    continue
                }
            }
        }

        for (position, index) in workIndices.enumerated() {
            do {
                try Task.checkCancellation()

                let item = job.items[index]
                let sourceURL = URL(fileURLWithPath: item.sourcePath)

                let cloudOriginal = project.images.first(where: { $0.id == item.sourceImageID })?.cloudRelativePath != nil
                try await makePostprocessHeadroom(
                    for: cloudOriginal ? UInt64(2 * 1024 * 1024 * 1024)
                        : Self.estimatedExportPostprocessBytes(sourceURL)
                )

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

                status = "Decoding original · \(item.sourceFileName)"
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

                if position + 1 < workIndices.count {
                    let nextIndex = workIndices[position + 1]
                    let nextURL = URL(
                        fileURLWithPath: job.items[nextIndex].sourcePath
                    )
                    // Cloud originals are never decoded in anticipation of a neighboring export.
                    let nextIsCloud = project.images.first(where: {
                        $0.id == job.items[nextIndex].sourceImageID
                    })?.cloudRelativePath != nil
                    // A 45+ MP RAW can retain several GB across the renderer and
                    // post-processing. Prefetch is disabled until GPU-resident handoff
                    // and measured byte-based admission are implemented.
                    _ = nextIsCloud
                    _ = nextURL
                }

                status = "Preparing host grade · \(item.sourceFileName)"
                let gradeStarted = ProcessInfo.processInfo.systemUptime
                let renderInput = try await Task.detached(priority: .userInitiated) {
                    let checkpoint = GPUProcessingFailure.checkpoint()
                    let graded = decoded.buffer.applyingHostAndFilmGrade(
                        tone: item.look.tone,
                        density: item.look.colorDensity, film: item.look.filmTone)
                    try GPUProcessingFailure.requireSuccess(after: checkpoint)
                    return graded
                }.value
                timings.gradeMs = Self.msSince(gradeStarted)
                try Task.checkCancellation()

                var exportLook = item.look
                if job.settings.colorMode == .sRGB || StudioImportedLUT.isSelected {
                    exportLook.values["outputColorSpace"] = .int(17)
                    exportLook.values["outputRole"] = .int(0)
                }

                status = "SpektraFilm simulation (full resolution) · \(item.sourceFileName)"
                let renderStarted = ProcessInfo.processInfo.systemUptime
                let filmOutput: PixelBufferF32
                let renderDiagnostics: RenderDiagnosticsView
                if StudioImportedLUT.isSelected {
                    guard let file = StudioImportedLUT.selectedURL() else {
                        throw StudioImportedLUT.Failure.invalid("Selected export LUT is missing.")
                    }
                    let lutStarted = ProcessInfo.processInfo.systemUptime
                    filmOutput = try await StudioImportedLUTOffline.shared.render(renderInput, file: file)
                    renderDiagnostics = RenderDiagnosticsView(cpuSetupMs: 0, sourceCopyMs: 0,
                        commandBufferMs: (ProcessInfo.processInfo.systemUptime - lutStarted) * 1000,
                        outputCopyMs: 0, passCount: 1, uploadBytes: 0)
                } else {
                    let exact = try await exactRenderer.render(renderInput,
                        look: exportLook, useDensityLuts: false, useStageCache: false)
                    filmOutput = exact.0
                    renderDiagnostics = exact.1
                }
                timings.renderMs = Self.msSince(renderStarted)
                timings.renderGpuMs = renderDiagnostics.commandBufferMs
                timings.renderPassCount = renderDiagnostics.passCount
                try Task.checkCancellation()

                // Stage 1 boundary: the serialized render lane ENDS here.
                let geometrySettings = item.look.geometry
                let lensSettings = item.look.lensEffects
                let localGrades = item.look.localGrades
                let clipPreferences = project.preferences
                let exportSettings = job.settings
                let destination = URL(fileURLWithPath: item.destinationPath)
                let writer = exportEngine
                let sourceForWriter = decoded.originalForMetadata
                let lookForWriter = exportLook
                let retainedBytes =
                    Self.actualExportPostprocessBytes(filmOutput)

                job.items[index].state = .writing
                job.updatedAt = Date()
                activeExportJob = job
                exportProgress = job.fractionComplete
                try await ExportJobJournal.shared.save(job)

                // A foreground user export must not compete at background utility QoS.
                let postTask = Task.detached(priority: .userInitiated) {
                    let gpuCheckpoint = GPUProcessingFailure.checkpoint()
                    try Task.checkCancellation()

                    let geometryStarted =
                        ProcessInfo.processInfo.systemUptime
                    var working = MaskedLocalGradeEngine.apply(
                        filmOutput,
                        grades: localGrades
                    )
                    try Task.checkCancellation()
                    working = LensCharacterEngine.apply(working, settings: lensSettings)
                    try Task.checkCancellation()
                    working = GeometryEngine.transformed(working, settings: geometrySettings)
                    try Task.checkCancellation()
                    working = ExposureBoundaryEngine.apply(
                        working,
                        look: lookForWriter,
                        preferences: clipPreferences
                    )
                    try Task.checkCancellation()
                    let output = try working.resizedForExport(settings: exportSettings)
                    let geometryResizeMs =
                        (ProcessInfo.processInfo.systemUptime -
                         geometryStarted) * 1000.0

                    try Task.checkCancellation()

                    try GPUProcessingFailure.requireSuccess(after: gpuCheckpoint)
                    let writeStarted =
                        ProcessInfo.processInfo.systemUptime
                    try await writer.write(
                        output: output,
                        look: lookForWriter,
                        sourceURL: sourceForWriter,
                        destination: destination,
                        settings: exportSettings
                    )
                    let writeMs =
                        (ProcessInfo.processInfo.systemUptime -
                         writeStarted) * 1000.0

                    let attrs =
                        try FileManager.default.attributesOfItem(
                            atPath: destination.path
                        )
                    let bytes =
                        (attrs[.size] as? NSNumber)?.int64Value ?? 0

                    return ExportPostprocessResult(
                        geometryResizeMs: geometryResizeMs,
                        writeMs: writeMs,
                        outputWidth: output.width,
                        outputHeight: output.height,
                        outputBytes: bytes,
                        completedUptime:
                            ProcessInfo.processInfo.systemUptime
                    )
                }

                pendingPostprocess.append(
                    PendingExportPostprocess(
                        index: index,
                        retainedBytes: retainedBytes,
                        itemStarted: itemStarted,
                        timings: timings,
                        task: postTask
                    )
                )
                // Complete and release this full frame before decoding the next.
                // This is deliberate back-pressure for crash containment, not a
                // claim that the complete spectral/RAW pipeline is GPU-resident.
                try await settlePostprocess(at: 0)

            } catch is CancellationError {
                if !pendingPostprocess.contains(where: { $0.index == index }),
                   project.images.first(where: { $0.id == job.items[index].sourceImageID })?.cloudRelativePath != nil {
                    await ExternalOriginalScratch.shared.releaseExport(job.items[index].sourceImageID)
                }
                decodeAhead?.cancel()
                decodeAhead = nil
                decodeAheadIndex = nil

                await stopAndDrainPostprocess()

                for i in job.items.indices
                where job.items[i].state == .rendering {
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
                if project.images.first(where: { $0.id == job.items[index].sourceImageID })?.cloudRelativePath != nil {
                    await ExternalOriginalScratch.shared.releaseExport(job.items[index].sourceImageID)
                }
                job.items[index].state = .failed
                job.items[index].errorMessage =
                    error.localizedDescription
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

        while !pendingPostprocess.isEmpty {
            status =
                "Finishing \(pendingPostprocess.count) export\(pendingPostprocess.count == 1 ? "" : "s")…"
            do {
                try await settlePostprocess(at: 0)
            } catch is CancellationError {
                await stopAndDrainPostprocess()
                job.state = .stopped
                job.updatedAt = Date()
                activeExportJob = job
                exportProgress = job.fractionComplete
                try? await ExportJobJournal.shared.save(job)
                status =
                    "Export stopped · \(job.remainingCount) remaining"
                return
            } catch {
                continue
            }
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

    private static func estimatedExportPostprocessBytes(
        _ url: URL
    ) -> UInt64 {
        let pixels = approximatePixelCount(url)
        guard pixels > 0 else { return 0 }
        return UInt64(pixels) * 48
    }

    private static func actualExportPostprocessBytes(
        _ buffer: PixelBufferF32
    ) -> UInt64 {
        let pixels = UInt64(max(1, buffer.width * buffer.height))
        return pixels * 48
    }

    private static func exportPostprocessWorkerLimit(estimatedBytes: UInt64) -> Int {
        let mib = UInt64(1024 * 1024)
        let gib = UInt64(1024 * 1024 * 1024)
        if estimatedBytes >= 640 * mib { return 1 }

        let available = availableMemoryBytes()
        if available == 0 || available < 4 * gib { return 1 }
        return min(2, ExportJob.postProcessWorkerCount)
    }

    private static func exportPostprocessBudgetBytes() -> UInt64 {
        let available = availableMemoryBytes()
        let mib = UInt64(1024 * 1024)
        let gib = UInt64(1024 * 1024 * 1024)

        guard available > 0 else {
            return 768 * mib
        }

        let reserve = max(768 * mib, available / 3)
        guard available > reserve else {
            return 256 * mib
        }

        let usable = (available - reserve) * 2 / 3
        return min(3 * gib, max(512 * mib, usable))
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
        guard pixels > 0, pixels <= 12_000_000 else { return false }

        let estimate = UInt64(pixels) * 80
        let available = availableMemoryBytes()
        guard available > 0 else { return false }
        let reserve = max(UInt64(1024 * 1024 * 1024), available / 2)
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
        return safe.isEmpty ? "SpektraFilmStudio_\(sequenceText)" : safe
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
