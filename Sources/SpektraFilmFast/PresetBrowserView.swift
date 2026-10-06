import SwiftUI

struct PresetBrowserView: View {
    @ObservedObject var model: AppModel
    @State private var search = ""
    @State private var category = "All"
    @State private var showingSaveSheet = false
    @State private var newName = ""
    @State private var newCategory = "Custom"

    @AppStorage("SpektraFilmFast.favoritePresetIDs")
    private var favoritePresetIDsStorage = ""
    @AppStorage("SpektraFilmFast.recentPresetIDs")
    private var recentPresetIDsStorage = ""

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.65)
            categoryRail
            Divider().opacity(0.45)

            if visiblePresets.isEmpty {
                ContentUnavailableView(
                    "No Presets",
                    systemImage: "square.grid.2x2",
                    description: Text(emptyMessage)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 9) {
                        ForEach(visiblePresets) { preset in
                            PresetTile(
                                model: model,
                                preset: preset,
                                isFavorite: favoriteIDs.contains(preset.id.uuidString),
                                onApply: {
                                    addRecent(preset.id)
                                    model.applyPreset(preset)
                                },
                                onToggleFavorite: { toggleFavorite(preset.id) },
                                onDelete: {
                                    removeStoredID(preset.id)
                                    model.deletePreset(preset)
                                }
                            )
                        }
                    }
                    .padding(9)
                }
            }

            Divider().opacity(0.65)
            footer
        }
        .background(StudioPalette.panel)
        .sheet(isPresented: $showingSaveSheet) { savePresetSheet }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Presets").font(.headline)
                    Text("\(model.presets.count) looks")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showingSaveSheet = true
                } label: {
                    Label("Save", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.selectedImage == nil)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search presets", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(
                StudioPalette.recessed,
                in: RoundedRectangle(cornerRadius: 7)
            )
        }
        .padding(10)
    }

    private var categoryRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(categoryChoices, id: \.self) { value in
                    Button { category = value } label: {
                        HStack(spacing: 4) {
                            if value == "Favorites" {
                                Image(systemName: "star.fill")
                            } else if value == "Recent" {
                                Image(systemName: "clock")
                            }
                            Text(value)
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(
                            category == value ? StudioPalette.selected : Color.clear,
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button { model.importPreset() } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)
            Spacer()
            Text("Hover to preview")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
    }

    private var savePresetSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save Current Look").font(.title3.weight(.semibold))
            TextField("Preset name", text: $newName)
                .textFieldStyle(.roundedBorder)
            TextField("Category", text: $newCategory)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { showingSaveSheet = false }
                Spacer()
                Button("Save Preset") {
                    model.savePreset(
                        name: newName.trimmingCharacters(in: .whitespacesAndNewlines),
                        category: newCategory.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    newName = ""
                    showingSaveSheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedImage == nil)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private var visiblePresets: [SpektraPreset] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [SpektraPreset]

        switch category {
        case "Favorites":
            base = model.presets.filter { favoriteIDs.contains($0.id.uuidString) }
        case "Recent":
            let index = Dictionary(
                uniqueKeysWithValues: recentIDs.enumerated().map { ($0.element, $0.offset) }
            )
            base = model.presets
                .filter { index[$0.id.uuidString] != nil }
                .sorted {
                    (index[$0.id.uuidString] ?? Int.max) <
                    (index[$1.id.uuidString] ?? Int.max)
                }
        case "All":
            base = model.presets
        default:
            base = model.presets.filter { $0.category == category }
        }

        guard !needle.isEmpty else { return base }
        return base.filter {
            $0.name.localizedCaseInsensitiveContains(needle) ||
            $0.category.localizedCaseInsensitiveContains(needle)
        }
    }

    private var categoryChoices: [String] {
        var values = ["All", "Favorites", "Recent"]
        values.append(contentsOf: model.presetCategories.filter { $0 != "All" })
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private var favoriteIDs: Set<String> {
        Set(favoritePresetIDsStorage.split(separator: ",").map(String.init))
    }

    private var recentIDs: [String] {
        recentPresetIDsStorage.split(separator: ",").map(String.init)
    }

    private var emptyMessage: String {
        if !search.isEmpty { return "No preset matches “\(search)”." }
        switch category {
        case "Favorites": return "Star presets to keep them here."
        case "Recent": return "Applied presets appear here."
        default: return "Save or import a preset to get started."
        }
    }

    private func toggleFavorite(_ id: UUID) {
        var ids = favoriteIDs
        let key = id.uuidString
        if ids.contains(key) { ids.remove(key) } else { ids.insert(key) }
        favoritePresetIDsStorage = ids.sorted().joined(separator: ",")
    }

    private func addRecent(_ id: UUID) {
        let key = id.uuidString
        var ids = recentIDs.filter { $0 != key }
        ids.insert(key, at: 0)
        if ids.count > 16 { ids = Array(ids.prefix(16)) }
        recentPresetIDsStorage = ids.joined(separator: ",")
    }

    private func removeStoredID(_ id: UUID) {
        let key = id.uuidString
        var favorites = favoriteIDs
        favorites.remove(key)
        favoritePresetIDsStorage = favorites.sorted().joined(separator: ",")
        recentPresetIDsStorage = recentIDs.filter { $0 != key }.joined(separator: ",")
    }
}

private struct PresetTile: View {
    @ObservedObject var model: AppModel
    let preset: SpektraPreset
    let isFavorite: Bool
    let onApply: () -> Void
    let onToggleFavorite: () -> Void
    let onDelete: () -> Void

    @State private var thumbnail: CGImage?
    @State private var isHovering = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var didStartPreview = false

    private var thumbnailTaskID: String {
        "\(model.project.selectedImageID?.uuidString ?? "none")-\(preset.id.uuidString)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumbnail {
                        Image(decorative: thumbnail, scale: 1)
                            .resizable()
                            .scaledToFill()
                    } else if let selected = model.selectedImage {
                        LocalThumbnail(url: selected.url, contentMode: .fill)
                            .overlay {
                                Color.black.opacity(0.18)
                                ProgressView().controlSize(.small)
                            }
                    } else {
                        ZStack {
                            StudioPalette.recessed
                            Image(systemName: "photo").foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(height: 92)
                .frame(maxWidth: .infinity)
                .clipped()

                HStack(spacing: 4) {
                    Button(action: onToggleFavorite) {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .font(.caption)
                            .frame(width: 23, height: 23)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)

                    Menu {
                        Button("Apply", action: onApply)
                        Button("Export Preset…") { model.exportPreset(preset) }
                        Divider()
                        Button(isFavorite ? "Remove Favorite" : "Favorite", action: onToggleFavorite)
                        Button("Delete", role: .destructive, action: onDelete)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.caption.weight(.semibold))
                            .frame(width: 23, height: 23)
                            .background(.regularMaterial, in: Circle())
                    }
                    .menuStyle(.borderlessButton)
                }
                .padding(5)
            }

            Text(preset.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(preset.category)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(6)
        .background(
            isHovering ? StudioPalette.hover : StudioPalette.recessed.opacity(0.45),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(
                    isHovering ? StudioPalette.selectedBorder : StudioPalette.subtleBorder,
                    lineWidth: isHovering ? 1 : 0.5
                )
        }
        .contentShape(Rectangle())
        .onTapGesture {
            hoverTask?.cancel()
            onApply()
        }
        .onHover { hovering in
            isHovering = hovering
            hoverTask?.cancel()
            if hovering {
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(180))
                    guard !Task.isCancelled, isHovering else { return }
                    didStartPreview = true
                    model.previewPreset(preset)
                }
            } else if didStartPreview {
                didStartPreview = false
                model.endPresetPreview()
            }
        }
        .task(id: thumbnailTaskID) {
            thumbnail = await model.presetThumbnail(preset, longEdge: 360)
        }
        .help("Click to apply. Hover briefly to preview on the main image.")
    }
}
