import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var frameState: PreviewFrameState

    init(model: AppModel) {
        self.model = model
        _frameState = ObservedObject(wrappedValue: model.frameState)
    }

    var body: some View {
        VStack(spacing: 0) {
            topToolbar
            if model.missingMediaCount > 0 { missingMediaBanner }
            Divider().opacity(0.65)
            workspace
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.65)
            statusBar
        }
        .background(StudioPalette.canvas)
        .frame(minWidth: 1180, minHeight: 760)
        .onChange(of: model.page) { _, newPage in
            model.workspaceDidChange(newPage)
        }
        .alert(
            "Metal Renderer",
            isPresented: Binding(
                get: { model.rendererError != nil },
                set: { if !$0 { model.rendererError = nil } }
            )
        ) {
            Button("OK") { model.rendererError = nil }
        } message: {
            Text(model.rendererError ?? "")
        }
    }

    @ViewBuilder
    private var workspace: some View {
        switch model.page {
        case .library: LibraryWorkspaceView(model: model)
        case .cull: CullWorkspaceView(model: model)
        case .proofs: ProofsWorkspaceView(model: model)
        case .edit: EditWorkspaceView(model: model)
        case .export: ExportWorkspaceView(model: model)
        }
    }

    private var topToolbar: some View {
        HStack(spacing: 10) {
            Menu {
                Button("New Project") { model.newProject() }
                Button("Open Project…") { model.openProject() }
                Divider()
                Button("Standalone Photo Mode…") { model.standalonePhotoMode() }
            } label: {
                HStack(spacing: 7) {
                    SpektraApplicationIconView()
                        .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 5) {
                            Text("SpektraFilm")
                                .font(.system(size: 12, weight: .semibold))
                            if model.isProjectDirty {
                                Circle()
                                    .fill(.secondary)
                                    .frame(width: 5, height: 5)
                                    .help("Unsaved changes")
                            }
                        }
                        Text(model.project.name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Divider().frame(height: 24)

            HStack(spacing: 2) {
                ForEach(WorkspacePage.allCases) { page in
                    Button {
                        model.page = page
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: page.systemImage)
                            Text(page.title)
                        }
                        .font(.system(size: 11, weight: model.page == page ? .semibold : .regular))
                        .foregroundStyle(model.page == page ? .primary : .secondary)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(model.page == page ? StudioPalette.selected : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(StudioPalette.recessed, in: RoundedRectangle(cornerRadius: 9))

            Spacer(minLength: 12)

            if let image = model.selectedImage {
                HStack(spacing: 2) {
                    ForEach(1...5, id: \.self) { n in
                        StudioIconButton(
                            systemImage: n <= image.rating ? "star.fill" : "star",
                            help: "Rate \(n) star\(n == 1 ? "" : "s")"
                        ) { model.setRating(n) }
                    }
                }
                .foregroundStyle(.secondary)

                Divider().frame(height: 22)

                StudioIconButton(
                    systemImage: image.flag == .picked ? "flag.fill" : "flag",
                    help: "Pick",
                    isSelected: image.flag == .picked
                ) { model.setFlag(.picked) }

                StudioIconButton(
                    systemImage: image.flag == .rejected ? "xmark.circle.fill" : "xmark.circle",
                    help: "Reject",
                    isSelected: image.flag == .rejected
                ) { model.setFlag(.rejected) }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: StudioLayout.toolbarHeight)
        .background(StudioPalette.panel)
    }

    private var missingMediaBanner: some View {
        HStack(spacing: 9) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .foregroundStyle(.orange)
            Text("\(model.missingMediaCount) source file\(model.missingMediaCount == 1 ? " is" : "s are") missing")
            Button("Relink…") { model.relinkMissingMedia() }
                .buttonStyle(.link)
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(.orange.opacity(0.09))
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Text(frameState.status)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 12)

            if model.isCullAnalyzing {
                Text("Cull \(Int(model.cullAnalysisProgress * 100))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if frameState.isRendering {
                ProgressView().controlSize(.mini)
                Text("Rendering").foregroundStyle(.secondary)
            }

            if model.rendererAvailable {
                Text(String(format: "GPU %.1f ms", frameState.diagnostics.commandBufferMs))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if let image = frameState.renderedPreview {
                Text("\(max(image.width, image.height)) px")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
        .padding(.horizontal, 10)
        .frame(height: StudioLayout.statusHeight)
        .background(StudioPalette.panel)
    }
}
