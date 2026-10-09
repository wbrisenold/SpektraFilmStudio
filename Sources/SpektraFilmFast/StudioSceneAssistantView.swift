import SwiftUI

/// Local scene grouping and non-destructive recommendations. This is a creative assistant,
/// not a model trained to predict the objectively correct film stock for a photograph.
struct StudioSceneAssistantView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var sets: [StudioSceneSet] = []
    @State private var selectedID: UUID?
    @State private var working = false
    @State private var errorText: String?
    @State private var similarity = 0.72
    @State private var pendingApply: StudioSceneSuggestion?
    @State private var pendingGroupID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 19))
                    .frame(width: 36, height: 36)
                    .background(StudioPalette.selected, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scene Intelligence").font(.title3.weight(.semibold))
                    Text("Group related shots and discover film / print starting points")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding(15)
            Divider()
            HStack(spacing: 14) {
                // Name the *effect*, not an abstract strength. Higher tolerance merges more
                // dissimilar photos, which felt backwards when the control was
                // labelled "Grouping strength" and slid the wrong way.
                VStack(alignment: .leading, spacing: 1) {
                    Text("How different two photos can be and still group together")
                        .font(.caption2).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text("Separate").font(.caption2).foregroundStyle(.secondary)
                        Slider(value: $similarity, in: 0.45...1.10)
                            .frame(width: 150)
                        Text("Merge").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .help("Left separates aggressively into small groups. Right merges visually different frames. Groups also require close capture time (within 20 minutes) and the same session folder.")
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Analyze Thumbnails") { Task { await analyze() } }
                    .disabled(working || model.project.images.isEmpty)
            }
            .font(.callout)
            .padding(12)
            Divider()
            HSplitView {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(sets) { group in
                            Button { selectedID = group.id } label: {
                                HStack(spacing: 11) {
                                    if let image = photo(group.id) {
                                        LocalThumbnail(url: model.thumbnailURL(for: image), contentMode: .fit)
                                            .frame(width: 76, height: 56)
                                            .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 7))
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(group.label).font(.subheadline.weight(.medium))
                                        Text("\(group.count) photo\(group.count == 1 ? "" : "s") · " + group.topTags.prefix(2).joined(separator: ", "))
                                            .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer()
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(selectedID == group.id ? StudioPalette.selected : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 9))
                            }.buttonStyle(.plain)
                        }
                    }.padding(12)
                }
                .frame(minWidth: 245, idealWidth: 310)
                VStack(alignment: .leading, spacing: 0) {
                    if let group = sets.first(where: { $0.id == selectedID }) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(group.label).font(.title3.weight(.semibold))
                                        Text("\(group.count) related photos").foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Select Group") { selectGroup(group) }
                                }
                                Text(group.explanation).font(.callout).foregroundStyle(.secondary)
                                Text("Film & Print Recommendations")
                                    .font(.headline)
                                ForEach(Array(group.suggested.enumerated()), id: \.element.id) { index, suggestion in
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Text("\(index + 1). \(suggestion.filmName)")
                                                .font(.subheadline.weight(.semibold))
                                            Spacer()
                                            Text(suggestion.paperName)
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Text(suggestion.why).font(.caption).foregroundStyle(.secondary)
                                        HStack {
                                            Button("Try on One Photo") { trySuggestion(suggestion, group: group) }
                                            Button("Apply to Entire Set…") {
                                                pendingApply = suggestion
                                                pendingGroupID = group.id
                                            }
                                            .disabled(model.isExporting)
                                        }.controlSize(.small)
                                    }
                                    .padding(11)
                                    .background(StudioPalette.panel.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                                }
                                Label("Suggestions are starting points, not measured film matches. Review skin color, highlight response, and print density in the exact renderer before batch application.", systemImage: "info.circle")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(17)
                        }
                    } else if let errorText {
                        ContentUnavailableView("Analysis unavailable", systemImage: "exclamationmark.triangle",
                                               description: Text(errorText))
                    } else if working {
                        ContentUnavailableView("Analyzing your local previews", systemImage: "sparkles",
                                               description: Text("No RAW originals are uploaded or downloaded for this analysis."))
                    } else {
                        ContentUnavailableView("No scene groups yet", systemImage: "photo.stack",
                                               description: Text("Analyze local thumbnails to find related shots."))
                    }
                }
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Image(systemName: "lock.shield")
                Text("On-device Apple Vision · local previews only · no online model · originals untouched")
                Spacer()
                Text("\(sets.count) sets")
            }.font(.caption2).foregroundStyle(.secondary).padding(12)
        }
        .background(StudioPalette.canvas)
        .frame(minWidth: 830, minHeight: 590)
        .task { await analyze() }
        .confirmationDialog(
            "Apply film stock and print paper to this entire set?",
            isPresented: Binding(get: { pendingApply != nil }, set: { if !$0 { pendingApply = nil; pendingGroupID = nil } }),
            titleVisibility: .visible
        ) {
            Button("Apply Stock + Paper") {
                if let pendingApply, let group = sets.first(where: { $0.id == pendingGroupID }) {
                    applyToGroup(pendingApply, group: group)
                }
                pendingApply = nil
                pendingGroupID = nil
            }
            Button("Cancel", role: .cancel) { pendingApply = nil; pendingGroupID = nil }
        } message: {
            Text("Only stock and paper change; individual white balance, crop and tone settings remain. Batch changes are not a single-step Undo. Save a project copy first if you need a rollback.")
        }
    }

    private func photo(_ id: UUID) -> ProjectImageRecord? {
        model.project.images.first(where: { $0.id == id })
    }

    @MainActor private func analyze() async {
        guard !working else { return }
        working = true
        errorText = nil
        defer { working = false }
        let inputs = model.project.images.map { image in
            StudioSceneInput(id: image.id,
                             previewURL: model.thumbnailURL(for: image),
                             captureTime: image.captureDate ?? image.metadata?.captureDate ?? image.importedAt,
                             folder: image.logicalFolderPath ?? image.url.deletingLastPathComponent().path)
        }
        do {
            let results = try await StudioSceneIntelligence.shared.group(inputs, similarity: Float(similarity),
                films: BridgeCatalog.shared.films, papers: BridgeCatalog.shared.papers)
            guard !Task.isCancelled else { return }
            sets = results
            if !sets.contains(where: { $0.id == selectedID }) { selectedID = sets.first?.id }
            if sets.isEmpty { errorText = "No local thumbnails are ready. Generate previews in Library or Cull before analyzing." }
        } catch is CancellationError { }
        catch { errorText = error.localizedDescription }
    }

    private func selectGroup(_ group: StudioSceneSet) {
        guard let first = group.imageIDs.first else { return }
        model.clearLibrarySelection()
        model.selectLibraryImage(first)
        for id in group.imageIDs.dropFirst() { model.selectLibraryImage(id, additive: true) }
        model.showProjectHome = false
        model.page = .library
    }

    private func trySuggestion(_ suggestion: StudioSceneSuggestion, group: StudioSceneSet) {
        guard let first = group.imageIDs.first else { return }
        model.clearLibrarySelection()
        model.selectLibraryImage(first)
        model.setParameter("film", value: .int(Int32(suggestion.filmIndex)), interactive: false)
        model.setParameter("paper", value: .int(Int32(suggestion.paperIndex)), interactive: false)
        model.showProjectHome = false
        model.page = .edit
        dismiss()
    }

    private func applyToGroup(_ suggestion: StudioSceneSuggestion, group: StudioSceneSet) {
        guard let first = group.imageIDs.first else { return }
        // Preserve every other per-image setting; apply only native stock/paper IDs.
        model.clearLibrarySelection()
        model.selectLibraryImage(first)
        model.setParameter("film", value: .int(Int32(suggestion.filmIndex)), interactive: false)
        model.setParameter("paper", value: .int(Int32(suggestion.paperIndex)), interactive: false)
        let memberIDs = Set(group.imageIDs.dropFirst())
        for index in model.project.images.indices where memberIDs.contains(model.project.images[index].id) {
            model.project.images[index].look.values["film"] = .int(Int32(suggestion.filmIndex))
            model.project.images[index].look.values["paper"] = .int(Int32(suggestion.paperIndex))
        }
        selectGroup(group)
        model.status = "Applied \(suggestion.filmName) + \(suggestion.paperName) to \(group.count) shots"
        dismiss()
    }
}
