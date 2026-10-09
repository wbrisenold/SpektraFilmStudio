import SwiftUI
import AppKit

struct EditWorkspaceView: View {
    @ObservedObject var model: AppModel
    @AppStorage("editFilmstripHeight") private var filmstripHeight = 132.0
    @State private var filmstripResizeStart: Double?
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
                .padding(.top, 45)
                .padding(.leading, model.isPresetSidebarVisible
                    ? StudioLayout.presetSidebarWidth + 2 * StudioLayout.paneInset
                    : StudioLayout.paneInset)
                .padding(.trailing, showEditorInspector
                    ? StudioLayout.editorInspectorWidth + 2 * StudioLayout.paneInset
                    : StudioLayout.paneInset)
                .padding(.bottom, editorBottomInset)

            VStack(spacing: 0) {
                editorToolbar
                Spacer(minLength: 0)
                if showFilmstrip && !model.project.images.isEmpty {
                    filmstrip
                        .studioGlassPane()
                        .padding(.horizontal, StudioLayout.paneInset)
                        .padding(.bottom, StudioLayout.paneInset)
                }
            }

            HStack(alignment: .top, spacing: 0) {
                if model.isPresetSidebarVisible {
                    PresetBrowserView(model: model)
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
            .padding(.top, 45 + StudioLayout.paneInset)
            // Must mirror the canvas reservation exactly, or the side panels run
            // under the docked scope strip.
            .padding(.bottom, editorBottomInset)
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
    }

    private var editorToolbar: some View {
        HStack(spacing: 8) {
            if let image = model.selectedImage {
                Text(image.fileName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Editor").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                model.isPresetSidebarVisible.toggle()
            } label: {
                Label("Presets", systemImage: "square.stack")
            }
            .help("Show or hide presets")
            .foregroundStyle(model.isPresetSidebarVisible ? .primary : .secondary)
            Button {
                showFilmstrip.toggle()
            } label: {
                Label("Filmstrip", systemImage: "rectangle.bottomthird.inset.filled")
            }
            .help("Show or hide filmstrip")
            Button {
                showEditorInspector.toggle()
            } label: {
                Label("Adjustments", systemImage: "sidebar.right")
            }
            .help("Show or hide adjustments")
            // Look edits (undo/redo/copy/paste/reset) and the scope toggle live with
            // the other workspace controls rather than eating inspector height.
            Button {
                showScopes.toggle()
            } label: {
                Label("Scopes", systemImage: "waveform.path")
            }
            .help(showScopes ? "Hide scopes" : "Show scopes")
            Menu {
                Button("Undo") { model.undo() }
                Button("Redo") { model.redo() }
                Divider()
                Button("Copy Look") { model.copyLook() }
                Button("Paste Look") { model.pasteLook() }
                Section("Copy / Paste Categories") {
                    ForEach(LookCopyCategory.allCases) { category in
                        Toggle(category.rawValue, isOn: Binding(
                            get: { model.lookCopyCategoryEnabled(category) },
                            set: { model.setLookCopyCategory(category, enabled: $0) }
                        ))
                    }
                }
                Divider()
                Button(role: .destructive) { model.resetLook() } label: {
                    Label("Reset All", systemImage: "arrow.counterclockwise")
                }
            } label: {
                Label("Look", systemImage: "slider.horizontal.3")
            }
            .help("Undo, redo, copy/paste categories and reset the look")
            // Scene Intelligence was reachable only from ⌘K and the macOS menu, so
            // it read as a hidden feature. One explicit control in the workspace it
            // reasons about is discoverable and costs a single button.
            Button {
                NotificationCenter.default.post(name: StudioOmniEvents.openSceneAssistant, object: nil)
            } label: {
                Label("Scene Intelligence", systemImage: "sparkles.rectangle.stack")
            }
            .help("Group photos from the same session and compare film/print starting points")
            if let image = model.selectedImage {
                Button("Export Photo…", systemImage: "square.and.arrow.up") {
                    quickExportRequest = QuickExportRequest(id: image.id)
                }.disabled(model.isExporting)
            }
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 37)
        .background(StudioPalette.panel.opacity(0.74))
    }

    private var clampedFilmstripHeight: CGFloat {
        CGFloat(min(320.0, max(128.0, filmstripHeight)))
    }

    /// Height reserved at the bottom of the canvas for the docked strips, so the
    /// preview is never drawn underneath them.
    private var editorBottomInset: CGFloat {
        var inset = StudioLayout.paneInset
        
        if showFilmstrip && !model.project.images.isEmpty {
            inset += clampedFilmstripHeight + StudioLayout.paneInset
        }
        return inset
    }

    private var filmstripThumbnailHeight: CGFloat {
        max(52, clampedFilmstripHeight - 76)
    }

    private var filmstripThumbnailWidth: CGFloat {
        min(224, max(96, filmstripThumbnailHeight * 1.45))
    }

    private var filmstripResizeHandle: some View {
        ZStack {
            StudioPalette.panel
            Capsule()
                .fill(Color.secondary.opacity(0.42))
                .frame(width: 38, height: 3)
        }
        .frame(height: 8)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if filmstripResizeStart == nil {
                        filmstripResizeStart = filmstripHeight
                    }
                    let start = filmstripResizeStart ?? filmstripHeight
                    filmstripHeight = min(320, max(128, start - Double(value.translation.height)))
                }
                .onEnded { _ in filmstripResizeStart = nil }
        )
        .help("Drag vertically to resize the filmstrip.")
    }

