import SwiftUI
import AppKit

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All Photos"
    case picked = "Picked"
    case clientPicks = "Client Picks"
    case rejected = "Rejected"
    case unrated = "Unrated"
    case fiveStar = "5 Stars"
    case needsReview = "AI Review"
    case exportQueued = "Export Queue"
    case missing = "Missing Media"
    var id: String { rawValue }
}

struct LibraryWorkspaceView: View {
    @ObservedObject var model: AppModel
    @State private var showingNewAlbum = false
    @State private var showingNewSmartCollection = false
    @State private var newAlbumName = ""
    @State private var newSmartCollectionName = ""
    @State private var thumbnailSizeDraft: Double = 176
    @State private var showingImportWizard = false
    @State private var preferredImportSource: String?
    @AppStorage("SpektraFilmStudio.designA.showLibraryInspector") private var showLibraryInspector = false

    var body: some View {
        Group {
            if (model.project.images.isEmpty && !model.isIngesting) || model.showProjectHome {
                StudioImportWelcomeView(model: model, showingWizard: $showingImportWizard, preferredSource: $preferredImportSource)
            } else {
                HSplitView {
                    sidebar.frame(minWidth: 170, idealWidth: 190, maxWidth: 235)
                        .padding(StudioLayout.paneInset).studioFloatingPane()
                    VStack(spacing: 0) {
                        toolbar
                        Divider()
                        gallery
                    }
                    if showLibraryInspector {
                        inspector.frame(minWidth: StudioLayout.editorInspectorWidth, idealWidth: StudioLayout.editorInspectorWidth, maxWidth: 440)
                            .padding(StudioLayout.paneInset).studioFloatingPane()
                    }
                }
            }
        }
        .background(StudioPalette.canvas)
        .onAppear { thumbnailSizeDraft = model.libraryThumbnailSize }
        // Do not dismiss Home because a background import or cloud sync added photos.
        // Navigation is explicit: Library enters the grid, Home enters the launcher.
        .onChange(of: model.libraryThumbnailSize) { _, value in
            if abs(thumbnailSizeDraft - value) > 0.5 { thumbnailSizeDraft = value }
        }
        .sheet(isPresented: $showingImportWizard) {
            StudioImportWizard(model: model, preferredSource: preferredImportSource)
        }
        .sheet(isPresented: $showingNewAlbum) {
            namingSheet(title: "New Album", placeholder: "Album name", text: $newAlbumName) {
                model.createAlbum(name: newAlbumName)
                newAlbumName = ""
                showingNewAlbum = false
            }
        }
        .sheet(isPresented: $showingNewSmartCollection) {
            namingSheet(title: "Save Smart Collection", placeholder: "Collection name", text: $newSmartCollectionName) {
                model.createSmartCollection(name: newSmartCollectionName)
                newSmartCollectionName = ""
                showingNewSmartCollection = false
            }
        }
    }

