import Foundation

@MainActor
extension AppModel {
    func libraryCount(_ filter: LibraryFilter) -> Int {
        project.images.reduce(into: 0) { count, image in
            let matches: Bool
            switch filter {
            case .all: matches = true
            case .picked: matches = image.flag == .picked
            case .clientPicks: matches = image.clientPicked
            case .rejected: matches = image.flag == .rejected
            case .unrated: matches = image.rating == 0
            case .fiveStar: matches = image.rating == 5
            case .needsReview: matches = image.cullAnalysis?.recommendation == .review
            case .exportQueued: matches = image.selectedForExport
            case .missing: matches = !FileManager.default.fileExists(atPath: image.sourcePath)
            }
            if matches { count += 1 }
        }
    }

    func setColorLabel(_ label: PhotoColorLabel?) {
        guard let index = selectedIndex else { return }
        project.images[index].colorLabel = label
    }

    func analyzeSelectedForCull() {
        guard let id = selectedImage?.id else { return }
        startCullAnalysis(ids: [id])
    }

    func analyzeVisibleForCull() {
        startCullAnalysis(ids: visibleImages.map(\.id))
    }

    func analyzeForCull(ids: [UUID]) {
        startCullAnalysis(ids: ids)
    }

    func analyzeCullNeighborhood() {
        startCullAnalysis(ids: cullComparisonImages.map(\.id))
    }

    func cancelCullAnalysis() {
        cullTask?.cancel()
        cullTask = nil
        isCullAnalyzing = false
        status = "Smart Cull canceled"
    }

    private func startCullAnalysis(ids: [UUID]) {
        let unique = Array(Set(ids))
        let items: [(UUID, URL)] = unique.compactMap { id in
            guard let image = project.images.first(where: { $0.id == id }),
                  FileManager.default.fileExists(atPath: image.sourcePath) else { return nil }
            return (id, image.url)
        }
        guard !items.isEmpty else { return }

        cullTask?.cancel()
        isCullAnalyzing = true
        cullAnalysisProgress = 0
        status = "Smart Cull analyzing 0 / \(items.count)…"

        let engine = cullEngine
        let thumbnailer = thumbnails
        let analysisCache = cullDiskCache
        cullTask = Task { [weak self] in
            guard let self else { return }
            let chunkSize = 3
            var completed = 0

            for start in stride(from: 0, to: items.count, by: chunkSize) {
                if Task.isCancelled { break }
                let chunk = Array(items[start..<min(items.count, start + chunkSize)])
                let results = await withTaskGroup(of: (UUID, CullAnalysisRecord?).self, returning: [(UUID, CullAnalysisRecord?)].self) { group in
                    for (id, url) in chunk {
                        group.addTask {
                            guard !Task.isCancelled else { return (id, nil) }
                            if let cached = await analysisCache.analysis(url: url) {
                                return (id, cached)
                            }
                            guard let payload = try? await thumbnailer.thumbnail(url: url, maxPixel: 1280),
                                  !Task.isCancelled,
                                  let analyzed = try? await engine.analyze(payload) else {
                                return (id, nil)
                            }
                            await analysisCache.store(analyzed.record, url: url)
                            return (id, analyzed.record)
                        }
                    }
                    var values: [(UUID, CullAnalysisRecord?)] = []
                    for await value in group { values.append(value) }
                    return values
                }

                if Task.isCancelled { break }
                for (id, record) in results {
                    if let record, let index = project.images.firstIndex(where: { $0.id == id }) {
                        project.images[index].cullAnalysis = record
                    }
                    completed += 1
                }
                cullAnalysisProgress = Double(completed) / Double(items.count)
                status = "Smart Cull analyzing \(completed) / \(items.count)…"
            }

            if Task.isCancelled {
                isCullAnalyzing = false
                cullTask = nil
                return
            }

            rebuildCullStacks()
            isCullAnalyzing = false
            cullAnalysisProgress = 1
            cullTask = nil
            status = "Smart Cull complete · \(items.count) analyzed"
        }
    }

