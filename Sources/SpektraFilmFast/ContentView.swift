import SwiftUI

/// Native Pro Studio shell: project actions live in a text-only menu, photography
/// workflows stay in one predictable navigation row, and status is unobtrusive.
struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var frameState: PreviewFrameState
    @State private var showingImportWizard = false

    init(model: AppModel) {
        self.model = model
        _frameState = ObservedObject(wrappedValue: model.frameState)
    }

    var body: some View {
        VStack(spacing: 0) {
            topToolbar
            if model.missingMediaCount > 0 { missingMediaBanner }
            Rectangle().fill(StudioPalette.divider).frame(height: 1)
            workspace
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(StudioPalette.divider).frame(height: 1)
            statusBar
        }
        .background(StudioPalette.canvas)
        .frame(minWidth: 1024, minHeight: 650)
        .sheet(isPresented: $showingImportWizard) {
            StudioImportWizard(model: model)
        }
        .onChange(of: model.page) { _, newPage in
            model.workspaceDidChange(newPage)
        }
        .onReceive(NotificationCenter.default.publisher(for: GPUProcessingFailure.notification)) { event in
            if let detail = event.object as? String { model.rendererError = detail }
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
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("SPEKTRAFILM")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .tracking(1.3)
                    .foregroundStyle(.secondary)
                Text(model.project.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 190, alignment: .leading)
            .help("Project commands are in the native File menu")

            Spacer(minLength: 6)

            HStack(spacing: 2) {
                ForEach(WorkspacePage.allCases) { page in
                    Button {
                        model.page = page
                    } label: {
                        Text(page.title)
                            .font(.system(size: 12, weight: model.page == page ? .semibold : .regular))
                            .foregroundStyle(model.page == page ? .primary : .secondary)
                            .padding(.horizontal, 13)
                            .frame(height: 29)
                            .background(
                                model.page == page ? StudioPalette.selected : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.page == page ? [.isSelected] : [])
                }
            }
            .padding(3)
            .background(StudioPalette.recessed, in: RoundedRectangle(cornerRadius: 9))
            .accessibilityLabel("Workspace")

            Spacer(minLength: 6)

            if model.isIngesting {
                ProgressView(value: model.ingestProgress)
                    .frame(width: 64)
                    .help(model.ingestStatus)
            }

            if model.isExporting {
                ProgressView()
                    .controlSize(.mini)
                    .help("Export in progress")
            }

            if model.page == .library && !model.project.images.isEmpty {
                Button {
                    showingImportWizard = true
                } label: {
                    Label("Import", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else if model.page == .edit, model.selectedImage != nil {
                Button {
                    model.page = .export
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 45)
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
        HStack(spacing: 10) {
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
            if let image = frameState.renderedPreview {
                Text("\(max(image.width, image.height)) px")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            // GPU timing stays available in the scopes/diagnostics inspector,
            // rather than occupying permanent toolbar/status real estate.
        }
        .font(.caption2)
        .padding(.horizontal, 12)
        .frame(height: 22)
        .background(StudioPalette.panel)
    }
}
