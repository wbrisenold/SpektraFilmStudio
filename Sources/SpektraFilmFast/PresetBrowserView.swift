import SwiftUI

struct PresetBrowserView: View {
    @ObservedObject var model: AppModel
    @State private var search = ""
    @State private var category = "All"
    @State private var showingSaveSheet = false
    @State private var newName = ""
    @State private var newCategory = "Custom"
    @AppStorage("SpektraFilmFast.favoritePresetIDs") private var favoritesStorage = ""
    @AppStorage("SpektraFilmFast.recentPresetIDs") private var recentsStorage = ""

    private var favorites: Set<String> { Set(favoritesStorage.split(separator: ",").map(String.init)) }
    private var recents: [String] { recentsStorage.split(separator: ",").map(String.init) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack {
                    Text("Presets").font(.headline)
                    Spacer()
                    Button { showingSaveSheet = true } label: { Label("Save", systemImage: "plus") }
                        .controlSize(.small).disabled(model.selectedImage == nil)
                }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search presets", text: $search).textFieldStyle(.plain)
                }
                .padding(.horizontal, 8).frame(height: 30)
                .background(StudioPalette.recessed, in: RoundedRectangle(cornerRadius: 7))
            }.padding(10)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(categories, id: \.self) { value in
                        Button(value) { category = value }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .padding(.horizontal, 8).frame(height: 26)
                            .background(category == value ? StudioPalette.selected : Color.clear, in: Capsule())
                    }
                }.padding(.horizontal, 9).padding(.vertical, 6)
            }

            Divider()

            List {
                ForEach(visiblePresets) { preset in
                    PresetListRow(
                        model: model,
                        preset: preset,
                        favorite: favorites.contains(preset.id.uuidString),
                        apply: { addRecent(preset.id); model.applyPreset(preset) },
                        toggleFavorite: { toggleFavorite(preset.id) },
                        delete: { model.deletePreset(preset) }
                    )
                }
            }
            .listStyle(.inset)

            Divider()
            HStack {
                Button { model.importPreset() } label: { Label("Import", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.borderless)
                Spacer()
                Text("Hover = live preview · Click = apply").font(.caption2).foregroundStyle(.secondary)
            }.padding(.horizontal, 10).frame(height: 38)
        }
        .background(StudioPalette.panel.opacity(0.12))
        .sheet(isPresented: $showingSaveSheet) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Save Current Look").font(.title3.weight(.semibold))
                TextField("Preset name", text: $newName).textFieldStyle(.roundedBorder)
                TextField("Category", text: $newCategory).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Cancel") { showingSaveSheet = false }
                    Spacer()
                    Button("Save Preset") {
                        model.savePreset(name: newName.trimmingCharacters(in: .whitespacesAndNewlines),
                                         category: newCategory.trimmingCharacters(in: .whitespacesAndNewlines))
                        newName = ""; showingSaveSheet = false
                    }.buttonStyle(.borderedProminent).disabled(model.selectedImage == nil)
                }
            }.padding(20).frame(width: 360)
        }
    }

    private var categories: [String] {
        let values = ["All", "Favorites", "Recent"] + model.presetCategories.filter { $0 != "All" }
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private var visiblePresets: [SpektraPreset] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [SpektraPreset]
        switch category {
        case "Favorites": base = model.presets.filter { favorites.contains($0.id.uuidString) }
        case "Recent":
            let rank = Dictionary(recents.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
            base = model.presets.filter { rank[$0.id.uuidString] != nil }
                .sorted { (rank[$0.id.uuidString] ?? Int.max) < (rank[$1.id.uuidString] ?? Int.max) }
        case "All": base = model.presets
        default: base = model.presets.filter { $0.category == category }
        }
        return needle.isEmpty ? base : base.filter {
            $0.name.localizedCaseInsensitiveContains(needle) || $0.category.localizedCaseInsensitiveContains(needle)
        }
    }

    private func toggleFavorite(_ id: UUID) {
        var set = favorites
        let key = id.uuidString
        if set.contains(key) { set.remove(key) } else { set.insert(key) }
        favoritesStorage = set.sorted().joined(separator: ",")
    }

    private func addRecent(_ id: UUID) {
        let key = id.uuidString
        var list = recents.filter { $0 != key }
        list.insert(key, at: 0)
        recentsStorage = Array(list.prefix(16)).joined(separator: ",")
    }
}

private struct PresetListRow: View {
    @ObservedObject var model: AppModel
    let preset: SpektraPreset
    let favorite: Bool
    let apply: () -> Void
    let toggleFavorite: () -> Void
    let delete: () -> Void
    @State private var hovering = false
    @State private var previewing = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "camera.filters").foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(preset.name).font(.caption.weight(.semibold)).lineLimit(1)
                Text(preset.category).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button(action: toggleFavorite) { Image(systemName: favorite ? "star.fill" : "star") }
                .buttonStyle(.borderless)
            Menu {
                Button("Apply", action: apply)
                Button("Export Preset…") { model.exportPreset(preset) }
                Divider()
                Button(favorite ? "Remove Favorite" : "Favorite", action: toggleFavorite)
                Button("Delete", role: .destructive, action: delete)
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 3)
        .background(hovering ? StudioPalette.hover.opacity(0.7) : Color.clear)
        .onTapGesture { hoverTask?.cancel(); apply() }
        .onHover { inside in
            hovering = inside
            hoverTask?.cancel()
            if inside {
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(140))
                    guard !Task.isCancelled, hovering else { return }
                    previewing = true
                    model.previewPreset(preset)
                }
            } else if previewing {
                previewing = false
                model.endPresetPreview()
            }
        }
    }
}
