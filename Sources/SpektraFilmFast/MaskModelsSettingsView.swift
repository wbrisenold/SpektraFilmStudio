import SwiftUI

struct MaskModelsSettingsView: View {
    @State private var installing: String?
    @State private var status = ""
    @State private var revision = 0
    var body: some View {
        Form {
            Section("Built into macOS") {
                Text("Subject, Background, People and face parts use Apple Vision. iPhone hair mattes and depth maps are read from the original photo.")
            }
            Section("Optional models · same versions as Redlamp") {
                #if arch(x86_64)
                Text("Models prefer the selected GPU. Core ML may schedule unsupported operations on the CPU; there is no automatic CPU-only retry. Compatibility and speed depend on your graphics hardware.")
                    .font(.caption).foregroundStyle(.secondary)
                #endif
                ForEach(ModelCatalog.all) { manifest in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(manifest.name).fontWeight(.medium)
                            Spacer()
                            if installed(manifest) {
                                Label("Installed", systemImage: "checkmark.circle")
                                    .foregroundStyle(.secondary)
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
                                .disabled(installing != nil || !manifest.fits())
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
    private func installed(_ manifest: ModelManifest) -> Bool {
        _ = revision
        if manifest.id == "sam2.1-tiny", let resources = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: resources.appendingPathComponent("AIModels/SAM2Tiny").path) { return true }
        return MaskModelStore.installed(manifest)
    }
}