    /// Burst grouping is intentionally explainable and deterministic. Automatic stacks
    /// require real capture timestamps plus temporal and visual proximity. Import time is never
    /// used as a fake capture time because a whole card can be imported within seconds.
    /// The highest technical score becomes rank #1; no photo is deleted automatically.
    private func rebuildCullStacks() {
        let ordered = project.images.indices
            .filter { project.images[$0].captureDate != nil }
            .sorted {
                guard let lhs = project.images[$0].captureDate,
                      let rhs = project.images[$1].captureDate else { return false }
                return lhs < rhs
            }

        var groups: [[Int]] = []
        var current: [Int] = []
        for index in ordered {
            guard let analysis = project.images[index].cullAnalysis else { continue }
            if let previous = current.last,
               let previousAnalysis = project.images[previous].cullAnalysis {
                guard let lhsDate = project.images[previous].captureDate,
                      let rhsDate = project.images[index].captureDate else {
                    if current.count > 1 { groups.append(current) }
                    current = [index]
                    continue
                }
                let seconds = abs(rhsDate.timeIntervalSince(lhsDate))
                let hashDistance = Self.hammingDistance(previousAnalysis.perceptualHash, analysis.perceptualHash)
                if seconds <= 3.0 && hashDistance <= 18 {
                    current.append(index)
                } else {
                    if current.count > 1 { groups.append(current) }
                    current = [index]
                }
            } else {
                if current.count > 1 { groups.append(current) }
                current = [index]
            }
        }
        if current.count > 1 { groups.append(current) }

        // Clear stale stack metadata before rebuilding.
        for index in project.images.indices {
            project.images[index].cullAnalysis?.stackID = nil
            project.images[index].cullAnalysis?.stackRank = nil
            project.images[index].cullAnalysis?.stackCount = nil
        }

        for group in groups {
            let stackID = UUID()
            let ranked = group.sorted {
                (project.images[$0].cullAnalysis?.score ?? 0) > (project.images[$1].cullAnalysis?.score ?? 0)
            }
            for (offset, index) in ranked.enumerated() {
                project.images[index].cullAnalysis?.stackID = stackID
                project.images[index].cullAnalysis?.stackRank = offset + 1
                project.images[index].cullAnalysis?.stackCount = ranked.count
                if offset == 0 {
                    project.images[index].cullAnalysis?.reasons.insert("Best technical frame in stack", at: 0)
                }
            }
        }
    }

    private static func hammingDistance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        Int((lhs ^ rhs).nonzeroBitCount)
    }
}

@MainActor
extension AppModel {
    var librarySelectedImages: [ProjectImageRecord] {
        let ids = librarySelection.isEmpty ? Set([project.selectedImageID].compactMap { $0 }) : librarySelection
        return project.images.filter { ids.contains($0.id) }
    }

    func selectLibraryImage(_ id: UUID, additive: Bool = false, range: Bool = false) {
        let ordered = visibleImages.map(\.id)
        if range, let anchor = librarySelectionAnchor,
           let a = ordered.firstIndex(of: anchor), let b = ordered.firstIndex(of: id) {
            let lo = min(a, b), hi = max(a, b)
            if !additive { librarySelection.removeAll() }
            librarySelection.formUnion(ordered[lo...hi])
        } else if additive {
            if librarySelection.contains(id) { librarySelection.remove(id) }
            else { librarySelection.insert(id) }
            librarySelectionAnchor = id
        } else {
            librarySelection = [id]
            librarySelectionAnchor = id
        }
        selectImage(id, renderPreview: page == .edit)
    }

    func clearLibrarySelection() {
        librarySelection.removeAll()
        librarySelectionAnchor = nil
    }

    func selectAllVisible() {
        librarySelection = Set(visibleImages.map(\.id))
        librarySelectionAnchor = visibleImages.first?.id
    }

    func batchSetRating(_ rating: Int) {
        let ids = Set(librarySelectedImages.map(\.id))
        guard !ids.isEmpty else { return }
        let clamped = max(0, min(5, rating))
        for index in project.images.indices where ids.contains(project.images[index].id) {
            project.images[index].rating = clamped
        }
        writeXMPForSelectionIfEnabled(ids: ids)
        status = "Rated \(ids.count) photo\(ids.count == 1 ? "" : "s") \(clamped) star\(clamped == 1 ? "" : "s")"
    }

    func batchSetFlag(_ flag: ProjectFlag) {
        let ids = Set(librarySelectedImages.map(\.id))
        guard !ids.isEmpty else { return }
        for index in project.images.indices where ids.contains(project.images[index].id) {
            project.images[index].flag = flag
        }
        writeXMPForSelectionIfEnabled(ids: ids)
        status = "\(flag.label) · \(ids.count) photo\(ids.count == 1 ? "" : "s")"
    }