    private var sidebar: some View {
        ScrollView {
          VStack(alignment: .leading, spacing: 6) {
            Text("LIBRARY").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 10)
            ForEach(LibraryFilter.allCases) { filter in
                Button {
                    model.resetLibraryFilters()
                    model.libraryFilter = filter
                } label: {
                    HStack {
                        Image(systemName: icon(filter)).frame(width: 18)
                        Text(filter.rawValue)
                        Spacer()
                        Text("\(model.libraryCount(filter))").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 7)
                    .background(model.libraryFilter == filter ? Color.primary.opacity(0.11) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
            Divider().padding(.vertical, 4)
            HStack {
                Text("COLLECTIONS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { showingNewAlbum = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).help("New album from current selection")
                Button { showingNewSmartCollection = true } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                    .buttonStyle(.plain).help("Save current search/filter as smart collection")
            }.padding(.horizontal, 10)
            if !model.project.albums.isEmpty {
                ForEach(model.project.albums) { album in
                    Button {
                        model.libraryAlbumFilter = album.id
                        model.librarySmartCollectionFilter = nil
                        model.libraryPeopleGroupFilter = nil
                    } label: {
                        HStack { Image(systemName: "rectangle.stack"); Text(album.name).lineLimit(1); Spacer(); Text("\(album.imageIDs.count)").foregroundStyle(.secondary) }
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(model.libraryAlbumFilter == album.id ? Color.primary.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain)
                }
            }
            if !model.project.smartCollections.isEmpty {
                ForEach(model.project.smartCollections) { collection in
                    Button {
                        model.librarySmartCollectionFilter = collection.id
                        model.libraryAlbumFilter = nil
                        model.libraryPeopleGroupFilter = nil
                    } label: {
                        HStack { Image(systemName: "sparkle.magnifyingglass"); Text(collection.name).lineLimit(1); Spacer() }
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(model.librarySmartCollectionFilter == collection.id ? Color.primary.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain)
                }
            }
            if model.libraryAlbumFilter != nil || model.librarySmartCollectionFilter != nil {
                Button("Clear Collection Filter") {
                    model.libraryAlbumFilter = nil
                    model.librarySmartCollectionFilter = nil
                }.font(.caption).buttonStyle(.plain).padding(.horizontal, 10)
            }
            Divider().padding(.vertical, 4)
            HStack {
                Text("PEOPLE").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if model.isGroupingPeople {
                    ProgressView().controlSize(.small)
                } else {
                    Button { model.rebuildPeopleGroups() } label: { Image(systemName: "person.2.badge.gearshape") }
                        .buttonStyle(.plain)
                        .help("Scan this project locally and group photos that appear to contain the same person. Face data never leaves this Mac.")
                }
            }.padding(.horizontal, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if !model.project.peopleGroups.isEmpty {
                        ForEach(model.project.peopleGroups) { group in
                            Button {
                                model.selectPeopleGroup(group)
                            } label: {
                                HStack {
                                    Image(systemName: "person.crop.circle")
                                    Text(group.name).lineLimit(1)
                                    Spacer()
                                    Text("\(group.imageIDs.count)").foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(model.libraryPeopleGroupFilter == group.id ? Color.primary.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Menu("Merge Into Person…") {
                                    ForEach(model.project.peopleGroups.filter { $0.id != group.id }) { other in
                                        Button(other.name) { model.mergePeopleGroup(group.id, into: other.id) }
                                    }
                                }
                                .disabled(model.project.peopleGroups.count < 2)
                            }
                        }
                    } else if !model.peopleGroupingStatus.isEmpty {
                        Text(model.peopleGroupingStatus)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                    }
                    if model.libraryPeopleGroupFilter != nil {
                        Button("Show All People") { model.clearPeopleFilter() }
                            .font(.caption).buttonStyle(.plain).padding(.horizontal, 10)
                    }
                }
            }
            if !model.project.peopleGroups.isEmpty {
                Button("Clear People Groups") { model.clearPeopleGroups() }
                    .font(.caption).buttonStyle(.plain).padding(.horizontal, 10)
            }

            Divider().padding(.vertical, 4)
            Text("FOLDERS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.libraryFolders, id: \.self) { folder in
                        Button {
                            model.libraryFolderFilter = folder
                        } label: {
                            HStack { Image(systemName: "folder"); Text(URL(fileURLWithPath: folder).lastPathComponent).lineLimit(1); Spacer() }
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(model.libraryFolderFilter == folder ? Color.primary.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain)
                    }
                }
            }
            CloudLibraryPanel(model: model)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)

            Spacer(minLength: 8)
            VStack(spacing: 8) {
                if model.isIngesting {
                    ProgressView(value: model.ingestProgress)
                    Text(model.ingestStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Button("Stop Import") { model.stopManagedIngest() }
                        .buttonStyle(.bordered)
                } else {
                    Button {
                        model.importImages()
                    } label: {
                        Label("Import Photos…", systemImage: "plus")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    Menu {
                        Button("Add Files…") { model.importImages() }
                        Button("Reference Folder…") { model.importFolder() }
                        Divider()
                        Button("Verified Card Ingest…") { model.beginManagedIngest() }
                        if model.hasRecoverableIngest {
                            Button("Resume Ingest") { model.resumeManagedIngest() }
                        }
                        Button("Import Lightroom…") { model.importLightroomCatalogToICloud() }
                        Button("Open iCloud Library…") { model.openICloudLibrary() }
                    } label: {
                        Label("More import options", systemImage: "ellipsis")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(10)
        }
          }
        .background(StudioPalette.panel)
    }

    private var toolbar: some View {
        VStack(spacing: 8) {
          HStack(spacing: 10) {
            TextField("Search filename, camera metadata, notes…", text: $model.librarySearch)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180, maxWidth: .infinity)
            Picker("Sort", selection: $model.project.sortMode) { ForEach(ProjectSortMode.allCases) { Text($0.rawValue).tag($0) } }
                .frame(width: 180)
          }
          HStack(spacing: 10) {
            if !model.librarySelection.isEmpty {
                let exportCount = model.librarySelectedImages.filter(\.selectedForExport).count
                HStack(spacing: 5) {
                    Text("\(model.librarySelection.count) selected · \(exportCount) queued").lineLimit(1)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

                Menu("Batch") {
                    Menu("Rating") {
                        ForEach(0...5, id: \.self) { n in
                            Button(n == 0 ? "Clear rating  (0)" : "\(n) star\(n == 1 ? "" : "s")  (\(n))") {
                                model.batchSetRating(n)
                            }
                        }
                    }
                    Menu("Flag") {
                        Button("Pick") { model.batchSetFlag(.picked) }
                        Button("Reject") { model.batchSetFlag(.rejected) }
                        Button("Unflag") { model.batchSetFlag(.unflagged) }
                    }
                    Menu("Color Label") {
                        Button("None") { model.batchSetColorLabel(nil) }
                        ForEach(PhotoColorLabel.allCases) { label in
                            Button(label.rawValue) { model.batchSetColorLabel(label) }
                        }
                    }
                    Menu("Client Pick") {
                        Button("Mark as Client Pick") { model.batchSetClientPicked(true) }
                        Button("Clear Client Pick") { model.batchSetClientPicked(false) }
                    }

                    Divider()

                    Button("Analyze Highlighted Photos") {
                        model.analyzeForCull(ids: Array(model.librarySelection))
                    }

                    if !model.project.albums.isEmpty {
                        Menu("Add to Album") {
                            ForEach(model.project.albums) { album in
                                Button(album.name) { model.addSelection(toAlbum: album.id) }
                            }
                        }
                    }

                    if model.libraryAlbumFilter != nil {
                        Button("Remove from Album") { model.removeSelectionFromCurrentAlbum() }
                    }
                    Button("Write XMP Sidecars") { model.writeSelectionXMP() }
                    Button("Read XMP Sidecars") { model.readSelectionXMP() }

                    Divider()

                    Menu("Sync Active Look") {
                        Button("Tone + Film · keep each photo WB & crop") {
                            model.syncActiveLookToHighlighted(copyWhiteBalance: false, copyGeometry: false)
                        }
                        Button("Include White Balance · keep each crop") {
                            model.syncActiveLookToHighlighted(copyWhiteBalance: true, copyGeometry: false)
                        }
                        Button("Everything · include WB & crop") {
                            model.syncActiveLookToHighlighted(copyWhiteBalance: true, copyGeometry: true)
                        }
                    }

                    Divider()

                    Button("Queue for Export") { model.batchSetExportSelection(true) }
                    Button("Remove from Export Queue") { model.batchSetExportSelection(false) }

                    Divider()

                    Button("Open in Cull") {
                        model.page = .cull
                        model.workspaceDidChange(.cull)
                    }
                    Button("Open Active Photo in Edit") {
                        model.page = .edit
                        model.workspaceDidChange(.edit)
                    }
                    Button("Go to Proofs") {
                        model.page = .proofs
                        model.workspaceDidChange(.proofs)
                    }

                    Divider()
                    Button("Clear Highlighted Selection") { model.clearLibrarySelection() }
                }
                .help("Batch actions apply to every highlighted photo.")
            }
            Spacer()
            Button {
                showLibraryInspector.toggle()
            } label: {
                Label("Info", systemImage: "sidebar.right")
            }
            .controlSize(.small)
            .help(showLibraryInspector ? "Hide photo details" : "Show photo details")
            if model.isCullAnalyzing {
                ProgressView(value: model.cullAnalysisProgress).frame(width: 110)
                Text("\(Int(model.cullAnalysisProgress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button("Cancel") { model.cancelCullAnalysis() }
            } else {
                Button("Smart Cull", systemImage: "sparkles") { model.analyzeVisibleForCull() }
            }
            HStack(spacing: 5) {
                Slider(
                    value: $thumbnailSizeDraft,
                    in: 120...280,
                    onEditingChanged: { editing in
                        if !editing { model.libraryThumbnailSize = thumbnailSizeDraft }
                    }
                )
                    .frame(width: 110)
                    .help("Changes how large photos appear in the Library grid. Move left to fit more photos on screen; move right to make each thumbnail easier to inspect.")
                Button { model.libraryThumbnailSize = 176 } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 9, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Reset Library thumbnail size.")
            }
        }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private var gallery: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSizeDraft), spacing: 8)], spacing: 8) {
                ForEach(model.visibleImages) { image in
                    LibraryPhotoCard(model: model, image: image)
                }
            }
            .padding(10)
        }
        .background(StudioPalette.recessed)
        .overlay {
            if model.visibleImages.isEmpty {
                VStack(spacing: 12) {
                    ContentUnavailableView("No matching photos", systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text("Your photos are still in the library. Reset filters to see them."))
                    Button("Show All Photos") { model.resetLibraryFilters() }.buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var inspector: some View {
        Group {
            if let image = model.selectedImage {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        LocalThumbnail(url: model.thumbnailURL(for: image)).aspectRatio(3/2, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 7))
                        Text(image.fileName).font(.headline).lineLimit(2)
                        HStack {
                            Button("Cull") { model.page = .cull; model.workspaceDidChange(.cull) }
                            Button("Edit") { model.page = .edit; model.workspaceDidChange(.edit) }.buttonStyle(.borderedProminent)
                        }
                        Divider()
                        metadataRow("Rating", image.rating == 0 ? "Unrated" : "\(image.rating) / 5")
                        metadataRow("Flag", image.flag.label)
                        metadataRow("Capture", image.captureDate?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                        if let metadata = image.metadata {
                            if !metadata.cameraDisplay.isEmpty { metadataRow("Camera", metadata.cameraDisplay) }
                            if let lens = metadata.lensModel { metadataRow("Lens", lens) }
                            if let focal = metadata.focalLengthMM { metadataRow("Focal", String(format: "%.0f mm", focal)) }
                            if let aperture = metadata.aperture { metadataRow("Aperture", String(format: "f/%.1f", aperture)) }
                            if let shutter = metadata.shutterSeconds { metadataRow("Shutter", Self.shutterString(shutter)) }
                            if let iso = metadata.iso { metadataRow("ISO", "ISO \(iso)") }
                            if let width = metadata.pixelWidth, let height = metadata.pixelHeight { metadataRow("Dimensions", "\(width) × \(height)") }
                        }
                        metadataRow("Folder", image.url.deletingLastPathComponent().lastPathComponent)
                        if let cull = image.cullAnalysis {
                            Divider()
                            Text("SMART CULL").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            HStack(alignment: .firstTextBaseline) {
                                Text(String(format: "%.0f", cull.score)).font(.system(size: 30, weight: .semibold, design: .rounded))
                                Text(cull.recommendation.rawValue).font(.headline)
                            }
                            metadataRow("Focus", String(format: "%.0f%%", cull.sharpness * 100))
                            if cull.faceCount > 0 { metadataRow("Face focus", String(format: "%.0f%%", cull.faceSharpness * 100)) }
                            metadataRow("Faces", "\(cull.faceCount)")
                            metadataRow("Highlights", String(format: "%.1f%%", cull.highlightClipPercent))
                            if cull.possibleBlink { Label("Possible blink", systemImage: "eye.slash").foregroundStyle(.orange) }
                            ForEach(cull.reasons, id: \.self) { Text("• \($0)").font(.caption).foregroundStyle(.secondary) }
                        } else {
                            Divider()
                            Button("Analyze Photo", systemImage: "sparkles") { model.analyzeSelectedForCull() }
                        }
                        Divider()
                        HStack {
                            Button("Write XMP") { model.librarySelection = [image.id]; model.writeSelectionXMP() }
                            Button("Read XMP") { model.librarySelection = [image.id]; model.readSelectionXMP() }
                        }
                        if !model.project.albums.isEmpty {
                            Menu("Add to Album") { ForEach(model.project.albums) { album in Button(album.name) { model.librarySelection = [image.id]; model.addSelection(toAlbum: album.id) } } }
                        }
                        if let note = image.note, !note.isEmpty { Divider(); Text(note).font(.caption) }
                    }.padding(12)
                }
            } else {
                ContentUnavailableView("No Selection", systemImage: "photo")
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private func namingSheet(title: String, placeholder: String, text: Binding<String>, onCreate: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder).frame(width: 320)
            HStack {
                Spacer()
                Button("Cancel") { showingNewAlbum = false; showingNewSmartCollection = false }
                Button("Create", action: onCreate).keyboardShortcut(.defaultAction).disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20)
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).multilineTextAlignment(.trailing) }.font(.caption)
    }

    private static func shutterString(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        if seconds >= 1 { return String(format: "%.1f s", seconds) }
        return "1/\(max(1, Int((1.0 / seconds).rounded()))) s"
    }

    private func icon(_ filter: LibraryFilter) -> String {
        switch filter {
        case .all: "square.grid.2x2"
        case .picked: "flag.fill"
        case .clientPicks: "heart.fill"
        case .rejected: "xmark.circle"
        case .unrated: "star"
        case .fiveStar: "star.fill"
        case .needsReview: "sparkles"
        case .exportQueued: "square.and.arrow.up"
        case .missing: "externaldrive.badge.exclamationmark"
        }
    }
}

private struct LibraryPhotoCard: View {
    @ObservedObject var model: AppModel
    let image: ProjectImageRecord

    var body: some View {
        let highlighted = model.librarySelection.contains(image.id)
        let active = model.project.selectedImageID == image.id
        return VStack(alignment: .leading, spacing: 5) {
            ZStack {
                LocalThumbnail(url: model.thumbnailURL(for: image))
                    .aspectRatio(3/2, contentMode: .fit)

                VStack {
                    HStack(alignment: .top) {
                        if image.selectedForExport {
                            Label("EXPORT", systemImage: "square.and.arrow.up.fill")
                                .font(.system(size: 8, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(.regularMaterial, in: Capsule())
                                .help("Queued for Export. This is separate from the blue highlighted selection.")
                        }
                        Spacer()
                        if let cull = image.cullAnalysis {
                            Text(String(format: "%.0f", cull.score))
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .padding(.horizontal, 5).padding(.vertical, 3)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                    Spacer()
                    HStack {
                        if image.clientPicked {
                            Label("CLIENT", systemImage: "heart.fill")
                                .font(.system(size: 8, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(.regularMaterial, in: Capsule())
                                .help("Client Pick returned from Proofs.")
                        }
                        Spacer()
                    }
                }
                .padding(5)
            }

            HStack(spacing: 5) {
                Text(image.fileName).lineLimit(1).font(.caption)
                Spacer()
                if image.flag == .picked { Image(systemName: "flag.fill").help("Picked") }
                if image.flag == .rejected { Image(systemName: "xmark.circle.fill").help("Rejected") }
            }

            HStack(spacing: 3) {
                Text(image.rating == 0 ? "" : String(repeating: "★", count: image.rating)).font(.caption2)
                if let label = image.colorLabel { Circle().fill(color(label)).frame(width: 7, height: 7) }
                Spacer()
                if active {
                    Image(systemName: "circle.inset.filled")
                        .font(.system(size: 7))
                        .help("Active photo shown in the inspector")
                }
                if image.cullAnalysis?.possibleBlink == true {
                    Image(systemName: "eye.slash").font(.caption2).help("Possible blink")
                }
            }
            .foregroundStyle(.secondary)
            .frame(height: 12)
        }
        .padding(6)
        .background(highlighted ? Color.accentColor.opacity(0.11) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    highlighted ? Color.accentColor.opacity(0.95) : (active ? Color.primary.opacity(0.55) : Color.secondary.opacity(0.12)),
                    lineWidth: highlighted ? 2 : (active ? 1 : 0.5)
                )
        }
        .contentShape(Rectangle())
        .onTapGesture {
            let flags = NSEvent.modifierFlags
            model.selectLibraryImage(image.id, additive: flags.contains(.command), range: flags.contains(.shift))
        }
        .onTapGesture(count: 2) { model.selectLibraryImage(image.id); model.page = .edit; model.workspaceDidChange(.edit) }
        .contextMenu {
            Button("Open in Edit") {
                prepareContextSelection()
                model.page = .edit
                model.workspaceDidChange(.edit)
            }
            Button("Open in Cull") {
                prepareContextSelection()
                model.page = .cull
                model.workspaceDidChange(.cull)
            }

            Divider()

            Menu("Rating") {
                ForEach(0...5, id: \.self) { rating in
                    Button(rating == 0 ? "Clear Rating" : "\(rating) Star\(rating == 1 ? "" : "s")") {
                        prepareContextSelection()
                        model.batchSetRating(rating)
                    }
                }
            }

            Menu("Flag") {
                Button("Pick") { prepareContextSelection(); model.batchSetFlag(.picked) }
                Button("Reject") { prepareContextSelection(); model.batchSetFlag(.rejected) }
                Button("Unflag") { prepareContextSelection(); model.batchSetFlag(.unflagged) }
            }

            Menu("Color Label") {
                Button("None") { prepareContextSelection(); model.batchSetColorLabel(nil) }
                ForEach(PhotoColorLabel.allCases) { label in
                    Button(label.rawValue) {
                        prepareContextSelection()
                        model.batchSetColorLabel(label)
                    }
                }
            }

            Menu("Client Pick") {
                Button("Mark as Client Pick") {
                    prepareContextSelection()
                    model.batchSetClientPicked(true)
                }
                Button("Clear Client Pick") {
                    prepareContextSelection()
                    model.batchSetClientPicked(false)
                }
            }

            Divider()

            Button(image.selectedForExport ? "Remove from Export Queue" : "Queue for Export") {
                prepareContextSelection()
                model.batchSetExportSelection(!image.selectedForExport)
            }

            Button("Analyze Highlighted Photos") {
                prepareContextSelection()
                model.analyzeForCull(ids: Array(model.librarySelection))
            }

            if !model.project.albums.isEmpty {
                Menu("Add to Album") {
                    ForEach(model.project.albums) { album in
                        Button(album.name) {
                            prepareContextSelection()
                            model.addSelection(toAlbum: album.id)
                        }
                    }
                }
            }

            Divider()

            if model.libraryAlbumFilter != nil {
                Button("Remove from Album") {
                    prepareContextSelection()
                    model.removeSelectionFromCurrentAlbum()
                }
            }
            Button("Write XMP Sidecars") {
                prepareContextSelection()
                model.writeSelectionXMP()
            }
            Button("Read XMP Sidecars") {
                prepareContextSelection()
                model.readSelectionXMP()
            }

            Divider()
            Button("Go to Proofs") {
                prepareContextSelection()
                model.page = .proofs
                model.workspaceDidChange(.proofs)
            }
            Button("Go to Export") {
                prepareContextSelection()
                model.page = .export
                model.workspaceDidChange(.export)
            }
        }
    }

    private func prepareContextSelection() {
        if !model.librarySelection.contains(image.id) {
            model.selectLibraryImage(image.id)
        }
    }

    private func color(_ label: PhotoColorLabel) -> Color {
        switch label { case .red: .red; case .yellow: .yellow; case .green: .green; case .blue: .blue; case .purple: .purple }
    }
}
