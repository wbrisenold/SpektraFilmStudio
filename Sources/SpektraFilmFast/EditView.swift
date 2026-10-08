import SwiftUI
import AppKit

struct EditWorkspaceView: View {
    @ObservedObject var model: AppModel
    @AppStorage("editFilmstripHeight") private var filmstripHeight = 156.0
    @State private var filmstripResizeStart: Double?
    @State private var inspectorMode: StudioInspectorMode = .adjust
    @AppStorage("SpektraFilmStudio.designA.showEditorInspector") private var showEditorInspector = true
    @AppStorage("SpektraFilmStudio.designA.showFilmstrip") private var showFilmstrip = true
    @AppStorage("SpektraFilmStudio.designA.showScopes") private var showScopes = false
    @State private var quickExportRequest: QuickExportRequest?

    var body: some View {
        HStack(spacing: 0) {
            if model.isPresetSidebarVisible {
                PresetBrowserView(model: model)
                    .frame(width: StudioLayout.presetSidebarWidth)

                Divider().opacity(0.65)
            }

            VStack(spacing: 0) {
                editorToolbar
                PreviewView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showFilmstrip && !model.project.images.isEmpty {
                    Divider().opacity(0.45)
                    filmstrip
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showEditorInspector {
                Divider().opacity(0.45)
                EditorInspectorView(model: model, mode: $inspectorMode, scopesVisible: $showScopes)
                    .frame(width: StudioLayout.editorInspectorWidth)
            }
        }
        .background(StudioPalette.canvas)
        .sheet(item: $quickExportRequest) { request in
            QuickExportSheet(model: model, imageID: request.id)
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
        .frame(height: 35)
        .background(StudioPalette.panel)
    }

    private var clampedFilmstripHeight: CGFloat {
        CGFloat(min(320.0, max(128.0, filmstripHeight)))
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

                Image(systemName: "rectangle.bottomthird.inset.filled")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Menu {
                    Button("Small") { filmstripHeight = 128 }
                    Button("Medium") { filmstripHeight = 156 }
                    Button("Large") { filmstripHeight = 232 }
                    Divider()
                    Button("Hide Filmstrip") { showFilmstrip = false }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .help("Filmstrip size and visibility")

                if let image = model.selectedImage {
                    Button {
                        quickExportRequest = QuickExportRequest(id: image.id)
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(model.isExporting)

                    Text(image.fileName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 170, alignment: .trailing)
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
    @Binding var scopesVisible: Bool
    @AppStorage(EditorPanelVisibilityStore.key) private var hiddenEditorPanels = ""

    var body: some View {
        StudioPanel {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Picker("Edit tools", selection: $mode) {
                        ForEach(StudioInspectorMode.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Button {
                        scopesVisible.toggle()
                    } label: {
                        Image(systemName: "waveform.path")
                    }
                    .buttonStyle(.borderless)
                    .help(scopesVisible ? "Hide scopes and monitor" : "Show scopes and monitor")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)

                if scopesVisible {
                    EditorScopePanelView(model: model)
                        .fixedSize(horizontal: false, vertical: true)
                    monitorControls
                }

                editActionStrip
                Rectangle().fill(StudioPalette.divider).frame(height: 1)

                ControlsView(model: model, mode: mode)
                    .frame(maxHeight: .infinity)
            }
        }
    }

    private var monitorControls: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Label("MONITOR", systemImage: "waveform.path")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Toggle("Clipping", isOn: Binding(
                    get: { model.project.preferences.clippingEnabled },
                    set: { model.setClippingEnabled($0) }))
                    .toggleStyle(.button).controlSize(.small)
                    .help("Warn when final output approaches white/red or black/blue. Bright warning is not always irreversible clipping.")
                Toggle("Skin", isOn: Binding(
                    get: { model.project.preferences.skinCheckEnabled },
                    set: { model.setSkinCheckEnabled($0) }))
                    .toggleStyle(.button).controlSize(.small)
                    .help("Show skin diagnostic on the rendered image")
            }
            if model.project.preferences.clippingEnabled {
                HStack(spacing: 8) {
                    Label(String(format:"Highlights %.1f%%", model.analysisMetrics.highlightPercent), systemImage:"circle.fill")
                        .foregroundStyle(.red)
                    Label(String(format:"Shadows %.1f%%", model.analysisMetrics.shadowPercent), systemImage:"circle.fill")
                        .foregroundStyle(.blue)
                    Spacer()
                    Text("Final render").foregroundStyle(.secondary)
                }
                .font(.caption2.monospacedDigit())
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(StudioPalette.panel)
    }

    private var editActionStrip: some View {
        HStack(spacing: 6) {
            Button { model.undo() } label: { Label("Undo", systemImage:"arrow.uturn.backward") }
                .help("Undo edit")
            Button { model.redo() } label: { Label("Redo", systemImage:"arrow.uturn.forward") }
                .help("Redo edit")
            Spacer(minLength: 3)
            Button { model.copyLook() } label: { Label("Copy", systemImage:"doc.on.doc") }
                .help("Copy this photo's enabled edit categories (⌘C)")
            Button { model.pasteLook() } label: { Label("Paste", systemImage:"doc.on.clipboard") }
                .help("Paste edits to the filmstrip selection (⌘V)")
            Menu {
                Section("Copy / Paste Categories") {
                    ForEach(LookCopyCategory.allCases) { category in
                        Toggle(category.rawValue, isOn: Binding(
                            get: { model.lookCopyCategoryEnabled(category) },
                            set: { model.setLookCopyCategory(category, enabled: $0) }
                        ))
                    }
                }
                Divider()
                Button(role: .destructive) { model.resetLook() } label: { Label("Reset All", systemImage: "arrow.counterclockwise") }
            } label: { Image(systemName:"ellipsis.circle") }
                .help("Edit category selection and reset")
        }
        .font(.caption)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(StudioPalette.panel)
    }

}
