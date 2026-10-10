import SwiftUI
import AppKit

// SFS-EDIT-LEFT-PHOTOS-LARGE-SCOPES-20261009

struct EditWorkspaceView: View {
    @ObservedObject var model: AppModel
    // Photos now live alongside Presets in the left editor sidebar.
    @AppStorage("SpektraFilmStudio.ui.editLeftTab") private var editLeftTab = "photos"
    // A real, resizable scope dock, independent of the adjustment rail.
    @AppStorage("SpektraFilmStudio.ui.scopesDockHeight") private var scopesDockHeight = 356.0
    @State private var scopesResizeOrigin: Double?
    @State private var inspectorMode: StudioInspectorMode = .adjust
    @AppStorage("SpektraFilmStudio.designA.showEditorInspector") private var showEditorInspector = true
    @AppStorage("SpektraFilmStudio.designA.showFilmstrip") private var showFilmstrip = true
    @AppStorage("SpektraFilmStudio.designA.showScopes") private var showScopes = false
    @State private var quickExportRequest: QuickExportRequest?

    var body: some View {
        ZStack(alignment: .top) {
            StudioPalette.canvas

            // Redlamp's stage-inset principle: the underlying editor occupies the
            // whole workspace; panels overlay the stage rather than HSplitView
            // resizing the renderer when they are shown or hidden.
            PreviewView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, StudioLayout.paneInset)
                .padding(.leading, model.isPresetSidebarVisible
                    ? StudioLayout.presetSidebarWidth + 2 * StudioLayout.paneInset
                    : StudioLayout.paneInset)
                .padding(.trailing, showEditorInspector
                    ? StudioLayout.editorInspectorWidth + 2 * StudioLayout.paneInset
                    : StudioLayout.paneInset)
                .padding(.bottom, editorBottomInset)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if showScopes {
                    scopeDock
                        // The scope dock uses only the center stage, never the left browser
                        // or the right RAW/FILM/MASK controls.
                        .padding(.leading, model.isPresetSidebarVisible
                            ? StudioLayout.presetSidebarWidth + 2 * StudioLayout.paneInset
                            : StudioLayout.paneInset)
                        .padding(.trailing, showEditorInspector
                            ? StudioLayout.editorInspectorWidth + 2 * StudioLayout.paneInset
                            : StudioLayout.paneInset)
                        .padding(.bottom, StudioLayout.paneInset)
                }
            }

            HStack(alignment: .top, spacing: 0) {
                if model.isPresetSidebarVisible {
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

    /// Reserve the scope dock below the preview. The side panels stay full-height.
    private var editorBottomInset: CGFloat {
        showScopes ? CGFloat(scopesDockHeight) + 2 * StudioLayout.paneInset : StudioLayout.paneInset
    }

    private var filmstripThumbnailHeight: CGFloat { 106 }
    private var filmstripThumbnailWidth: CGFloat {
        (StudioLayout.presetSidebarWidth - 42) / 2
    }

    // The full-width studio monitor is independently scalable (drag its grab bar).
    // Scope calculations still run off the latest finalized display signal.
    private var scopeDock: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Capsule()
                    .fill(StudioPalette.secondaryLabel)
                    .frame(width: 38, height: 4)
                    .frame(width: 56, height: 30)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { drag in
                                if scopesResizeOrigin == nil { scopesResizeOrigin = scopesDockHeight }
                                let proposed = (scopesResizeOrigin ?? scopesDockHeight) - Double(drag.translation.height)
                                scopesDockHeight = min(480, max(280, proposed))
                            }
                            .onEnded { _ in scopesResizeOrigin = nil }
                    )
                    .help("Drag vertically to resize scopes")
                    .accessibilityLabel("Scope dock resize handle")
                Text("SCOPES")
                    .font(StudioType.section)
                    .tracking(StudioType.sectionTracking)
                    .foregroundStyle(.secondary)
                Menu {
                    ForEach(ScopeMode.allCases) { mode in
                        Button {
                            model.setEditorScopeMode(mode)
                        } label: {
                            if model.project.preferences.scopeMode == mode {
                                Label(mode.rawValue, systemImage: "checkmark")
                            } else {
                                Text(mode.rawValue)
                            }
                        }
                    }
                } label: {
                    Label(model.project.preferences.scopeMode.rawValue, systemImage: "waveform.path.ecg")
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                Spacer(minLength: 4)
                if model.isScopeAnalyzing { ProgressView().controlSize(.mini) }
                Toggle(isOn: Binding(
                    get: { model.project.preferences.clippingEnabled },
                    set: { model.setClippingEnabled($0) }
                )) { Label("Clipping", systemImage: "arrowtriangle.up.fill") }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .controlSize(.mini)
                .help("Show clipping warnings over the preview")
                Toggle(isOn: Binding(
                    get: { model.project.preferences.skinCheckEnabled },
                    set: { model.setSkinCheckEnabled($0) }
                )) { Label("Skin", systemImage: "hand.raised.fill") }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .controlSize(.mini)
                .help("Show skin diagnostic over the preview")
                Button { showScopes = false } label: { Image(systemName: "xmark") }
                    .help("Close scopes")
            }
            .controlSize(.small)
            .padding(.trailing, 12)
            .frame(height: 38)

            Rectangle().fill(StudioPalette.divider).frame(height: 1)
            ScrollView(.vertical) {
                EditorScopePanelView(
                    model: model,
                    wellHeight: max(210, CGFloat(scopesDockHeight) - 145)
                )
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 10)
            }
            .scrollIndicators(.automatic)
        }
        .frame(height: CGFloat(scopesDockHeight))
        .studioGlassPane()
    }

    private var filmstrip: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Photos")
                    .font(.caption)
                Text("\(model.visibleImages.count)")
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

            ScrollView(.vertical) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 8) {
                    ForEach(model.visibleImages) { image in
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
                                range: flags.contains(.shift)
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
