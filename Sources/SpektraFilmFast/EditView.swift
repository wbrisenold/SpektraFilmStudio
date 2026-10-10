import SwiftUI
import AppKit

// SPEKTRA_RAW_METAL_GPU_FILTERS_20261010

// SFS-EDIT-LEFT-PHOTOS-LARGE-SCOPES-20261009

struct EditWorkspaceView: View {
    @ObservedObject var model: AppModel
    // Photos now live alongside Presets in the left editor sidebar.
    @AppStorage("SpektraFilmStudio.ui.editLeftTab") private var editLeftTab = "photos"
    // Dedicated independent scope rail: always to the RIGHT of the viewer,
    // before RAW/FILM/MASK controls. Photos rail yields first on small windows.
    @AppStorage("SpektraFilmStudio.ui.scopesRailWidth") private var scopesRailWidth = 376.0
    @State private var workspaceWidth: CGFloat = 1280
    @State private var inspectorMode: StudioInspectorMode = .adjust
    @AppStorage("SpektraFilmStudio.designA.showEditorInspector") private var showEditorInspector = true
    @AppStorage("SpektraFilmStudio.designA.showFilmstrip") private var showFilmstrip = true
    @AppStorage("SpektraFilmStudio.designA.showScopes") private var showScopes = false
    @State private var quickExportRequest: QuickExportRequest?
    // These are EDIT VIEW preferences only. They never mutate Library/Cull scopes.
    @AppStorage("SpektraFilmStudio.ui.editPhotosStatus") private var editPhotosStatus = "all"
    @AppStorage("SpektraFilmStudio.ui.editPhotosMinRating") private var editPhotosMinRating = 0
    @AppStorage("SpektraFilmStudio.ui.editPhotosSort") private var editPhotosSort = "library"
    @State private var editPhotosSearch = ""

