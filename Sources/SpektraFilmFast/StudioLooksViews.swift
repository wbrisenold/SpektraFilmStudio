import AppKit
import SwiftUI

// Looks is deliberately small. Lab keeps the full native inspector and physics.
struct StudioLooksBrowserView: View {
    @ObservedObject var model: AppModel
    @AppStorage(StudioLooksSettings.modeKey) private var mode = "native"
    @AppStorage(StudioLooksSettings.folderKey) private var root = ""
    @AppStorage(StudioLooksSettings.selectedIDKey) private var selected = ""
    @State private var packs: [StudioLooksPack.Manifest] = []
    @State private var browserError = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Looks").font(.headline)
                Spacer()
                Button("Folder…") { choose() }
                Button {
                    rescan()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh Looks")
            }.padding(.horizontal, 12)
            if packs.isEmpty {
                Text("Choose a folder containing Look packs. Each pack has manifest.json and cube.bin.")
                    .font(.caption).foregroundStyle(.secondary).padding(12)
            }
            if !browserError.isEmpty {
                Text(browserError).foregroundStyle(.orange).font(.caption).padding(.horizontal, 12)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(packs) { pack in
                        Button {
                            select(pack)
                        } label: {
                            HStack(spacing: 10) {
                                thumbnail(pack)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(pack.name).font(.subheadline).fontWeight(.medium)
                                    Text(pack.category).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if (model.selectedLook.studioLookID ?? selected) == pack.id && mode == "looks" {
                                    Image(systemName: "checkmark.circle.fill")
                                }
                            }.padding(7)
                                .background(
                                    (model.selectedLook.studioLookID ?? selected) == pack.id && mode == "looks"
                                        ? Color.accentColor.opacity(0.16) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 8)
            }
        }
        .onAppear { rescan() }
        .onChange(of: root) { _, _ in rescan() }
    }

    @ViewBuilder private func thumbnail(_ pack: StudioLooksPack.Manifest) -> some View {
        if let folder = pack.folder, let name = pack.thumbnail,
            !name.contains("/") && !name.contains("..")
        {
            AsyncThumbnail(url: folder.appendingPathComponent(name))
        } else {
            Image(systemName: "camera.filters")
                .frame(width: 55, height: 55)
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private struct AsyncThumbnail: View {
        let url: URL
        @State private var image: NSImage? = nil
        var body: some View {
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "camera.filters")
                }
            }
            .frame(width: 55, height: 55).clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            .task {
                if image == nil {
                    image = await Task.detached(priority: .utility) {
                        NSImage(contentsOfFile: url.path)
                    }.value
                }
            }
        }
    }
    private func rescan() {
        packs = root.isEmpty ? [] : StudioLooksPack.discover(in: URL(fileURLWithPath: root, isDirectory: true))
        browserError = packs.isEmpty && !root.isEmpty ? "No valid linear Rec.2020 Look packs in this folder" : ""
    }
    private func select(_ pack: StudioLooksPack.Manifest) {
        selected = pack.id
        mode = "looks"
        model.setSelectedLooksPack(pack.id)
    }
    private func choose() {
        Task { @MainActor in
            guard let folder = await SpektraFilePanel.folder(title: "Choose Looks Folder") else { return }
            root = folder.standardizedFileURL.path
            rescan()
        }
    }
}

struct StudioLooksInspectorView: View {
    @ObservedObject var model: AppModel
    @AppStorage(StudioLooksSettings.selectedIDKey) private var selected = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(
                    StudioLooksSettings.selectedPack(for: model.selectedLook)?.name
                        ?? "Choose a Look from the left browser"
                )
                .font(.headline)
                Text("Live · Scene-linear Rec.2020")
                    .font(.caption).foregroundStyle(.secondary)
                if StudioLooksSettings.selectedPack(for: model.selectedLook) != nil {
                    slider("Strength", key: "strength", initial: 1, range: 0...1)
                    slider("Exposure", key: "exposure", initial: 0, range: -5...5)
                    slider("Contrast", key: "contrast", initial: 0, range: -2...2)
                    slider("Warmth", key: "temperature", initial: 0, range: -1...1)
                    slider("Tint", key: "tint", initial: 0, range: -1...1)
                }
                Text(
                    "Looks use a finished color asset. Exact grain, halation, masks, and full-resolution Looks export remain in Lab until their GPU paths pass fidelity tests."
                )
                .font(.caption2).foregroundStyle(.secondary)
            }.padding(12)
        }
    }
    private func slider(
        _ title: String, key: String, initial: Double,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(
                    String(
                        format: "%.2f", Double(StudioLooksSettings.scalar(model.selectedLook, key, default: initial)))
                )
                .monospacedDigit().font(.caption)
            }
            Slider(
                value: Binding(
                    get: { Double(StudioLooksSettings.scalar(model.selectedLook, key, default: initial)) },
                    set: { model.setParameter("looks." + key, value: .scalar($0), interactive: true) }),
                in: range,
                onEditingChanged: { editing in
                    if editing { model.beginEditGesture() } else { model.endEditGesture() }
                })
        }
    }
}
