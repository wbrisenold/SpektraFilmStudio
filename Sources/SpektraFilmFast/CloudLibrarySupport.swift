import AppKit
import Foundation
import UniformTypeIdentifiers

enum SpektraCloudDeviceIdentity {
    static let key = "SpektraFilmStudio.cloudDeviceID"

    static var current: String {
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString.lowercased()
        UserDefaults.standard.set(created, forKey: key)
        return created
    }
}

@MainActor
extension AppModel {
    var isCloudLibraryConnected: Bool { cloudLibrary != nil }

    func restoreCloudLibraryIfPossible() async {
        guard cloudLibrary == nil else { return }
        let path = cloudLibraryRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            cloudLibraryStatus = "Not connected"
            return
        }

        let root = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path) else {
            cloudLibraryStatus = "Cloud library not found at saved location"
            return
        }

        do {
            cloudLibraryStatus = "Opening iCloud Library…"
            let library = try await SpektraCloudLibrary.open(
                at: root,
                deviceID: SpektraCloudDeviceIdentity.current
            )
            let loaded = try await library.initialProject()
            cloudLibrary = library
            replaceProjectFromCloud(loaded, resetWorkspace: true)
            cloudLibraryStatus = "iCloud Library ready"
            cloudLastSync = Date()
            startCloudSyncLoop()
        } catch {
            cloudLibraryStatus = "Cloud open failed · \(error.localizedDescription)"
        }
    }

    func moveCurrentLibraryToICloud() {
        guard !isCloudSyncing else { return }
        guard let parent = chooseCloudParent(
            title: "Choose iCloud Drive Folder",
            prompt: "Use for SpektraFilm Cloud"
        ) else { return }
        moveCurrentLibraryToICloud(parent: parent)
    }

    func moveCurrentLibraryToICloud(parent: URL) {
        guard !isCloudSyncing, cloudLibrary == nil else { return }
        guard confirmCloudLocation(parent) else { return }

        let folderName = sanitizedCloudLibraryName(project.name)
        let root = uniqueCloudLibraryURL(parent: parent, preferredName: folderName)

        isCloudSyncing = true
        cloudSyncProgress = 0
        cloudLibraryStatus = "Preparing iCloud Library…"

        let snapshot = project
        Task { [weak self] in
            guard let self else { return }
            do {
                let library = try await SpektraCloudLibrary.create(
                    at: root,
                    name: snapshot.name,
                    deviceID: SpektraCloudDeviceIdentity.current,
                    project: snapshot
                ) { completed, total, fileName in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        cloudSyncProgress = total > 0 ? Double(completed) / Double(total) : 1
                        cloudLibraryStatus = "Uploading originals \(completed)/\(total) · \(fileName)"
                    }
                }
                let loaded = try await library.currentProject()
                cloudLibrary = library
                cloudLibraryRootPath = root.path
                UserDefaults.standard.set(root.path, forKey: "SpektraFilmStudio.cloudLibraryRootPath")
                replaceProjectFromCloud(loaded, resetWorkspace: true)
                isCloudSyncing = false
                cloudSyncProgress = 1
                cloudLastSync = Date()
                cloudLibraryStatus = "iCloud Library synced"
                startCloudSyncLoop()
            } catch {
                isCloudSyncing = false
                cloudLibraryStatus = "iCloud migration failed · \(error.localizedDescription)"
            }
        }
    }

    func importLightroomCatalogToICloud() {
        guard !isCloudSyncing else { return }

        let catalogPanel = NSOpenPanel()
        catalogPanel.title = "Choose Lightroom Classic Catalog"
        catalogPanel.prompt = "Import Catalog"
        catalogPanel.allowsMultipleSelection = false
        catalogPanel.canChooseDirectories = false
        catalogPanel.canChooseFiles = true
        if let type = UTType(filenameExtension: "lrcat") {
            catalogPanel.allowedContentTypes = [type]
        }
        guard catalogPanel.runModal() == .OK, let catalogURL = catalogPanel.url else { return }

        guard let parent = chooseCloudParent(
            title: "Choose iCloud Drive Destination",
            prompt: "Import to iCloud"
        ) else { return }
        importLightroomCatalogToICloud(catalogURL: catalogURL, parent: parent)
    }

    func importLightroomCatalogToICloud(catalogURL: URL, parent: URL) {
        guard !isCloudSyncing, cloudLibrary == nil else { return }
        guard confirmCloudLocation(parent) else { return }

        let baseName = catalogURL.deletingPathExtension().lastPathComponent
        let projectName = baseName.isEmpty ? "Lightroom Migration" : baseName
        let root = uniqueCloudLibraryURL(
            parent: parent,
            preferredName: sanitizedCloudLibraryName(projectName)
        )

        isCloudSyncing = true
        cloudSyncProgress = 0
        cloudLibraryStatus = "Reading Lightroom catalog…"

        Task { [weak self] in
            guard let self else { return }
            do {
                // A .lrcat selected from iCloud Drive may itself be a placeholder. The catalog is
                // normally tiny relative to the originals, so materialize it before SQLite opens it.
                try await SpektraCloudLibrary.materializeIfNeeded(catalogURL)
                var snapshot = try await Task.detached(priority: .userInitiated) {
                    try LightroomCatalogImport().read(catalogURL)
                }.value
                remapMissingLightroomOriginalsIfRequested(snapshot: &snapshot)

                var empty = SpektraProjectDocument()
                empty.name = projectName
                let library = try await SpektraCloudLibrary.create(
                    at: root,
                    name: projectName,
                    deviceID: SpektraCloudDeviceIdentity.current,
                    project: empty
                )

                let result = try await library.importLightroomClassic(
                    catalogURL: catalogURL,
                    snapshot: snapshot,
                    projectName: projectName
                ) { completed, total, fileName in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        cloudSyncProgress = total > 0 ? Double(completed) / Double(total) : 1
                        cloudLibraryStatus = "Migrating Lightroom \(completed)/\(total) · \(fileName)"
                    }
                }

                cloudLibrary = library
                cloudLibraryRootPath = root.path
                UserDefaults.standard.set(root.path, forKey: "SpektraFilmStudio.cloudLibraryRootPath")
                replaceProjectFromCloud(result.0, resetWorkspace: true)
                isCloudSyncing = false
                cloudSyncProgress = 1
                cloudLastSync = Date()

                let report = result.1
                let missing = report.missingOriginals.count
                cloudLibraryStatus = missing == 0
                    ? "Lightroom migration complete · \(report.importedPhotos) photos"
                    : "Migration complete · \(report.importedPhotos) photos · \(missing) originals missing"
                startCloudSyncLoop()

                if missing > 0 || !report.warnings.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = "Lightroom migration completed with notes"
                    alert.informativeText = """
                    Imported \(report.importedPhotos) photo records and \(report.collections) collections.
                    Copied \(report.copiedOriginals) unique originals and reused \(report.reusedOriginals) for virtual copies.
                    Missing originals: \(missing).
                    Lightroom's original develop payloads were preserved in the Migration folder even when a setting could not be translated.
                    """
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            } catch {
                isCloudSyncing = false
                cloudLibraryStatus = "Lightroom migration failed · \(error.localizedDescription)"
            }
        }
    }

    func openICloudLibrary() {
        guard !isCloudSyncing else { return }
        didStartProjectWorkflow = true
        // SwiftUI presents the folder chooser; AppKit's nested runModal was unsafe.
        showingICloudFolderPicker = true
    }

    func openICloudLibrary(at root: URL) {
        guard !isCloudSyncing else { return }
        didStartProjectWorkflow = true
        guard root.isFileURL else {
            cloudLibraryStatus = "Choose a local or iCloud Drive library folder"
            return
        }
        // Validate before changing the current project or disconnecting anything.
        let accessed = root.startAccessingSecurityScopedResource()
        let manifestExists = FileManager.default.fileExists(
            atPath: root.appendingPathComponent("manifest.json").path
        )
        if accessed { root.stopAccessingSecurityScopedResource() }
        guard manifestExists else {
            cloudLibraryStatus = "Not a SpektraFilm library: select the folder containing manifest.json"
            return
        }
        guard confirmCloudLibraryTransition() else { return }
        isCloudSyncing = true
        cloudLibraryStatus = "Opening iCloud Library…"
        Task { [weak self] in
            guard let self else { return }
            do {
                // Load/merge away from the UI actor. Retain security access through I/O.
                let opened = try await Task.detached(priority: .userInitiated) {
                    let accessed = root.startAccessingSecurityScopedResource()
                    defer { if accessed { root.stopAccessingSecurityScopedResource() } }
                    let library = try await SpektraCloudLibrary.open(
                        at: root,
                        deviceID: SpektraCloudDeviceIdentity.current
                    )
                    let loaded = try await library.initialProject()
                    return (library, loaded)
                }.value
                let (library, loaded) = opened
                cloudLibrary = library
                cloudLibraryRootPath = root.path
                UserDefaults.standard.set(root.path, forKey: "SpektraFilmStudio.cloudLibraryRootPath")
                replaceProjectFromCloud(loaded, resetWorkspace: true)
                isCloudSyncing = false
                cloudSyncProgress = 1
                cloudLastSync = Date()
                cloudLibraryStatus = "iCloud Library ready"
                startCloudSyncLoop()
            } catch {
                isCloudSyncing = false
                cloudLibraryStatus = "Cloud open failed · \(error.localizedDescription)"
            }
        }
    }

    func disconnectCloudLibrary() {
        cloudSyncLoopTask?.cancel()
        cloudSyncLoopTask = nil
        cloudPublishTask?.cancel()
        cloudPublishTask = nil
        cloudLibrary = nil
        cloudLibraryRootPath = ""
        UserDefaults.standard.removeObject(forKey: "SpektraFilmStudio.cloudLibraryRootPath")
        cloudLibraryStatus = "Not connected"
        cloudSyncProgress = 0
        cloudLastSync = nil
    }

    func scheduleCloudPublish() {
        guard cloudLibrary != nil else { return }
        cloudPublishTask?.cancel()
        cloudPublishTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(900))
                guard let self, !Task.isCancelled else { return }
                await synchronizeCloudNow(userInitiated: false)
            } catch {
                return
            }
        }
    }

    func synchronizeCloudNow(userInitiated: Bool = true) async {
        guard let library = cloudLibrary, !isCloudSyncing else { return }
        guard !isInteractiveEditActive else {
            if userInitiated { cloudLibraryStatus = "Finish the current slider/mask gesture, then sync" }
            return
        }

        isCloudSyncing = true
        if userInitiated { cloudLibraryStatus = "Syncing iCloud Library…" }
        let snapshot = project

        do {
            let result = try await library.synchronize(project: snapshot)
            if result.didChangeProject {
                let selected = project.selectedImageID
                replaceProjectFromCloud(
                    result.project,
                    preferredSelection: selected,
                    resetWorkspace: false
                )
            }
            isCloudSyncing = false
            cloudSyncProgress = 1
            cloudLastSync = Date()
            isProjectDirty = false
            cloudLibraryStatus = result.pushedOperations == 0 && result.pulledOperations == 0
                ? "iCloud Library up to date"
                : "Synced · ↑\(result.pushedOperations) ↓\(result.pulledOperations)"
        } catch {
            isCloudSyncing = false
            cloudLibraryStatus = "Cloud sync warning · \(error.localizedDescription)"
        }
    }

    func chooseExternalOriginalScratch() {
        let panel = NSOpenPanel()
        panel.title = "Choose External RAW Scratch Drive"
        panel.message = "Select a mounted external SSD or network volume. Cloud originals are staged there only while editing or exporting. Internal startup disk is not allowed."
        panel.prompt = "Use as RAW Scratch"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        do {
            _ = try ExternalOriginalScratch.validatedRoot(parent)
            externalOriginalScratchParent = parent.path
            UserDefaults.standard.set(parent.path, forKey: "SpektraFilmStudio.externalOriginalScratchParent")
            cloudLibraryStatus = "External RAW scratch: \(parent.lastPathComponent)"
        } catch {
            cloudLibraryStatus = error.localizedDescription
        }
    }

    func keepSelectedCloudOriginalsDownloaded() {
        // Legacy action now means only the currently edited original, never bulk pinning.
        guard page == .edit, let photo = selectedImage,
              photo.cloudRelativePath != nil else {
            cloudLibraryStatus = "Open the photo in Edit to stage its original; library browsing uses previews"
            return
        }
        if !deferPreviewForCloudOriginalIfNeeded(photo, renderPreview: true) {
            cloudLibraryStatus = "Current RAW is already staged on the external drive"
        }
    }

    func freeSelectedCloudOriginals() {
        guard let library = cloudLibrary else { return }
        let images = cloudTargetImages()
        let ids = Set(images.map(\.id))
        Task { [weak self] in
            guard let self else { return }
            await ExternalOriginalScratch.shared.forget(ids)
            for image in images {
                guard let relative = image.cloudRelativePath else { continue }
                try? await library.evict(relativePath: relative)
            }
            cloudLibraryStatus = "Unused scratch originals cleared and iCloud cache eviction requested"
        }
    }

    /// A cloud original is staged only after entering Edit or beginning Export.
    /// Library/Cull selection uses previews and never calls the RAW decoder.
    func deferPreviewForCloudOriginalIfNeeded(
        _ image: ProjectImageRecord,
        renderPreview: Bool
    ) -> Bool {
        guard let library = cloudLibrary, let relative = image.cloudRelativePath else { return false }
        guard renderPreview else {
            status = "Selected \(image.fileName) · cloud preview only"
            return true
        }
        if let staged = stagedCloudOriginals[image.id],
           FileManager.default.fileExists(atPath: staged.path) { return false }
        guard !externalOriginalScratchParent.isEmpty else {
            status = "Choose an external RAW scratch drive in Library before editing cloud photos"
            return true
        }
        let parent = URL(fileURLWithPath: externalOriginalScratchParent, isDirectory: true)
        let imageID = image.id
        let originalURL = URL(fileURLWithPath: cloudLibraryRootPath, isDirectory: true)
            .appendingPathComponent(relative)
        status = "Staging \(image.fileName) to external RAW scratch…"
        Task { [weak self] in
            guard let self else { return }
            await ExternalOriginalScratch.shared.setEditing(imageID)
            do {
                let staged = try await ExternalOriginalScratch.shared.stage(
                    photoID: imageID, fileName: image.fileName,
                    original: originalURL, relativePath: relative,
                    library: library, parent: parent
                )
                guard project.selectedImageID == imageID, page == .edit else {
                    await ExternalOriginalScratch.shared.setEditing(nil)
                    return
                }
                stagedCloudOriginals[imageID] = staged
                guard let active = selectedImage else { return }
                status = "External RAW ready: \(active.fileName)"
                refreshWhiteBalanceReference(for: active)
                presentFastSelectionPreview(for: active, renderOnMiss: true)
            } catch {
                if project.selectedImageID == imageID {
                    status = "RAW scratch failed · \(error.localizedDescription)"
                }
            }
        }
        return true
    }

    func startCloudSyncLoop() {
        cloudSyncLoopTask?.cancel()
        guard cloudLibrary != nil else { return }
        cloudSyncLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(8)) }
                catch { return }
                guard let self, self.cloudLibrary != nil else { return }
                if !self.isCloudSyncing && !self.isInteractiveEditActive {
                    await self.synchronizeCloudNow(userInitiated: false)
                }
            }
        }
    }

    private func replaceProjectFromCloud(
        _ incoming: SpektraProjectDocument,
        preferredSelection: UUID? = nil,
        resetWorkspace: Bool
    ) {
        let previousPage = page
        let previousSelected = project.selectedImageID
        let previousLook = selectedImage?.look

        if resetWorkspace { prepareForCloudProjectReplacement() }
        suppressDirtyTracking = true
        var loaded = incoming
        loaded.migrateForV2()
        if let preferredSelection,
           loaded.images.contains(where: { $0.id == preferredSelection }) {
            loaded.selectedImageID = preferredSelection
        } else if let previousSelected,
                  loaded.images.contains(where: { $0.id == previousSelected }) {
            loaded.selectedImageID = previousSelected
        } else if loaded.selectedImageID == nil {
            loaded.selectedImageID = loaded.images.first?.id
        }
        project = loaded
        projectURL = nil
        suppressDirtyTracking = false
        isProjectDirty = false

        let validIDs = Set(project.images.map(\.id))
        librarySelection.formIntersection(validIDs)

        if resetWorkspace {
            showProjectHome = false
            page = .library
            renderedPreview = nil
            sourcePreview = nil
            librarySelection.removeAll()
            return
        }

        page = previousPage
        if previousLook != selectedImage?.look {
            if page == .edit, selectedImage != nil {
                requestPreviewRefresh()
            }
        }
    }

    func updateCloudPreview(photoID: UUID, image: CGImage) {
        guard !cloudLibraryRootPath.isEmpty,
              let record = project.images.first(where: { $0.id == photoID }),
              let relative = record.cloudPreviewRelativePath else { return }
        let destination = URL(fileURLWithPath: cloudLibraryRootPath, isDirectory: true)
            .appendingPathComponent(relative)
        let payload = CloudPreviewImage(value: image)
        Task { await CloudPreviewWriter.shared.write(payload, destination: destination) }
    }

    func thumbnailURL(for image: ProjectImageRecord) -> URL {
        guard let relative = image.cloudPreviewRelativePath,
              !cloudLibraryRootPath.isEmpty else { return image.url }
        let candidate = URL(fileURLWithPath: cloudLibraryRootPath, isDirectory: true)
            .appendingPathComponent(relative)
        // No preview available: show a placeholder, never trigger File Provider RAW fetch.
        return FileManager.default.fileExists(atPath: candidate.path)
            ? candidate : URL(fileURLWithPath: "/dev/null")
    }

    private func cloudTargetImages() -> [ProjectImageRecord] {
        let ids = librarySelection.isEmpty
            ? Set([project.selectedImageID].compactMap { $0 })
            : librarySelection
        return project.images.filter { ids.contains($0.id) && $0.cloudRelativePath != nil }
    }

    private func remapMissingLightroomOriginalsIfRequested(
        snapshot: inout LightroomCatalogImport.Snapshot
    ) {
        let fm = FileManager.default
        let missingIndices = snapshot.photos.indices.filter {
            !fm.fileExists(atPath: snapshot.photos[$0].absolutePath)
        }
        guard !missingIndices.isEmpty else { return }

        let oldRoot = commonParentDirectory(
            missingIndices.map { URL(fileURLWithPath: snapshot.photos[$0].absolutePath) }
        )

        let alert = NSAlert()
        alert.messageText = "\(missingIndices.count) Lightroom original\(missingIndices.count == 1 ? "" : "s") not found"
        alert.informativeText = oldRoot.map {
            "The catalog points into \($0.path). If that library moved to another drive or cloud folder, choose the replacement folder and SpektraFilm will remap the relative paths before uploading to iCloud."
        } ?? "Choose the folder that now contains these Lightroom originals, or continue and relink them later."
        alert.addButton(withTitle: "Locate Replacement Root…")
        alert.addButton(withTitle: "Continue With Missing")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let panel = NSOpenPanel()
        panel.title = "Locate Lightroom Originals"
        panel.prompt = "Use This Root"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let replacementRoot = panel.url else { return }

        guard let oldRoot else {
            snapshot.warnings.append("Could not infer a common Lightroom source root for path remapping.")
            return
        }

        var remapped = 0
        for index in missingIndices {
            let original = URL(fileURLWithPath: snapshot.photos[index].absolutePath)
            guard let relative = relativePath(from: oldRoot, to: original) else { continue }
            let candidate = replacementRoot.appendingPathComponent(relative)
            if fm.fileExists(atPath: candidate.path) {
                snapshot.photos[index].absolutePath = candidate.path
                remapped += 1
            }
        }
        snapshot.warnings.append(
            "Remapped \(remapped) of \(missingIndices.count) missing Lightroom originals from \(oldRoot.path) to \(replacementRoot.path)."
        )
    }

    private func commonParentDirectory(_ files: [URL]) -> URL? {
        guard var components = files.first?.deletingLastPathComponent().standardizedFileURL.pathComponents else {
            return nil
        }
        for file in files.dropFirst() {
            let next = file.deletingLastPathComponent().standardizedFileURL.pathComponents
            var count = 0
            while count < min(components.count, next.count), components[count] == next[count] {
                count += 1
            }
            components = Array(components.prefix(count))
            if components.isEmpty { return nil }
        }
        guard components.count > 1 else { return nil }
        var url = URL(fileURLWithPath: components[0], isDirectory: true)
        for component in components.dropFirst() {
            url.appendPathComponent(component, isDirectory: true)
        }
        return url.standardizedFileURL
    }

    private func relativePath(from root: URL, to file: URL) -> String? {
        let rootComponents = root.standardizedFileURL.pathComponents
        let fileComponents = file.standardizedFileURL.pathComponents
        guard fileComponents.starts(with: rootComponents) else { return nil }
        return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private func chooseCloudParent(title: String, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = SpektraCloudLibrary.defaultICloudDriveURL()
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func confirmCloudLocation(_ url: URL) -> Bool {
        guard !SpektraCloudLibrary.looksLikeICloudDrive(url) else { return true }
        let alert = NSAlert()
        alert.messageText = "This folder does not look like iCloud Drive"
        alert.informativeText = "SpektraFilm can use any File Provider folder, but choose iCloud Drive if you want this library to be your iCloud-synced Lightroom replacement."
        alert.addButton(withTitle: "Use Anyway")
        alert.addButton(withTitle: "Choose Again")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func sanitizedCloudLibraryName(_ raw: String) -> String {
        let base = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "SpektraFilm Library" : raw
        let illegal = CharacterSet(charactersIn: "/:")
        let cleaned = base.components(separatedBy: illegal).joined(separator: "-")
        return "\(cleaned) - SpektraFilm.sflibrary"
    }

    private func uniqueCloudLibraryURL(parent: URL, preferredName: String) -> URL {
        let fm = FileManager.default
        var candidate = parent.appendingPathComponent(preferredName, isDirectory: true)
        if !fm.fileExists(atPath: candidate.path) { return candidate }

        let stem = URL(fileURLWithPath: preferredName).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: preferredName).pathExtension
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(stem) \(n).\(ext)", isDirectory: true)
            n += 1
        }
        return candidate
    }
}
