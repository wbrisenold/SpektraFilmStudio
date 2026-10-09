import SwiftUI

struct MaskModelsSettingsView: View {
    @State private var installing: String?
    @State private var status = ""
    @State private var revision = 0
    @AppStorage("SpektraFilmStudio.ai.depthProvider") private var depthProvider = "automatic"
    var body: some View {
        Form {
            Section("Active Model Providers") {
                LabeledContent("Subject / Background / People") {
                    Text("Apple Vision (fixed)").foregroundStyle(.secondary)
                }
                LabeledContent("Object selection") {
                    Text("SAM 2.1 Tiny (bundled)").foregroundStyle(.secondary)
                }
                LabeledContent("Hair / Clothing / Skin parts") {
                    Text("SAM 3 when available").foregroundStyle(.secondary)
                }
                LabeledContent("Depth model") {
                    Picker("Depth model", selection: $depthProvider) {
                        Text("Automatic (embedded → DA3 → DA2)").tag("automatic")
                        Text("Depth Anything 3 Large").tag("da3")
                        Text("Depth Anything V2 Small").tag("da2")
                        Text("Embedded camera depth only").tag("embedded")
                    }
                    .labelsHidden()
                    .frame(maxWidth: 340)
                }
                Text("The selected provider is used for new Depth Range masks. Manually selected models must be installed; there is no silent fallback. Automatic uses the listed priority. For existing masks use Masks › Update AI Masks.")
                    .font(.caption).foregroundStyle(.secondary)
                if depthProvider == "da3", let manifest = ModelCatalog.manifest("depth-anything-3-mono-large"),
                   !MaskModelStore.installed(manifest) {
                    Label("Depth Anything 3 is not installed. Download it below before creating depth masks.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).font(.caption)
                }
                if depthProvider == "da2", let manifest = ModelCatalog.manifest("depth-anything-v2-small"),
                   !MaskModelStore.installed(manifest) {
                    Label("Depth Anything V2 is not installed. Download it below before creating depth masks.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).font(.caption)
                }
            }
            Section("Optional models · same versions as Redlamp") {
                #if arch(x86_64)
                Text("Models prefer the selected GPU. Core ML may schedule unsupported operations on the CPU; there is no automatic CPU-only retry. Compatibility and speed depend on your graphics hardware.")
                    .font(.caption).foregroundStyle(.secondary)
                #endif
                ForEach(ModelCatalog.offered) { manifest in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(manifest.name).fontWeight(.medium)
                            Spacer()
                            if installed(manifest) {
                                Label("Installed", systemImage: "checkmark.circle")
                                    .foregroundStyle(.secondary)
                                if selectedModel(manifest) {
                                    Label("Selected for depth", systemImage: "checkmark.seal")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            } else {
                                Button(installing == manifest.id ? "Downloading…" : "Download") {
                                    installing = manifest.id
                                    status = "Downloading and verifying \(manifest.name)…"
                                    Task {
                                        do {
                                            try await MaskModelStore.shared.install(manifest)
                                            await RedlampMaskService.shared.invalidateComputedMasks()
                                            status = "\(manifest.name) installed and verified"
                                        } catch { status = error.localizedDescription }
                                        installing = nil
                                        revision += 1
                                    }
                                }
                                .disabled(installing != nil || !manifest.fits() || !manifest.isPublished)
                            }
                        }
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(manifest.downloadBytes), countStyle: .file)) · \(manifest.purpose)")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Weights: \(manifest.licenses.weights) · Code: \(manifest.licenses.code)")
                            .font(.caption2).foregroundStyle(.secondary)
                        if let notes = manifest.notes {
                            Text(notes).font(.caption2).foregroundStyle(.secondary)
                        }
                        Link("Model source and terms", destination: manifest.source)
                            .font(.caption)
                    }.padding(.vertical, 5)
                }
                Text("Downloading a model uses the listed publisher’s terms. SAM 3’s Meta SAM License is downloaded with its weights; Snow prompts and their license are included with the app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !status.isEmpty { Text(status).font(.caption).textSelection(.enabled) }
        }
        .formStyle(.grouped)
        .padding(14)
    }
    private func selectedModel(_ manifest: ModelManifest) -> Bool {
        (depthProvider == "da3" && manifest.id == "depth-anything-3-mono-large") ||
        (depthProvider == "da2" && manifest.id == "depth-anything-v2-small")
    }
    private func installed(_ manifest: ModelManifest) -> Bool {
        _ = revision
        if manifest.id == "sam2.1-tiny", let resources = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: resources.appendingPathComponent("AIModels/SAM2Tiny").path) { return true }
        return MaskModelStore.installed(manifest)
    }
}
