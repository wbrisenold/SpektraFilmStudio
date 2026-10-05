import SwiftUI
import AppKit

struct EditWorkspaceView: View {
    @ObservedObject var model: AppModel
    @AppStorage("editFilmstripHeight") private var filmstripHeight = 156.0
    @State private var filmstripResizeStart: Double?

    var body: some View {
        HStack(spacing: 0) {
            if model.isPresetSidebarVisible {
                PresetBrowserView(model: model)
                    .frame(width: StudioLayout.presetSidebarWidth)

                Divider().opacity(0.65)
            }

            VStack(spacing: 0) {
                PreviewView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider().opacity(0.65)
                filmstrip
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().opacity(0.65)

            EditorInspectorView(model: model)
                .frame(width: StudioLayout.editorInspectorWidth)
        }
        .background(StudioPalette.canvas)
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
                Slider(value: $filmstripHeight, in: 128...320)
                    .frame(width: 92)
                    .help("Resize filmstrip thumbnails.")
                Button { filmstripHeight = 156 } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.plain)
                .help("Reset filmstrip size.")

                if let image = model.selectedImage {
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

                                LocalThumbnail(url: image.url, contentMode: .fit)
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

    var body: some View {
        StudioPanel {
            VStack(spacing: 0) {
                // The monitor stays pinned while adjustments scroll independently below it.
                EditorScopePanelView(model: model)
                    .fixedSize(horizontal: false, vertical: true)

                monitorControls

                Divider().opacity(0.55)

                HStack {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("ADJUSTMENTS")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(StudioPalette.panel)

                ControlsView(model: model)
                    .frame(maxHeight: .infinity)
            }
        }
    }

    private var monitorControls: some View {
        HStack(spacing: 12) {
            Toggle(
                "Clip",
                isOn: Binding(
                    get: { model.project.preferences.clippingEnabled },
                    set: { model.setClippingEnabled($0) }
                )
            )
            .toggleStyle(.checkbox)

            Toggle(
                "Skin overlay",
                isOn: Binding(
                    get: { model.project.preferences.skinCheckEnabled },
                    set: { enabled in
                        model.setSkinCheckEnabled(enabled)
                        if enabled, model.project.preferences.skinCheckMode == .scope {
                            model.setSkinCheckMode(.both)
                        }
                    }
                )
            )
            .toggleStyle(.checkbox)

            Spacer(minLength: 4)

            HStack(spacing: 2) {
                StudioIconButton(systemImage: "arrow.uturn.backward", help: "Undo the last edit") { model.undo() }
                StudioIconButton(systemImage: "arrow.uturn.forward", help: "Redo the last undone edit") { model.redo() }
                StudioIconButton(systemImage: "doc.on.doc", help: "Copy the enabled edit categories") { model.copyLook() }
                StudioIconButton(systemImage: "doc.on.clipboard", help: "Paste the enabled edit categories to the highlighted photo(s)") { model.pasteLook() }
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
                    Button("Copy Selected Edits") { model.copyLook() }
                    Button("Paste to Highlighted") { model.pasteLook() }
                } label: {
                    Image(systemName: "checklist")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
                .help("Choose which edit categories Option-Command-C / Option-Command-V copy and paste.")
            }

            Button { model.resetLook() } label: {
                Label("Reset All", systemImage: "arrow.counterclockwise")
                    .font(.caption2.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .help("Reset every edit on this photo. Ratings, flags, Client Picks, metadata, and the original file are not changed. You can Undo this reset.")

            if model.project.preferences.clippingEnabled {
                HStack(spacing: 5) {
                    Circle().fill(.red).frame(width: 5, height: 5)
                    Text(String(format: "%.1f", model.analysisMetrics.highlightPercent))
                    Circle().fill(.blue).frame(width: 5, height: 5)
                    Text(String(format: "%.1f", model.analysisMetrics.shadowPercent))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(StudioPalette.panel)
        .overlay(alignment: .top) { Divider().opacity(0.35) }
    }
}
