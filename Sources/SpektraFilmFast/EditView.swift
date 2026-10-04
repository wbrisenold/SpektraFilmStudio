import SwiftUI

struct EditWorkspaceView: View {
    @ObservedObject var model: AppModel

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

    private var filmstrip: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Filmstrip")
                    .font(.caption.weight(.semibold))
                Text("\(model.visibleImages.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if let image = model.selectedImage {
                    Text(image.fileName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(StudioPalette.panel)

            ScrollView(.horizontal) {
                LazyHStack(spacing: 7) {
                    ForEach(model.visibleImages) { image in
                        VStack(spacing: 4) {
                            LocalThumbnail(url: image.url)
                                .frame(width: 106, height: 70)
                                .clipShape(RoundedRectangle(cornerRadius: 5))

                            HStack(spacing: 4) {
                                if image.rating > 0 {
                                    Text("\(image.rating)★")
                                        .font(.caption2.monospacedDigit())
                                }
                                if image.flag == .picked {
                                    Image(systemName: "flag.fill").font(.caption2)
                                } else if image.flag == .rejected {
                                    Image(systemName: "xmark.circle.fill").font(.caption2)
                                }
                            }
                            .foregroundStyle(.secondary)
                            .frame(height: 12)
                        }
                        .padding(4)
                        .studioSelection(model.project.selectedImageID == image.id)
                        .contentShape(Rectangle())
                        .onTapGesture { model.selectImage(image.id, renderPreview: true) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
            }
            .background(StudioPalette.recessed)
        }
        .frame(height: StudioLayout.filmstripHeight)
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
                StudioIconButton(systemImage: "doc.on.doc", help: "Copy all current image adjustments") { model.copyLook() }
                StudioIconButton(systemImage: "doc.on.clipboard", help: "Paste copied adjustments onto this image") { model.pasteLook() }
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