    var body: some View {
        ZStack(alignment: .top) {
            StudioPalette.canvas

            // Redlamp's stage-inset principle: the underlying editor occupies the
            // whole workspace; panels overlay the stage rather than HSplitView
            // resizing the renderer when they are shown or hidden.
            PreviewView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, StudioLayout.paneInset)
                .padding(.leading, sidebarActuallyVisible
                    ? StudioLayout.presetSidebarWidth + 2 * StudioLayout.paneInset
                    : StudioLayout.paneInset)
                .padding(.trailing, (showEditorInspector
                    ? StudioLayout.editorInspectorWidth + 2 * StudioLayout.paneInset
                    : StudioLayout.paneInset) + (showScopes ? CGFloat(scopesRailWidth) + StudioLayout.paneInset : 0))
                .padding(.bottom, StudioLayout.paneInset)


            HStack(alignment: .top, spacing: 0) {
                if sidebarActuallyVisible {
                    VStack(spacing: 0) {
                        Picker("Left browser", selection: $editLeftTab) {
                            Text("Presets").tag("presets")
                            if showFilmstrip { Text("Photos").tag("photos") }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityLabel("Editor left browser")
                        .padding(10)

                        Rectangle().fill(StudioPalette.divider).frame(height: 1)
                        if editLeftTab == "photos" && showFilmstrip {
                            filmstrip
                        } else {
                            PresetBrowserView(model: model)
                        }
                    }
                    .frame(width: StudioLayout.presetSidebarWidth)
                    .frame(maxHeight: .infinity)
                    .studioGlassPane()
                }
                Spacer(minLength: 0)
                if showScopes {
                    scopeRail
                        .frame(width: CGFloat(scopesRailWidth))
                        .frame(maxHeight: .infinity)
                        .studioGlassPane()
                        .padding(.trailing, StudioLayout.paneInset)
                }
                if showEditorInspector {
                    EditorInspectorView(model: model, mode: $inspectorMode)
                        .frame(width: StudioLayout.editorInspectorWidth)
                        .frame(maxHeight: .infinity)
                        .studioGlassPane()
                }
            }
            .padding(.horizontal, StudioLayout.paneInset)
            .padding(.top, StudioLayout.paneInset)
            // Sidebars keep their full height. Only the PHOTO PREVIEW is reserved
            // above the scopes; the adjustment rail must never shrink for scopes.
            .padding(.bottom, StudioLayout.paneInset)
        }
        .background(StudioPalette.canvas)
        // Prefer keeping the viewer usable on narrower Intel displays: the
        // Photos/Presets sidebar auto-collapses *visually* while Scopes is open.
        // This does not overwrite the user's persisted sidebar preference.
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { workspaceWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, width in workspaceWidth = width }
        })
        .sheet(item: $quickExportRequest) { request in
            QuickExportSheet(model: model, imageID: request.id)
        }
        .onReceive(NotificationCenter.default.publisher(for: StudioOmniEvents.focusAdjustment)) { note in
            guard let name = note.object as? String,
                  let item = BridgeCatalog.shared.parameters.first(where: { $0.name == name }) else { return }
            inspectorMode = ["raw", "tone", "geometry", "lens"].contains(item.group) ? .adjust : .film
            showEditorInspector = true
        }
        .onChange(of: model.activeLocalGradeID) { _, id in
            if id != nil { inspectorMode = .masks }
        }
        .onChange(of: showFilmstrip) { _, visible in
            if !visible && editLeftTab == "photos" { editLeftTab = "presets" }
        }
        .onChange(of: showScopes) { _, enabled in
            if enabled { model.requestEditorScopeUpdate() }
        }
    }

    // Edit actions now live in the macOS Workspace / Edit Look / File menus.
    // There is no duplicate toolbar between the global page picker and viewer.

    private var sidebarActuallyVisible: Bool {
        model.isPresetSidebarVisible && (!showScopes || workspaceWidth >= 1510)
    }

    private var filmstripThumbnailHeight: CGFloat { 106 }
    private var filmstripThumbnailWidth: CGFloat {
        (StudioLayout.presetSidebarWidth - 42) / 2
    }

    // The monitor has its own space and scroll position, independent of sliders.
    // All images are measured from the existing latest-frame scope engine rather
    // than recalculated from SwiftUI overlays.
    private var scopeRail: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("SCOPES")
                    .font(StudioType.section)
                    .tracking(StudioType.sectionTracking)
                Spacer(minLength: 2)
                Menu {
                    ForEach(ScopeMode.allCases) { mode in
                        Button {
                            model.setEditorScopeMode(mode)
                        } label: {
                            if model.project.preferences.scopeMode == mode {
                                Label(mode.rawValue, systemImage: "checkmark")
                            } else { Text(mode.rawValue) }
                        }
                    }
                } label: {
                    Text(model.project.preferences.scopeMode.rawValue)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                Button { showScopes = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Hide scope monitor")
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            Rectangle().fill(StudioPalette.divider).frame(height: 1)
            ScrollView(.vertical) {
                VStack(spacing: 16) {
                    EditorScopePanelView(
                        model: model,
                        wellHeight: scopeWellHeight
                    )
                    Divider()
                    HStack(spacing: 8) {
                        Toggle(isOn: Binding(
                            get: { model.project.preferences.clippingEnabled },
                            set: { model.setClippingEnabled($0) }
                        )) { Label("Clipping", systemImage: "arrowtriangle.up.fill") }
                        Toggle(isOn: Binding(
                            get: { model.project.preferences.skinCheckEnabled },
                            set: { model.setSkinCheckEnabled($0) }
                        )) { Label("Skin", systemImage: "hand.raised.fill") }
                    }
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Scope panel width")
                            Spacer()
                            Text("\(Int(scopesRailWidth)) pt")
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: $scopesRailWidth, in: 300...500, step: 8)
                    }
                    .font(.caption2)
                    .padding(.horizontal, 8)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 14)
            }
        }
    }

    private var scopeWellHeight: CGFloat {
        switch model.project.preferences.scopeMode {
        case .vectorscope, .skinVectorscope, .chromaticity:
            return CGFloat(scopesRailWidth) - 35
        default:
            return max(200, min(310, CGFloat(scopesRailWidth) * 0.68))
        }
    }

    private var filteredEditPhotos: [ProjectImageRecord] {
        let query = editPhotosSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = model.visibleImages.filter { photo in
            guard photo.rating >= editPhotosMinRating else { return false }
            if !query.isEmpty && !photo.fileName.localizedStandardContains(query) { return false }
            switch editPhotosStatus {
            case "picks": return photo.flag == .picked
            case "rejected": return photo.flag == .rejected
            case "unflagged": return photo.flag == .unflagged
            case "unrated": return photo.rating == 0
            case "client": return photo.clientPicked
            case "export": return photo.selectedForExport
            case "review": return photo.cullAnalysis?.recommendation == .review
            case "best": return photo.cullAnalysis?.recommendation == .keep
            default: return true
            }
        }
        switch editPhotosSort {
        case "name": return matching.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        case "rating": return matching.sorted { $0.rating == $1.rating ? $0.importedAt < $1.importedAt : $0.rating > $1.rating }
        case "score": return matching.sorted { ($0.cullAnalysis?.score ?? -1) > ($1.cullAnalysis?.score ?? -1) }
        case "newest": return matching.sorted { $0.importedAt > $1.importedAt }
        default: return matching
        }
    }

    private var filmstrip: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Photos")
                    .font(.caption)
                Text("\(filteredEditPhotos.count) / \(model.visibleImages.count)")
                    .foregroundStyle(.secondary)

                if model.librarySelection.count > 1 {
                    Text("\(model.librarySelection.count) selected")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.16), in: Capsule())
                }

                Spacer()

                Button { model.isPresetSidebarVisible = false } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.borderless)
                .help("Close left sidebar")

            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(StudioPalette.panel)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search filenames", text: $editPhotosSearch)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .accessibilityLabel("Find photos in Edit sidebar")
                if !editPhotosSearch.isEmpty {
                    Button { editPhotosSearch = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
                Menu {
                    Picker("Flag / status", selection: $editPhotosStatus) {
                        Text("All Photos").tag("all")
                        Text("Picked").tag("picks")
                        Text("Rejected").tag("rejected")
                        Text("Unflagged").tag("unflagged")
                        Text("Unrated").tag("unrated")
                        Text("Client Picks").tag("client")
                        Text("Export Queue").tag("export")
                        Text("AI Review").tag("review")
                        Text("AI Keep").tag("best")
                    }
                    Picker("Minimum rating", selection: $editPhotosMinRating) {
                        ForEach(0..<6, id: \.self) { stars in
                            Text(stars == 0 ? "Any Rating" : "\(stars)★ and up").tag(stars)
                        }
                    }
                    Picker("Sort", selection: $editPhotosSort) {
                        Text("Library Order").tag("library")
                        Text("Filename").tag("name")
                        Text("Highest Rated").tag("rating")
                        Text("Best AI Score").tag("score")
                        Text("Newest Imported").tag("newest")
                    }
                    Divider()
                    Button("Clear Photos Filters") {
                        editPhotosStatus = "all"
                        editPhotosMinRating = 0
                        editPhotosSort = "library"
                        editPhotosSearch = ""
                    }
                } label: {
                    Image(systemName: (editPhotosStatus == "all" && editPhotosMinRating == 0) ?
                        "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .menuStyle(.borderlessButton)
                .help("Filter by picks, rejection, rating, review, and sort")
                .accessibilityLabel("Photos filter options")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if filteredEditPhotos.isEmpty {
                ContentUnavailableView("No matching photos", systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Try clearing the Edit photo filters."))
                    .frame(maxHeight: .infinity)
            } else {
            ScrollView(.vertical) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 8) {
                    ForEach(filteredEditPhotos) { image in
                        let highlighted = model.librarySelection.contains(image.id)
                        let active = model.project.selectedImageID == image.id

                        VStack(spacing: 4) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(Color.black.opacity(0.28))

                                LocalThumbnail(url: model.thumbnailURL(for: image), contentMode: .fit)
                                    .padding(4)
                                    .frame(width: filmstripThumbnailWidth, height: filmstripThumbnailHeight)

                                VStack {
                                    HStack {
                                        if image.flag == .picked {
                                            Image(systemName: "flag.fill")
                                                .foregroundStyle(.green)
                                        } else if image.flag == .rejected {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(.red)
                                        }

                                        if image.rating > 0 {
                                            Text("\(image.rating)★")
                                                .font(.caption2.monospacedDigit().weight(.semibold))
                                                .padding(.horizontal, 5)
                                                .frame(height: 18)
                                                .background(.regularMaterial, in: Capsule())
                                        }

                                        Spacer()

                                        if highlighted {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 15, weight: .semibold))
                                                .symbolRenderingMode(.hierarchical)
                                        }
                                    }
                                    Spacer()
                                    if active {
                                        HStack {
                                            Circle()
                                                .fill(Color.accentColor)
                                                .frame(width: 7, height: 7)
                                            Text("ACTIVE")
                                                .font(.system(size: 8, weight: .bold))
                                            Spacer()
                                        }
                                        .foregroundStyle(.primary)
                                    }
                                }
                                .padding(6)
                            }
                            .frame(width: filmstripThumbnailWidth, height: filmstripThumbnailHeight)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay {
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(
                                        active ? Color.accentColor :
                                            (highlighted ? Color.accentColor.opacity(0.58) : Color.white.opacity(0.10)),
                                        lineWidth: active ? 2.5 : (highlighted ? 1.5 : 1)
                                    )
                            }

                            Text(image.fileName)
                                .font(.caption2)
                                .foregroundStyle(active ? .primary : .secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: filmstripThumbnailWidth)
                        }
                        .padding(4)
                        .studioSelection(highlighted)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            let flags = NSEvent.modifierFlags
                            model.selectLibraryImage(
                                image.id,
                                additive: flags.contains(.command),
                                range: flags.contains(.shift),
                                orderedIDs: filteredEditPhotos.map(\.id)
                            )
                        }
                        .contextMenu {
                            Button("Select Only") { model.selectLibraryImage(image.id) }
                            Button("Export This Photo…") {
                                quickExportRequest = QuickExportRequest(id: image.id)
                            }
                            .disabled(model.isExporting)
                            Divider()
                            Button("Copy Selected Edits") { model.copyLook() }
                            Button("Paste to Highlighted") { model.pasteLook() }
                            if model.librarySelection.count > 1 {
                                Button("Clear Multi-Selection") { model.clearLibrarySelection() }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .background(StudioPalette.recessed)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

private struct EditorInspectorView: View {
    @ObservedObject var model: AppModel
    @Binding var mode: StudioInspectorMode
    @AppStorage(EditorPanelVisibilityStore.key) private var hiddenEditorPanels = ""

    // The inspector column is for controls only. Scopes live under the canvas so
    // they never steal height from the sliders (Redlamp keeps them out of the rail).
    var body: some View {
        StudioPanel {
            VStack(spacing: 0) {
                // Only the workflow switch lives here. Look actions and the scope
                // toggle moved to the editor toolbar so this header costs a single
                // row and the adjustments below get the rest of the rail.
                // Redlamp's ToolStrip (HistogramView.swift): a row of tool *icons*
                // on the well surface, not a full-width segmented control with
                // labels. Clicking the active tool returns to Edit, as Redlamp does.
                HStack(spacing: 2) {
                    ForEach(StudioInspectorMode.allCases) { item in
                        Button {
                            mode = (mode == item && item != .adjust) ? .adjust : item
                        } label: {
                            Image(systemName: item.symbol)
                                .font(.system(size: 13))
                                .frame(maxWidth: .infinity, minHeight: 26)
                                .foregroundStyle(mode == item ? Color.primary : Color.secondary)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(mode == item ? StudioPalette.selected : Color.clear)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(item.rawValue.capitalized)
                        .accessibilityLabel(item.rawValue.capitalized)
                    }
                }
                .padding(3)
                .background(StudioPalette.recessed, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 8)
                .padding(.bottom, 10)

                // Redlamp keys the scrolling panels off `activeTool`
                // (ReferencePanels.swift: InspectorView), so a tool shows only its
                // Redlamp's InspectorView order: ToolStrip, divider,
                // then the scrolling panels. The scope readout owns the well; the
                // scope toggles live in the large monitor dock, outside this inspector.
                Rectangle().fill(StudioPalette.divider).frame(height: 1)

                ControlsView(model: model, mode: mode)
                    .frame(maxHeight: .infinity)

                Rectangle().fill(StudioPalette.divider).frame(height: 1)

                inspectorFooter
            }
        }
    }

    /// Redlamp's InspectorFooter: Previous on the left, Reset on the right, below
    /// the scrolling panels rather than competing for toolbar space.
    private var inspectorFooter: some View {
        HStack {
            Button("Previous") { model.applyLookToPreviousImage() }
                .disabled(model.previousLookTargetID == nil)
                .help("Copy this photo's settings to the previously viewed photo")
            Spacer()
            Button(role: .destructive) { model.resetLook() } label: {
                Label("Reset All", systemImage: "arrow.counterclockwise")
            }
            .disabled(model.selectedImage == nil)
            .help("Reset all settings")
        }
        .controlSize(.small)
        .padding(10)
    }

}