    func batchSetColorLabel(_ label: PhotoColorLabel?) {
        let ids = Set(librarySelectedImages.map(\.id))
        guard !ids.isEmpty else { return }
        for index in project.images.indices where ids.contains(project.images[index].id) {
            project.images[index].colorLabel = label
        }
        writeXMPForSelectionIfEnabled(ids: ids)
    }

    func batchSetExportSelection(_ selected: Bool) {
        let ids = Set(librarySelectedImages.map(\.id))
        for index in project.images.indices where ids.contains(project.images[index].id) {
            project.images[index].selectedForExport = selected
        }
    }


    func syncActiveLookToHighlighted(copyWhiteBalance: Bool, copyGeometry: Bool) {
        guard let source = selectedImage else { return }
        let ids = librarySelection.isEmpty ? Set([source.id]) : librarySelection
        guard ids.count > 1 || !ids.contains(source.id) else {
            status = "Highlight additional photos to sync"
            return
        }

        var changed = 0
        for index in project.images.indices where ids.contains(project.images[index].id) && project.images[index].id != source.id {
            let targetRaw = project.images[index].look.raw
            let targetGeometry = project.images[index].look.geometry
            var synced = source.look
            if !copyWhiteBalance { synced.raw = targetRaw }
            if !copyGeometry { synced.geometry = targetGeometry }
            synced.normalizeForProOnly()
            if project.images[index].look != synced {
                project.images[index].look = synced
                changed += 1
            }
        }

        status = "Synced look to \(changed) photo\(changed == 1 ? "" : "s")" +
            (copyWhiteBalance ? " · WB included" : " · each photo kept its WB") +
            (copyGeometry ? " · crop included" : " · each photo kept its crop")
    }

    func batchSetClientPicked(_ selected: Bool) {
        let ids = Set(librarySelectedImages.map(\.id))
        guard !ids.isEmpty else { return }
        for index in project.images.indices where ids.contains(project.images[index].id) {
            project.images[index].clientPicked = selected
        }
        status = selected
            ? "Marked \(ids.count) photo\(ids.count == 1 ? "" : "s") as Client Pick"
            : "Cleared Client Pick from \(ids.count) photo\(ids.count == 1 ? "" : "s")"
    }