    private var filmstrip: some View {
        VStack(spacing: 0) {
            filmstripResizeHandle

            HStack(spacing: 8) {
                Text("Filmstrip")
                    .font(.caption.weight(.semibold))
                Text("\(model.visibleImages.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                if model.librarySelection.count > 1 {
                    Text("\(model.librarySelection.count) selected")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.16), in: Capsule())
                }

                Spacer()

                // Icon-only: the strip's own header already says "Filmstrip" immediately to
                // the left, so a second labelled control was a duplicate.
                Menu {
                    Button("Hide Filmstrip") { showFilmstrip = false }
                    Divider()
                    Button("Small") { filmstripHeight = 128 }
                    Button("Medium") { filmstripHeight = 156 }
                    Button("Large") { filmstripHeight = 232 }
                } label: {
                    Image(systemName: "rectangle.bottomthird.inset.filled")
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .help("Filmstrip size and visibility")

                // Filename only: Export already lives in the editor toolbar directly
                // above this strip, so the second copy here was redundant.
                if let image = model.selectedImage {
                    Text(image.fileName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 200, alignment: .trailing)
                        .help(image.fileName)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(StudioPalette.panel)

            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
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
                .padding(.vertical, 6)
            }
            .background(StudioPalette.recessed)
        }
        .frame(height: clampedFilmstripHeight)
    }
}

private struct EditorInspectorView: View {
    @ObservedObject var model: AppModel
    @Binding var mode: StudioInspectorMode
    @AppStorage(EditorPanelVisibilityStore.key) private var hiddenEditorPanels = ""
    @AppStorage("SpektraFilmStudio.designA.showScopes") private var showScopes = false

    // The inspector column is for controls only. Scopes live under the canvas so
    // they never steal height from the sliders (Redlamp keeps them out of the rail).
    var body: some View {
        StudioPanel {
            VStack(spacing: 0) {
                // Only the workflow switch lives here. Look actions and the scope
                // toggle moved to the editor toolbar so this header costs a single
                // row and the adjustments below get the rest of the rail.
                Picker("Edit tools", selection: $mode) {
                    ForEach(StudioInspectorMode.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .padding(.horizontal, 8)
                .frame(height: RedlampMetrics.panelHeaderHeight)

                // Redlamp keys the scrolling panels off `activeTool`
                // (ReferencePanels.swift: InspectorView), so a tool shows only its
                // Redlamp's InspectorView order: HistogramView + ToolStrip, divider,
                // then the scrolling panels. The scope readout owns the well; the
                // toggles sit in its header row, so nothing extra is stacked above.
                if showScopes {
                    EditorScopePanelView(model: model)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                    Rectangle().fill(StudioPalette.divider).frame(height: 1)
                }

                Rectangle().fill(StudioPalette.divider).frame(height: 1)

                ControlsView(model: model, mode: mode)
                    .frame(maxHeight: .infinity)
            }
        }
    }

}
