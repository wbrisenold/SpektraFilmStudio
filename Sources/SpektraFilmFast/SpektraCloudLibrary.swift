import Foundation

enum CloudLibraryOperationKind: String, Codable, Sendable {
    case photoUpsert
    case photoDelete
    case lookUpdate
    case photoStateUpdate
    case projectMetadataUpdate
}

struct CloudPhotoState: Codable, Equatable, Sendable {
    var rating: Int
    var flag: ProjectFlag
    var selectedForExport: Bool
    var colorLabel: PhotoColorLabel?
    var clientPicked: Bool
    var cullAnalysis: CullAnalysisRecord?
    var keywords: [String]?
    var note: String?

    init(_ image: ProjectImageRecord) {
        rating = image.rating
        flag = image.flag
        selectedForExport = image.selectedForExport
        colorLabel = image.colorLabel
        clientPicked = image.clientPicked
        cullAnalysis = image.cullAnalysis
        keywords = image.keywords
        note = image.note
    }

    func apply(to image: inout ProjectImageRecord) {
        image.rating = rating
        image.flag = flag
        image.selectedForExport = selectedForExport
        image.colorLabel = colorLabel
        image.clientPicked = clientPicked
        image.cullAnalysis = cullAnalysis
        image.keywords = keywords
        image.note = note
    }
}

struct CloudProjectMetadata: Codable, Equatable, Sendable {
    var formatVersion: Int
    var name: String
    var workspaceMode: WorkspaceMode
    var sortMode: ProjectSortMode
    var filterRating: Int
    var filterFlag: ProjectFlag?
    var albums: [PhotoAlbum]
    var peopleGroups: [PersonGroup]
    var smartCollections: [SmartCollection]
    var exportSettings: ExportSettings
    var preferences: AppPreferences

    init(_ project: SpektraProjectDocument) {
        formatVersion = project.formatVersion
        name = project.name
        workspaceMode = project.workspaceMode
        sortMode = project.sortMode
        filterRating = project.filterRating
        filterFlag = project.filterFlag
        albums = project.albums
        peopleGroups = project.peopleGroups
        smartCollections = project.smartCollections
        exportSettings = project.exportSettings
        // Destination paths are device-local. Sync format/quality/resize/naming settings,
        // but never overwrite another Mac's chosen export folder.
        exportSettings.destinationPath = ""
        preferences = project.preferences
    }

    func apply(to project: inout SpektraProjectDocument) {
        project.formatVersion = max(project.formatVersion, formatVersion)
        project.name = name
        project.workspaceMode = workspaceMode
        project.sortMode = sortMode
        project.filterRating = filterRating
        project.filterFlag = filterFlag
        project.albums = albums
        project.peopleGroups = peopleGroups
        project.smartCollections = smartCollections
        let localDestination = project.exportSettings.destinationPath
        project.exportSettings = exportSettings
        project.exportSettings.destinationPath = localDestination
        project.preferences = preferences
    }
}

struct CloudLibraryOperation: Codable, Sendable {
    var id: UUID
    var deviceID: String
    var counter: UInt64
    var createdAt: Date
    var kind: CloudLibraryOperationKind
    var photoID: UUID?
    var photo: ProjectImageRecord?
    var look: RenderLook?
    var photoState: CloudPhotoState?
    var metadata: CloudProjectMetadata?
}

struct CloudLibraryManifest: Codable, Sendable {
    static let schemaVersion = 1
    var schemaVersion: Int
    var libraryID: UUID
    var createdAt: Date
    var createdByDevice: String
    var name: String
}

struct CloudLibrarySnapshot: Codable, Sendable {
    var schemaVersion: Int
    var libraryID: UUID
    var createdAt: Date
    var heads: [String: UInt64]
    var project: SpektraProjectDocument
}

struct CloudLibrarySyncResult: Sendable {
    var project: SpektraProjectDocument
    var pushedOperations: Int
    var pulledOperations: Int
    var didChangeProject: Bool
}

struct LightroomCloudMigrationReport: Codable, Sendable {
    var importedPhotos: Int
    var virtualCopies: Int
    var copiedOriginals: Int
    var reusedOriginals: Int
    var missingOriginals: [String]
    var copiedSidecars: Int
    var mappedDevelopPhotos: Int
    var preservedDevelopPayloads: Int
    var collections: Int
    var warnings: [String]
    var importedAt: Date
}

