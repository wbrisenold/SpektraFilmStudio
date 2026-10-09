import SwiftUI
import UniformTypeIdentifiers

/// Native Pro Studio shell: project actions live in a text-only menu, photography
/// workflows stay in one predictable navigation row, and status is unobtrusive.
struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var frameState: PreviewFrameState
    @State private var showingCloudTransfer = false
    @State private var showingOmni = false
    @State private var showingSceneAssistant = false

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
        .overlay(alignment: .top) {
            if showingOmni {
                StudioOmniSearch(model: model, isPresented: $showingOmni)
                    .zIndex(100)
            }
        }
        .frame(minWidth: 1080, minHeight: 650)
        .sheet(isPresented: $model.showingLightroomImportWizard) {
            StudioImportWizard(model: model, preferredSource: "Lightroom Classic")
        }
        .sheet(isPresented: $showingCloudTransfer) {
            NativeCloudTransferView(model: model)
        }
        .sheet(isPresented: $showingSceneAssistant) {
            StudioSceneAssistantView(model: model)
        }
        .onReceive(NotificationCenter.default.publisher(for: StudioOmniEvents.openSceneAssistant)) { _ in
            showingSceneAssistant = true
        }
        .onReceive(NotificationCenter.default.publisher(for: StudioOmniEvents.open)) { _ in
            showingOmni.toggle()
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
            Button {
                model.page = .library
                model.showProjectHome = true
            } label: {
                HStack(spacing: 9) {
                    SpektraApplicationIconView()
                        .frame(width: 27, height: 27)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("SPEKTRAFILM")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(1.0)
                        Text(model.project.name)
                            .font(StudioType.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: 196, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("Home · New, Open and Recent Projects")
            .accessibilityLabel("Home and recent projects")

            Spacer(minLength: 4)

            HStack(spacing: 2) {
                ForEach(WorkspacePage.allCases) { page in
                    let selected = model.page == page && !model.showProjectHome
                    Button {
                        model.showProjectHome = false
                        model.page = page
                    } label: {
                        Text(page.title)
                            .font(.system(size: 11, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? .primary : .secondary)
                            .padding(.horizontal, 14)
                            .frame(height: 29)
                            .background(selected ? StudioPalette.selected : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            .padding(4)
            .background(StudioPalette.recessed,
                        in: RoundedRectangle(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(StudioPalette.subtleBorder, lineWidth: 0.5)
            }
            .accessibilityLabel("Workspace")

            Spacer(minLength: 4)

            Button {
                showingOmni = true
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Omni Search · ⌘K")

            Button {
                showingCloudTransfer = true
            } label: {
                Image(systemName: "icloud")
            }
            .buttonStyle(.borderless)
            .help("Cloud library, Lightroom and transfer settings")
            .accessibilityLabel("Cloud Setup")

            if model.isIngesting {
                ProgressView(value: model.ingestProgress)
                    .frame(width: 55)
                    .help(model.ingestStatus)
            }
            if model.isExporting {
                ProgressView()
                    .controlSize(.mini)
                    .help("Export in progress")
            }
            if model.page == .library && !model.project.images.isEmpty {
                Button {
                    model.importImages()
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
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 15)
        .frame(height: 51)
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
            let sourceCommit = Bundle.main.object(forInfoDictionaryKey: "SpektraSourceCommit") as? String ?? "unidentified"
            Text("Source: \(String(sourceCommit.prefix(12)))\(sourceCommit.hasSuffix("-dirty") ? "-dirty" : "")")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help("Source: \(sourceCommit). A dirty build includes uncommitted changes.")
            // GPU timing stays available in the scopes/diagnostics inspector,
            // rather than occupying permanent toolbar/status real estate.
        }
        .font(.caption2)
        .padding(.horizontal, 12)
        .frame(height: 22)
        .background(StudioPalette.panel)
    }
}