    func createAlbum(name: String, imageIDs: Set<UUID>? = nil) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let ids = imageIDs ?? Set(librarySelectedImages.map(\.id))
        project.albums.append(PhotoAlbum(name: clean, imageIDs: ids))
        libraryAlbumFilter = project.albums.last?.id
        librarySmartCollectionFilter = nil
        status = "Created album “\(clean)”"
    }

    func addSelection(toAlbum id: UUID) {
        guard let albumIndex = project.albums.firstIndex(where: { $0.id == id }) else { return }
        let ids = Set(librarySelectedImages.map(\.id))
        project.albums[albumIndex].imageIDs.formUnion(ids)
        status = "Added \(ids.count) photo\(ids.count == 1 ? "" : "s") to \(project.albums[albumIndex].name)"
    }

    func removeSelectionFromCurrentAlbum() {
        guard let id = libraryAlbumFilter,
              let albumIndex = project.albums.firstIndex(where: { $0.id == id }) else { return }
        let ids = Set(librarySelectedImages.map(\.id))
        project.albums[albumIndex].imageIDs.subtract(ids)
    }

    func deleteAlbum(_ id: UUID) {
        project.albums.removeAll { $0.id == id }
        if libraryAlbumFilter == id { libraryAlbumFilter = nil }
    }

    func createSmartCollection(name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let recommendation: CullRecommendation? = libraryFilter == .needsReview ? .review : nil
        let flag: ProjectFlag? = {
            switch libraryFilter {
            case .picked: .picked
            case .rejected: .rejected
            case .clientPicks, .exportQueued: nil
            default: nil
            }
        }()
        let minimumRating = libraryFilter == .fiveStar ? 5 : project.filterRating
        project.smartCollections.append(SmartCollection(
            name: clean,
            minimumRating: minimumRating,
            flag: flag,
            colorLabel: nil,
            cullRecommendation: recommendation,
            searchText: librarySearch
        ))
        librarySmartCollectionFilter = project.smartCollections.last?.id
        libraryAlbumFilter = nil
        status = "Saved smart collection “\(clean)”"
    }

    func deleteSmartCollection(_ id: UUID) {
        project.smartCollections.removeAll { $0.id == id }
        if librarySmartCollectionFilter == id { librarySmartCollectionFilter = nil }
    }


    func rebuildPeopleGroups() {
        guard !isGroupingPeople else { return }
        let items = project.images.compactMap { image -> (UUID, URL)? in
            guard FileManager.default.fileExists(atPath: image.sourcePath) else { return nil }
            return (image.id, image.url)
        }
        guard !items.isEmpty else {
            peopleGroupingStatus = "No photos available"
            return
        }
        peopleGroupingTask?.cancel()
        isGroupingPeople = true
        peopleGroupingStatus = "Grouping faces locally…"
        let engine = faceGroupingEngine
        let generation = projectGeneration
        peopleGroupingTask = Task { [weak self] in
            guard let self else { return }
            let groups = await engine.group(items: items)
            guard !Task.isCancelled, generation == projectGeneration else { return }
            project.peopleGroups = groups
            libraryPeopleGroupFilter = nil
            isGroupingPeople = false
            peopleGroupingTask = nil
            peopleGroupingStatus = groups.isEmpty
                ? "No repeated faces found"
                : "Grouped \(groups.count) repeated face\(groups.count == 1 ? "" : "s")"
            status = peopleGroupingStatus
        }
    }

    func clearPeopleFilter() {
        libraryPeopleGroupFilter = nil
    }

    func selectPeopleGroup(_ group: PersonGroup) {
        libraryPeopleGroupFilter = group.id
        libraryAlbumFilter = nil
        librarySmartCollectionFilter = nil
        librarySelection = group.imageIDs
        librarySelectionAnchor = group.imageIDs.first
    }

    func clearPeopleGroups() {
        peopleGroupingTask?.cancel()
        peopleGroupingTask = nil
        isGroupingPeople = false
        peopleGroupingStatus = ""
        project.peopleGroups = []
        libraryPeopleGroupFilter = nil
        status = "People groups cleared"
    }

    func writeSelectionXMP() {
        let images = librarySelectedImages
        guard !images.isEmpty else { return }
        status = "Writing XMP for \(images.count) photo\(images.count == 1 ? "" : "s")…"
        Task { [weak self] in
            let failures = await XMPService.shared.write(images: images)
            guard let self else { return }
            status = failures.isEmpty
                ? "XMP written for \(images.count) photo\(images.count == 1 ? "" : "s")"
                : "XMP finished with \(failures.count) failure\(failures.count == 1 ? "" : "s")"
        }
    }

    func readSelectionXMP() {
        let ids = Set(librarySelectedImages.map(\.id))
        guard !ids.isEmpty else { return }
        let inputs = project.images.filter { ids.contains($0.id) }.map { ($0.id, $0.url) }
        Task { [weak self] in
            guard let self else { return }
            var values: [UUID: XMPSidecarState] = [:]
            await withTaskGroup(of: (UUID, XMPSidecarState?).self) { group in
                for (id, url) in inputs {
                    group.addTask { (id, await XMPService.shared.read(for: url)) }
                }
                for await (id, state) in group { if let state { values[id] = state } }
            }
            for index in project.images.indices {
                guard let state = values[project.images[index].id] else { continue }
                if let rating = state.rating { project.images[index].rating = rating }
                if let flag = state.flag { project.images[index].flag = flag }
                if let label = state.colorLabel { project.images[index].colorLabel = label }
            }
            status = "Read XMP from \(values.count) photo\(values.count == 1 ? "" : "s")"
        }
    }

    func toggleCullStackCollapsed(_ id: UUID) {
        if collapsedCullStacks.contains(id) { collapsedCullStacks.remove(id) }
        else { collapsedCullStacks.insert(id) }
    }

    private func writeXMPForSelectionIfEnabled(ids: Set<UUID>) {
        guard project.preferences.writeXMPAutomatically else { return }
        let images = project.images.filter { ids.contains($0.id) }
        Task.detached(priority: .utility) {
            _ = await XMPService.shared.write(images: images)
        }
    }
}