/// File-based iCloud library.
///
/// The user selects a folder in iCloud Drive. SpektraFilm stores immutable originals,
/// immutable operation journal entries, and periodic immutable project snapshots there.
/// It deliberately does not put a live SQLite database in iCloud.
actor SpektraCloudLibrary {
    enum CloudError: LocalizedError {
        case invalidLibrary
        case unsupportedSchema(Int)
        case missingManifest
        case createFailed(String)
        case sourceMissing(String)
        case streamOpenFailed(String)
        case readFailed(String)
        case writeFailed(String)
        case downloadTimedOut(String)

        var errorDescription: String? {
            switch self {
            case .invalidLibrary: return "This folder is not a SpektraFilm Cloud Library."
            case .unsupportedSchema(let version): return "This cloud library uses unsupported schema \(version)."
            case .missingManifest: return "Cloud library manifest is missing."
            case .createFailed(let message): return "Could not create cloud library: \(message)"
            case .sourceMissing(let path): return "Source file is missing: \(path)"
            case .streamOpenFailed(let path): return "Could not open cloud transfer stream: \(path)"
            case .readFailed(let path): return "Cloud read failed: \(path)"
            case .writeFailed(let path): return "Cloud write failed: \(path)"
            case .downloadTimedOut(let path): return "Timed out waiting for iCloud to download: \(path)"
            }
        }
    }

    let rootURL: URL
    let deviceID: String
    private(set) var manifest: CloudLibraryManifest
    private var lastPublishedProject: SpektraProjectDocument?
    private var seenHeads: [String: UInt64] = [:]
    private var localCounter: UInt64 = 0
    private var opsSinceSnapshot = 0

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func defaultICloudDriveURL() -> URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func looksLikeICloudDrive(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if path.contains("/Mobile Documents/com~apple~CloudDocs") { return true }
        if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true { return true }
        return false
    }

    static func create(
        at rootURL: URL,
        name: String,
        deviceID: String,
        project: SpektraProjectDocument,
        progress: (@Sendable (_ completed: Int, _ total: Int, _ fileName: String) -> Void)? = nil
    ) async throws -> SpektraCloudLibrary {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try createStructure(rootURL)
        } catch {
            throw CloudError.createFailed(error.localizedDescription)
        }

        let manifest = CloudLibraryManifest(
            schemaVersion: CloudLibraryManifest.schemaVersion,
            libraryID: UUID(),
            createdAt: Date(),
            createdByDevice: deviceID,
            name: name
        )
        try coordinatedWrite(Self.encoder.encode(manifest), to: rootURL.appendingPathComponent("manifest.json"))
        let library = SpektraCloudLibrary(rootURL: rootURL, deviceID: deviceID, manifest: manifest)
        var cloudProject = project
        cloudProject.name = name
        cloudProject = try await library.adoptOriginals(in: cloudProject, progress: progress)
        try await library.bootstrap(project: cloudProject)
        return library
    }

    static func open(at rootURL: URL, deviceID: String) async throws -> SpektraCloudLibrary {
        let manifestURL = rootURL.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { throw CloudError.missingManifest }
        let manifest = try Self.decoder.decode(
            CloudLibraryManifest.self,
            from: coordinatedRead(manifestURL)
        )
        guard manifest.schemaVersion == CloudLibraryManifest.schemaVersion else {
            throw CloudError.unsupportedSchema(manifest.schemaVersion)
        }
        try createStructure(rootURL)
        let library = SpektraCloudLibrary(rootURL: rootURL, deviceID: deviceID, manifest: manifest)
        try await library.finishOpening()
        return library
    }

    private init(rootURL: URL, deviceID: String, manifest: CloudLibraryManifest) {
        self.rootURL = rootURL
        self.deviceID = deviceID
        self.manifest = manifest
    }

    var displayName: String { manifest.name }

    private func bootstrap(project: SpektraProjectDocument) async throws {
        lastPublishedProject = project
        seenHeads = [:]
        try await writeSnapshot(project: project)
    }

    private func finishOpening() async throws {
        let loaded = try await loadMergedProject()
        lastPublishedProject = loaded.project
        seenHeads = loaded.heads
        localCounter = max(
            loaded.heads[deviceID, default: 0],
            try readDeviceHead(deviceID)
        )
    }

    // open(at:) already loaded and merged this snapshot in finishOpening().
    // Reading every cloud snapshot and operation again doubles peak work at launch.
    func initialProject() async throws -> SpektraProjectDocument {
        if let lastPublishedProject { return lastPublishedProject }
        return try await currentProject()
    }

    func currentProject() async throws -> SpektraProjectDocument {
        let loaded = try await loadMergedProject()
        lastPublishedProject = loaded.project
        seenHeads = loaded.heads
        return loaded.project
    }

    func synchronize(project localProject: SpektraProjectDocument) async throws -> CloudLibrarySyncResult {
        // Any photos added after the library was created are adopted into iCloud before their
        // catalog operation is published. Existing cloud-backed photos are a cheap no-op here.
        let cloudReadyProject = try await adoptOriginals(in: localProject, progress: nil)
        let pushed = try await publish(project: cloudReadyProject)
        let beforePull = lastPublishedProject ?? cloudReadyProject
        let loaded = try await mergeRemote(into: beforePull)
        lastPublishedProject = loaded.project
        seenHeads = loaded.heads

        if opsSinceSnapshot >= 250 {
            try await writeSnapshot(project: loaded.project)
            opsSinceSnapshot = 0
        }

        return CloudLibrarySyncResult(
            project: loaded.project,
            pushedOperations: pushed,
            pulledOperations: loaded.applied,
            didChangeProject: loaded.project != localProject
        )
    }

    func adoptOriginals(
        in project: SpektraProjectDocument,
        progress: (@Sendable (_ completed: Int, _ total: Int, _ fileName: String) -> Void)?
    ) async throws -> SpektraProjectDocument {
        var result = project
        var copiedBySource: [String: String] = [:]
        let total = result.images.count

        for index in result.images.indices {
            try Task.checkCancellation()
            var image = result.images[index]
            if image.logicalFolderPath == nil {
                image.logicalFolderPath = image.url.deletingLastPathComponent().path
            }
            if let relative = image.cloudRelativePath {
                let resolved = rootURL.appendingPathComponent(relative)
                image.sourcePath = resolved.path
                result.images[index] = image
                progress?(index + 1, total, image.fileName)
                continue
            }

            let source = image.url.standardizedFileURL
            if let existingOriginal = copiedBySource[source.path] {
                let previewRelative = previewRelativePath(photoID: image.id)
                let previewDestination = rootURL.appendingPathComponent(previewRelative)
                let generatedPreview: String?
                do {
                    try CloudPreviewGenerator.writeJPEG(source: source, destination: previewDestination)
                    generatedPreview = previewRelative
                } catch {
                    generatedPreview = nil
                }
                image.cloudRelativePath = existingOriginal
                image.cloudPreviewRelativePath = generatedPreview
                image.sourcePath = rootURL.appendingPathComponent(existingOriginal).path
                result.images[index] = image
                progress?(index + 1, total, image.fileName)
                continue
            }

            guard FileManager.default.fileExists(atPath: source.path) else {
                progress?(index + 1, total, image.fileName)
                continue
            }
            try await Self.materializeIfNeeded(source)

            let relative = originalRelativePath(photoID: image.id, fileName: image.fileName)
            let destination = rootURL.appendingPathComponent(relative)
            try Self.streamCopy(from: source, to: destination)

            let previewRelative = previewRelativePath(photoID: image.id)
            let previewDestination = rootURL.appendingPathComponent(previewRelative)
            let generatedPreview: String?
            do {
                try CloudPreviewGenerator.writeJPEG(source: source, destination: previewDestination)
                generatedPreview = previewRelative
            } catch {
                generatedPreview = nil
            }
            copiedBySource[source.path] = relative

            // Preserve a Lightroom/XMP sidecar when one exists beside the original.
            let sidecar = source.deletingPathExtension().appendingPathExtension("xmp")
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try? Self.streamCopy(
                    from: sidecar,
                    to: destination.deletingPathExtension().appendingPathExtension("xmp")
                )
            }

            image.cloudRelativePath = relative
            image.cloudPreviewRelativePath = generatedPreview
            image.sourcePath = destination.path
            result.images[index] = image
            progress?(index + 1, total, image.fileName)
        }
        return result
    }

    func importLightroomClassic(
        catalogURL: URL,
        snapshot: LightroomCatalogImport.Snapshot,
        projectName: String,
        progress: (@Sendable (_ completed: Int, _ total: Int, _ fileName: String) -> Void)?
    ) async throws -> (SpektraProjectDocument, LightroomCloudMigrationReport) {
        let fm = FileManager.default
        let migrationRoot = rootURL
            .appendingPathComponent("Migration/Lightroom", isDirectory: true)
            .appendingPathComponent(Self.timestampString(Date()), isDirectory: true)
        try fm.createDirectory(at: migrationRoot, withIntermediateDirectories: true)

        // Archive the original catalog read-only for rollback/audit. SpektraFilm never writes to it.
        try Self.streamCopy(from: catalogURL, to: migrationRoot.appendingPathComponent(catalogURL.lastPathComponent))

        // Modern Lightroom versions may keep mask/AI payloads beside the catalog in .lrcat-data.
        // Preserve that companion even though SpektraFilm does not claim to translate all of it yet.
        let catalogData = catalogURL.deletingPathExtension().appendingPathExtension("lrcat-data")
        if fm.fileExists(atPath: catalogData.path) {
            try await Self.materializeIfNeeded(catalogData)
            try? Self.streamCopy(
                from: catalogData,
                to: migrationRoot.appendingPathComponent(catalogData.lastPathComponent)
            )
        }

        // If Lightroom is open or recently closed in WAL mode, archive the SQLite companions too.
        for suffix in ["-wal", "-shm"] {
            let companion = URL(fileURLWithPath: catalogURL.path + suffix)
            if fm.fileExists(atPath: companion.path) {
                try? Self.streamCopy(
                    from: companion,
                    to: migrationRoot.appendingPathComponent(companion.lastPathComponent)
                )
            }
        }

        var project = SpektraProjectDocument()
        project.name = projectName
        project.workspaceMode = .project
        project.images = []
        project.albums = []

        var report = LightroomCloudMigrationReport(
            importedPhotos: 0,
            virtualCopies: 0,
            copiedOriginals: 0,
            reusedOriginals: 0,
            missingOriginals: [],
            copiedSidecars: 0,
            mappedDevelopPhotos: 0,
            preservedDevelopPayloads: 0,
            collections: 0,
            warnings: snapshot.warnings,
            importedAt: Date()
        )

        var originalByPath: [String: String] = [:]
        var collectionMembers: [Int64: Set<UUID>] = [:]
        var records: [ProjectImageRecord] = []
        records.reserveCapacity(snapshot.photos.count)

        let developRoot = migrationRoot.appendingPathComponent("DevelopPayloads", isDirectory: true)
        try fm.createDirectory(at: developRoot, withIntermediateDirectories: true)

        for (offset, lrPhoto) in snapshot.photos.enumerated() {
            try Task.checkCancellation()
            let source = URL(fileURLWithPath: lrPhoto.absolutePath).standardizedFileURL
            let recordID = UUID()
            for collectionID in lrPhoto.collectionIDs {
                collectionMembers[collectionID, default: []].insert(recordID)
            }

            let relative: String?
            if let existingOriginal = originalByPath[source.path] {
                relative = existingOriginal
                report.reusedOriginals += 1
            } else if fm.fileExists(atPath: source.path) {
                try await Self.materializeIfNeeded(source)
                let path = originalRelativePath(photoID: recordID, fileName: lrPhoto.fileName)
                let destination = rootURL.appendingPathComponent(path)
                try Self.streamCopy(from: source, to: destination)
                originalByPath[source.path] = path
                relative = path
                report.copiedOriginals += 1

                let xmp = source.deletingPathExtension().appendingPathExtension("xmp")
                if fm.fileExists(atPath: xmp.path) {
                    try? Self.streamCopy(from: xmp, to: destination.deletingPathExtension().appendingPathExtension("xmp"))
                    report.copiedSidecars += 1
                }
            } else {
                relative = nil
                report.missingOriginals.append(source.path)
            }

            var previewRelative: String?
            if fm.fileExists(atPath: source.path) {
                let generatedPreviewRelative = previewRelativePath(photoID: recordID)
                let previewDestination = rootURL.appendingPathComponent(generatedPreviewRelative)
                do {
                    try CloudPreviewGenerator.writeJPEG(source: source, destination: previewDestination)
                    previewRelative = generatedPreviewRelative
                } catch {
                    previewRelative = nil
                    report.warnings.append("Preview could not be generated for \(lrPhoto.fileName): \(error.localizedDescription)")
                }
            }

            var look = RenderLook.defaults()
            let sidecarURL = fm.fileExists(
                atPath: source.deletingPathExtension().appendingPathExtension("xmp").path
            ) ? source.deletingPathExtension().appendingPathExtension("xmp") : nil

            let mapping = LightroomDevelopMapper.map(
                catalogText: lrPhoto.latestDevelopText,
                sidecarURL: sidecarURL,
                base: look
            )
            look = mapping.look
            if mapping.mappedKeys > 0 { report.mappedDevelopPhotos += 1 }

            if let text = lrPhoto.latestDevelopText, !text.isEmpty {
                let payloadURL = developRoot.appendingPathComponent("\(lrPhoto.imageID).txt")
                try? text.data(using: .utf8)?.write(to: payloadURL, options: .atomic)
                report.preservedDevelopPayloads += 1
            }

            let flag: ProjectFlag = lrPhoto.pick > 0 ? .picked : (lrPhoto.pick < 0 ? .rejected : .unflagged)
            let label = Self.mapColorLabel(lrPhoto.colorLabel)
            let resolvedPath = relative.map { rootURL.appendingPathComponent($0).path } ?? source.path

            var noteParts: [String] = []
            if let copy = lrPhoto.copyName, !copy.isEmpty {
                noteParts.append("Lightroom virtual copy: \(copy)")
                report.virtualCopies += 1
            }
            if !mapping.unmappedKeys.isEmpty {
                noteParts.append("Lightroom fields preserved but not mapped: \(mapping.unmappedKeys.sorted().joined(separator: ", "))")
            }

            let record = ProjectImageRecord(
                id: recordID,
                sourcePath: resolvedPath,
                sourceFileSize: Self.fileSize(source),
                sourceModificationTime: Self.modificationTime(source),
                importedAt: Date(),
                captureDate: Self.parseLightroomDate(lrPhoto.captureTime),
                metadata: nil,
                rating: min(5, max(0, lrPhoto.rating)),
                flag: flag,
                selectedForExport: false,
                colorLabel: label,
                clientPicked: false,
                cullAnalysis: nil,
                keywords: lrPhoto.keywords.isEmpty ? nil : lrPhoto.keywords,
                note: noteParts.isEmpty ? nil : noteParts.joined(separator: " · "),
                look: look,
                cloudRelativePath: relative,
                cloudPreviewRelativePath: previewRelative,
                logicalFolderPath: source.deletingLastPathComponent().path
            )
            records.append(record)
            progress?(offset + 1, snapshot.photos.count, lrPhoto.fileName)
        }

        project.images = records
        project.selectedImageID = records.first?.id

        var albums: [PhotoAlbum] = []
        albums.reserveCapacity(snapshot.collections.count)
        for collection in snapshot.collections {
            let members = collectionMembers[collection.id, default: []]
            guard !members.isEmpty else { continue }
            albums.append(PhotoAlbum(
                id: UUID(),
                name: collection.name,
                imageIDs: members,
                createdAt: Date()
            ))
        }
        project.albums = albums
        report.collections = albums.count
        report.importedPhotos = records.count

        let reportData = try Self.encoder.encode(report)
        try Self.coordinatedWrite(reportData, to: migrationRoot.appendingPathComponent("migration-report.json"))

        lastPublishedProject = project
        seenHeads = [:]
        try await writeSnapshot(project: project)
        return (project, report)
    }

    func requestDownload(relativePath: String) async throws {
        let url = rootURL.appendingPathComponent(relativePath)
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard values?.isUbiquitousItem == true else { return }
        if values?.ubiquitousItemDownloadingStatus == .current ||
            values?.ubiquitousItemDownloadingStatus == .downloaded { return }

        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            try Task.checkCancellation()
            let current = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if current?.ubiquitousItemDownloadingStatus == .current ||
                current?.ubiquitousItemDownloadingStatus == .downloaded { return }
            try await Task.sleep(for: .milliseconds(180))
        }
        throw CloudError.downloadTimedOut(url.path)
    }

    func isDownloaded(relativePath: String) -> Bool {
        let url = rootURL.appendingPathComponent(relativePath)
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]) else {
            return FileManager.default.fileExists(atPath: url.path)
        }
        guard values.isUbiquitousItem == true else { return FileManager.default.fileExists(atPath: url.path) }
        return values.ubiquitousItemDownloadingStatus == .current ||
               values.ubiquitousItemDownloadingStatus == .downloaded
    }

    func evict(relativePath: String) throws {
        let url = rootURL.appendingPathComponent(relativePath)
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey])
        guard values?.isUbiquitousItem == true else { return }
        try FileManager.default.evictUbiquitousItem(at: url)
    }

    private func publish(project: SpektraProjectDocument) async throws -> Int {
        guard let previous = lastPublishedProject else {
            lastPublishedProject = project
            try await writeSnapshot(project: project)
            return 0
        }

        var operations: [CloudLibraryOperation] = []
        let oldByID = Dictionary(uniqueKeysWithValues: previous.images.map { ($0.id, $0) })
        let newByID = Dictionary(uniqueKeysWithValues: project.images.map { ($0.id, $0) })

        for image in project.images {
            guard let old = oldByID[image.id] else {
                operations.append(makeOperation(kind: .photoUpsert, photoID: image.id, photo: image))
                continue
            }

            if sourceIdentity(old) != sourceIdentity(image) {
                operations.append(makeOperation(kind: .photoUpsert, photoID: image.id, photo: image))
                continue
            }
            if old.look != image.look {
                operations.append(makeOperation(kind: .lookUpdate, photoID: image.id, look: image.look))
            }
            if CloudPhotoState(old) != CloudPhotoState(image) {
                operations.append(makeOperation(kind: .photoStateUpdate, photoID: image.id, photoState: CloudPhotoState(image)))
            }
        }

        for old in previous.images where newByID[old.id] == nil {
            operations.append(makeOperation(kind: .photoDelete, photoID: old.id))
        }

        if CloudProjectMetadata(previous) != CloudProjectMetadata(project) {
            operations.append(makeOperation(kind: .projectMetadataUpdate, metadata: CloudProjectMetadata(project)))
        }

        for operation in operations {
            try writeOperation(operation)
            seenHeads[deviceID] = operation.counter
            opsSinceSnapshot += 1
        }

        lastPublishedProject = project
        return operations.count
    }

    private func mergeRemote(
        into project: SpektraProjectDocument
    ) async throws -> (project: SpektraProjectDocument, heads: [String: UInt64], applied: Int) {
        var merged = project
        var heads = seenHeads
        var operations = try unreadOperations(after: heads)
        operations.sort {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            if $0.deviceID != $1.deviceID { return $0.deviceID < $1.deviceID }
            if $0.counter != $1.counter { return $0.counter < $1.counter }
            return $0.id.uuidString < $1.id.uuidString
        }

        for operation in operations {
            apply(operation, to: &merged)
            heads[operation.deviceID] = max(heads[operation.deviceID, default: 0], operation.counter)
        }
        resolveCloudPaths(in: &merged)
        return (merged, heads, operations.count)
    }

    private func loadMergedProject() async throws -> (project: SpektraProjectDocument, heads: [String: UInt64]) {
        guard let snapshotURL = try bestSnapshotURL() else { throw CloudError.invalidLibrary }
        let snapshot = try Self.decoder.decode(CloudLibrarySnapshot.self, from: Self.coordinatedRead(snapshotURL))
        guard snapshot.libraryID == manifest.libraryID else { throw CloudError.invalidLibrary }

        let merged = try await mergeStarting(
            project: snapshot.project,
            heads: snapshot.heads
        )
        return merged
    }

    private func mergeStarting(
        project: SpektraProjectDocument,
        heads: [String: UInt64]
    ) async throws -> (project: SpektraProjectDocument, heads: [String: UInt64]) {
        var merged = project
        var cursors = heads
        var operations = try unreadOperations(after: cursors)
        operations.sort {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            if $0.deviceID != $1.deviceID { return $0.deviceID < $1.deviceID }
            if $0.counter != $1.counter { return $0.counter < $1.counter }
            return $0.id.uuidString < $1.id.uuidString
        }
        for op in operations {
            apply(op, to: &merged)
            cursors[op.deviceID] = max(cursors[op.deviceID, default: 0], op.counter)
        }
        resolveCloudPaths(in: &merged)
        return (merged, cursors)
    }

    private func apply(_ operation: CloudLibraryOperation, to project: inout SpektraProjectDocument) {
        switch operation.kind {
        case .photoUpsert:
            guard var photo = operation.photo else { return }
            resolveCloudPath(in: &photo)
            if let i = project.images.firstIndex(where: { $0.id == photo.id }) {
                project.images[i] = photo
            } else {
                project.images.append(photo)
            }

        case .photoDelete:
            guard let id = operation.photoID else { return }
            project.images.removeAll { $0.id == id }
            for i in project.albums.indices { project.albums[i].imageIDs.remove(id) }
            for i in project.peopleGroups.indices { project.peopleGroups[i].imageIDs.remove(id) }
            if project.selectedImageID == id { project.selectedImageID = project.images.first?.id }

        case .lookUpdate:
            guard let id = operation.photoID, let look = operation.look,
                  let i = project.images.firstIndex(where: { $0.id == id }) else { return }
            project.images[i].look = look

        case .photoStateUpdate:
            guard let id = operation.photoID, let state = operation.photoState,
                  let i = project.images.firstIndex(where: { $0.id == id }) else { return }
            state.apply(to: &project.images[i])

        case .projectMetadataUpdate:
            operation.metadata?.apply(to: &project)
        }
    }

    private func makeOperation(
        kind: CloudLibraryOperationKind,
        photoID: UUID? = nil,
        photo: ProjectImageRecord? = nil,
        look: RenderLook? = nil,
        photoState: CloudPhotoState? = nil,
        metadata: CloudProjectMetadata? = nil
    ) -> CloudLibraryOperation {
        localCounter += 1
        return CloudLibraryOperation(
            id: UUID(),
            deviceID: deviceID,
            counter: localCounter,
            createdAt: Date(),
            kind: kind,
            photoID: photoID,
            photo: photo,
            look: look,
            photoState: photoState,
            metadata: metadata
        )
    }

    private func writeOperation(_ operation: CloudLibraryOperation) throws {
        let dir = journalURL.appendingPathComponent(deviceID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(
            String(format: "%020llu-%@.sfop", operation.counter, operation.id.uuidString)
        )
        try Self.coordinatedWrite(Self.encoder.encode(operation), to: file)
        try writeDeviceHead(operation.counter)
    }

    private func unreadOperations(after heads: [String: UInt64]) throws -> [CloudLibraryOperation] {
        let fm = FileManager.default
        guard let devices = try? fm.contentsOfDirectory(
            at: journalURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [CloudLibraryOperation] = []
        for deviceDir in devices {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: deviceDir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let device = deviceDir.lastPathComponent
            let after = heads[device, default: 0]
            let remoteHead = try readDeviceHead(device)
            guard remoteHead > after else { continue }
            guard let files = try? fm.contentsOfDirectory(
                at: deviceDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in files where file.pathExtension == "sfop" {
                guard let counter = Self.counter(from: file.lastPathComponent), counter > after else { continue }
                do {
                    let op = try Self.decoder.decode(CloudLibraryOperation.self, from: Self.coordinatedRead(file))
                    result.append(op)
                } catch {
                    // A partially downloaded iCloud entry must not corrupt the whole library.
                    continue
                }
            }
        }
        return result
    }

    private func writeSnapshot(project: SpektraProjectDocument) async throws {
        let heads = seenHeads
        let snapshot = CloudLibrarySnapshot(
            schemaVersion: CloudLibraryManifest.schemaVersion,
            libraryID: manifest.libraryID,
            createdAt: Date(),
            heads: heads,
            project: project
        )
        let name = "\(Self.timestampString(snapshot.createdAt))-\(UUID().uuidString).sfsnapshot"
        try Self.coordinatedWrite(
            Self.encoder.encode(snapshot),
            to: snapshotsURL.appendingPathComponent(name)
        )
        seenHeads = heads
    }

    private func bestSnapshotURL() throws -> URL? {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(
            at: snapshotsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ))?.filter { $0.pathExtension == "sfsnapshot" } ?? []
        if files.isEmpty { return nil }

        var best: (url: URL, score: UInt64, created: Date)?
        for file in files {
            guard let data = try? Self.coordinatedRead(file),
                  let snapshot = try? Self.decoder.decode(CloudLibrarySnapshot.self, from: data),
                  snapshot.libraryID == manifest.libraryID else { continue }
            let score = snapshot.heads.values.reduce(UInt64(0), +)
            if best == nil || score > best!.score || (score == best!.score && snapshot.createdAt > best!.created) {
                best = (file, score, snapshot.createdAt)
            }
        }
        return best?.url
    }

    private func readAllHeads() throws -> [String: UInt64] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: headsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return seenHeads }

        var result = seenHeads
        for file in files where file.pathExtension == "json" {
            struct Head: Codable { var deviceID: String; var counter: UInt64 }
            guard let data = try? Self.coordinatedRead(file),
                  let head = try? Self.decoder.decode(Head.self, from: data) else { continue }
            result[head.deviceID] = max(result[head.deviceID, default: 0], head.counter)
        }
        return result
    }

    private func writeDeviceHead(_ counter: UInt64) throws {
        struct Head: Codable { var deviceID: String; var counter: UInt64; var updatedAt: Date }
        let head = Head(deviceID: deviceID, counter: counter, updatedAt: Date())
        try Self.coordinatedWrite(
            Self.encoder.encode(head),
            to: headsURL.appendingPathComponent("\(deviceID).json")
        )
    }

    private func readDeviceHead(_ device: String) throws -> UInt64 {
        struct Head: Codable { var deviceID: String; var counter: UInt64 }
        let url = headsURL.appendingPathComponent("\(device).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        return (try? Self.decoder.decode(Head.self, from: Self.coordinatedRead(url)).counter) ?? 0
    }

    private func resolveCloudPaths(in project: inout SpektraProjectDocument) {
        for i in project.images.indices { resolveCloudPath(in: &project.images[i]) }
    }

    private func resolveCloudPath(in image: inout ProjectImageRecord) {
        guard let relative = image.cloudRelativePath else { return }
        image.sourcePath = rootURL.appendingPathComponent(relative).path
    }

    private func sourceIdentity(_ image: ProjectImageRecord) -> String {
        "\(image.cloudRelativePath ?? image.sourcePath)|\(image.sourceFileSize ?? -1)|\(image.sourceModificationTime ?? -1)"
    }

    private func originalRelativePath(photoID: UUID, fileName: String) -> String {
        let prefix = String(photoID.uuidString.prefix(2))
        return "Originals/\(prefix)/\(photoID.uuidString)/\(fileName)"
    }

    private func previewRelativePath(photoID: UUID) -> String {
        let prefix = String(photoID.uuidString.prefix(2))
        return "Previews/\(prefix)/\(photoID.uuidString).jpg"
    }

    private var journalURL: URL { rootURL.appendingPathComponent("Journal", isDirectory: true) }
    private var headsURL: URL { rootURL.appendingPathComponent("Heads", isDirectory: true) }
    private var snapshotsURL: URL { rootURL.appendingPathComponent("Snapshots", isDirectory: true) }

    private static func createStructure(_ root: URL) throws {
        for name in ["Originals", "Previews", "Journal", "Heads", "Snapshots", "Migration"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    private static func counter(from fileName: String) -> UInt64? {
        UInt64(fileName.prefix(20))
    }

    private static func timestampString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    private static func mapColorLabel(_ value: String?) -> PhotoColorLabel? {
        switch value?.lowercased() {
        case "red": return .red
        case "yellow": return .yellow
        case "green": return .green
        case "blue": return .blue
        case "purple", "magenta": return .purple
        default: return nil
        }
    }

    private static func parseLightroomDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        let formats = ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy:MM:dd HH:mm:ss"]
        for format in formats {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = format
            if let date = f.date(from: value) { return date }
        }
        return nil
    }

    private static func fileSize(_ url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let value = attrs[.size] as? NSNumber else { return nil }
        return value.int64Value
    }

    private static func modificationTime(_ url: URL) -> TimeInterval? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let value = attrs[.modificationDate] as? Date else { return nil }
        return value.timeIntervalSince1970
    }

    static func materializeIfNeeded(_ url: URL, timeout: TimeInterval = 180) async throws {
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard values?.isUbiquitousItem == true else { return }
        if values?.ubiquitousItemDownloadingStatus == .current ||
            values?.ubiquitousItemDownloadingStatus == .downloaded { return }

        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            let current = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if current?.ubiquitousItemDownloadingStatus == .current ||
                current?.ubiquitousItemDownloadingStatus == .downloaded { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw CloudError.downloadTimedOut(url.path)
    }

    static func streamCopy(from source: URL, to destination: URL, bufferSize: Int = 8 * 1024 * 1024) throws {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw CloudError.sourceMissing(source.path)
        }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: destination.path) {
            let sourceSize = fileSize(source)
            let destinationSize = fileSize(destination)
            if sourceSize != nil, sourceSize == destinationSize { return }
            try FileManager.default.removeItem(at: destination)
        }

        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil) else {
            throw CloudError.createFailed(temp.path)
        }

        guard let input = InputStream(url: source),
              let output = OutputStream(url: temp, append: false) else {
            try? FileManager.default.removeItem(at: temp)
            throw CloudError.streamOpenFailed(source.path)
        }

        input.open()
        output.open()
        defer {
            input.close()
            output.close()
        }

        var buffer = [UInt8](repeating: 0, count: max(64 * 1024, bufferSize))
        do {
            while true {
                try Task.checkCancellation()
                let read = input.read(&buffer, maxLength: buffer.count)
                if read < 0 { throw input.streamError ?? CloudError.readFailed(source.path) }
                if read == 0 { break }

                var offset = 0
                while offset < read {
                    let written = buffer.withUnsafeBytes { raw -> Int in
                        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                        return output.write(base.advanced(by: offset), maxLength: read - offset)
                    }
                    if written <= 0 { throw output.streamError ?? CloudError.writeFailed(destination.path) }
                    offset += written
                }
            }
            try FileManager.default.moveItem(at: temp, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    private static func coordinatedWrite(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: url,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            do { try data.write(to: coordinatedURL, options: .atomic) }
            catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    private static func coordinatedRead(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var readResult: Result<Data, Error>?
        NSFileCoordinator().coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            readResult = Result { try Data(contentsOf: coordinatedURL, options: .mappedIfSafe) }
        }
        if let coordinationError { throw coordinationError }
        guard let readResult else { throw CloudError.readFailed(url.path) }
        return try readResult.get()
    }
}
