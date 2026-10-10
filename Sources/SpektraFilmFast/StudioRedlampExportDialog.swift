import SwiftUI
import AppKit

// Redlamp source audit: RedlampUI/Export/ExportSheet.swift and
// ExportSheetSections.swift @ 657beb41d148a8f66916123f961e612b95c1a047.
// The native grouped-form/preset/footer architecture is retained, while
// SpektraFilm adds the user-required large output preview and batch selection.
// This view does not implement a second renderer or export worker.
struct StudioRedlampExportDialog: View {
    @ObservedObject var model: AppModel
    let onClose: () -> Void
    @State private var choosePhotos = false
    @State private var showPresetName = false
    @State private var presetName = ""
    @AppStorage("SpektraFilmStudio.export.savedPresets.v1") private var savedPresetsData = Data()
    @State private var currentPreset: UUID?

    private var settings: Binding<ExportSettings> { $model.project.exportSettings }
    private var currentPhoto: ProjectImageRecord? {
        if let selected = model.selectedImage { return selected }
        return model.project.images.first(where: { $0.selectedForExport })
    }
    private var userPresets: [StudioExportUserPreset] {
        (try? JSONDecoder().decode([StudioExportUserPreset].self, from: savedPresetsData)) ?? []
    }
    private var blockReason: String? {
        let s = model.project.exportSettings
        if model.selectedExportCount < 1 { return "Choose photos to export" }
        if s.destinationPath.isEmpty { return "Choose an export folder" }
        if s.sequenceStart < 1 { return "Sequence must be positive" }
        if s.resizeMode == .longEdge && s.resizeLongEdge < 1 { return "Choose a valid long edge" }
        if (s.resizeMode == .width || s.resizeMode == .fitBox || s.resizeMode == .cropToFill) && s.resizeWidth < 1 {
            return "Choose a valid width"
        }
        if (s.resizeMode == .height || s.resizeMode == .fitBox || s.resizeMode == .cropToFill) && s.resizeHeight < 1 {
            return "Choose a valid height"
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 15, weight: .medium))
                Text("Export Photos")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Text("\(model.selectedExportCount) selected")
                    .foregroundStyle(.secondary)
                    .font(.caption.monospacedDigit())
                Button { choosePhotos = true } label: {
                    Label("Choose Photos", systemImage: "photo.stack")
                }
                .controlSize(.small)
                .disabled(model.isExporting)
                .popover(isPresented: $choosePhotos, arrowEdge: .bottom) {
                    StudioExportPhotoPicker(model: model)
                        .frame(width: 360, height: 480)
                        .studioOmniPane()
                }
            }
            .padding(.horizontal, 20).frame(height: 57)
            Divider()
            HStack(spacing: 0) {
                photoPreview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                settingsForm
                    .frame(width: 405).frame(maxHeight: .infinity)
            }
            Divider()
            if model.isExporting || (model.activeExportJob.map { $0.processedCount > 0 } ?? false) {
                queueProgress
                Divider()
            }
            HStack(spacing: 12) {
                if let problem = blockReason, !model.isExporting {
                    Label(problem, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                if model.isExporting {
                    Button("Stop Export") { model.stopExport() }
                        .disabled(model.isStoppingExport)
                } else {
                    Button("Export \(model.selectedExportCount) Photos") {
                        model.exportSelected()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(blockReason != nil)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 20).frame(height: 59)
        }
        .frame(width: 1060, height: 710)
        .background(StudioPalette.panel)
        .tint(.accentColor)
        .accessibilityIdentifier("studio.export.shared-modal")
        .alert("Save Export Preset", isPresented: $showPresetName) {
            TextField("Preset name", text: $presetName)
            Button("Save") { savePreset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Save the current file, size, naming, destination and metadata settings.")
        }
    }

    private var photoPreview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(currentPhoto?.fileName ?? "Select a photo")
                        .font(.subheadline.weight(.medium)).lineLimit(1)
                    Text("OUTPUT PREVIEW")
                        .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                }
                Spacer()
                if let currentPhoto {
                    Button("Edit") {
                        onClose()
                        model.focusPhoto(currentPhoto.id, destination: .edit)
                    }
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 18).frame(height: 53)
            Divider()
            Group {
                if let currentPhoto {
                    StudioExportPreview(model: model, image: currentPhoto)
                        .padding(18)
                } else {
                    ContentUnavailableView("No Photos Selected", systemImage: "photo", description: Text("Choose the photos to export."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(StudioPalette.recessed)
            Divider()
            HStack(spacing: 8) {
                Label(model.project.exportSettings.format.rawValue, systemImage: "doc")
                Text("·")
                Text(model.project.exportSettings.colorMode == .sRGB ? "sRGB" : "Match renderer")
                Text("·")
                Text(model.project.exportSettings.resizeMode.rawValue)
                Spacer()
            }
            .font(.caption2).foregroundStyle(.secondary)
            .padding(.horizontal, 18).frame(height: 35)
        }
        .accessibilityIdentifier("studio.export.preview")
    }

    private var settingsForm: some View {
        Form {
            Section {
                LabeledContent("Preset") {
                    Menu {
                        ForEach(ExportPresetCategory.allCases) { category in
                            Section(category.rawValue) {
                                ForEach(ExportPresetDefinition.all.filter { $0.category == category }) { p in
                                    Button(p.name) { model.applyExportPreset(p.id); currentPreset = nil }
                                }
                            }
                        }
                        if !userPresets.isEmpty {
                            Section("My Presets") {
                                ForEach(userPresets) { p in
                                    Button(p.name) {
                                        model.project.exportSettings = p.settings
                                        currentPreset = p.id
                                    }
                                }
                            }
                        }
                        Divider()
                        Button("Save as Preset…") { presetName = ""; showPresetName = true }
                        if let id = currentPreset {
                            Button("Update Current Preset") { updatePreset(id) }
                            Button("Delete Current Preset", role: .destructive) { deletePreset(id) }
                        }
                    } label: {
                        Text(currentPreset.flatMap { id in userPresets.first(where: { $0.id == id })?.name } ?? "Custom")
                    }
                    .fixedSize()
                }
            }
            Section("Location") {
                LabeledContent("Export to") {
                    HStack(spacing: 8) {
                        Text(model.project.exportSettings.destinationPath.isEmpty
                             ? "Choose folder" : URL(fileURLWithPath: model.project.exportSettings.destinationPath).lastPathComponent)
                            .lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { model.chooseExportDestination() }
                            .controlSize(.small)
                    }
                }
                TextField("File name", text: settings.filenameTemplate)
                Stepper("Sequence starts at \(model.project.exportSettings.sequenceStart)",
                        value: settings.sequenceStart, in: 1...999999)
            }
            Section("File") {
                Picker("Format", selection: settings.format) {
                    ForEach(ExportFormat.allCases) { format in Text(format.rawValue).tag(format) }
                }
                if model.project.exportSettings.format != .tiff {
                    LabeledContent("Quality") {
                        HStack(spacing: 9) {
                            Slider(value: settings.jpegQuality, in: 0.1...1.0)
                                .controlSize(.small)
                            Text("\(Int((model.project.exportSettings.jpegQuality * 100).rounded()))")
                                .frame(width: 32, alignment: .trailing)
                                .monospacedDigit()
                        }
                    }
                } else {
                    Toggle("16-bit TIFF", isOn: settings.tiff16Bit)
                }
                Picker("Color space", selection: settings.colorMode) {
                    ForEach(ExportColorMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
            }
            Section("Size") {
                Picker("Resize", selection: settings.resizeMode) {
                    ForEach(ExportResizeMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                switch model.project.exportSettings.resizeMode {
                case .none: EmptyView()
                case .longEdge: dimensionField("Long edge", value: settings.resizeLongEdge)
                case .width: dimensionField("Width", value: settings.resizeWidth)
                case .height: dimensionField("Height", value: settings.resizeHeight)
                case .fitBox, .cropToFill:
                    dimensionField("Width", value: settings.resizeWidth)
                    dimensionField("Height", value: settings.resizeHeight)
                }
                if model.project.exportSettings.resizeMode != .none {
                    Toggle("Never enlarge", isOn: settings.dontEnlarge)
                }
            }
            Section("Metadata") {
                Toggle("Include original metadata", isOn: settings.preserveMetadata)
                if model.project.exportSettings.preserveMetadata {
                    Toggle("Remove GPS location", isOn: settings.stripGPS)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.isExporting)
        .accessibilityIdentifier("studio.export.settings")
    }

    private func dimensionField(_ title: String, value: Binding<Int>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 5) {
                TextField(title, value: value, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 76)
                Text("px").foregroundStyle(.secondary)
            }
        }
    }

    private var queueProgress: some View {
        HStack(spacing: 12) {
            if let job = model.activeExportJob {
                ProgressView(value: job.fractionComplete)
                    .frame(width: 170)
                Text("\(job.completedCount) of \(job.items.count) exported")
                if job.failedCount > 0 { Text("\(job.failedCount) failed").foregroundStyle(.orange) }
                Spacer()
                if !model.isExporting && job.remainingCount > 0 {
                    Button("Resume") { model.resumeExport() }
                        .disabled(model.exportQueueSettingsDiffer)
                    if job.failedCount > 0 {
                        Button("Retry Failed") { model.retryFailedExports() }
                            .disabled(model.exportQueueSettingsDiffer)
                    }
                }
            }
        }
        .font(.caption).padding(.horizontal, 20).frame(height: 39)
    }

    private func savePreset() {
        let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var values = userPresets
        let new = StudioExportUserPreset(id: UUID(), name: name, settings: model.project.exportSettings)
        values.append(new)
        if let data = try? JSONEncoder().encode(values) { savedPresetsData = data; currentPreset = new.id }
    }
    private func updatePreset(_ id: UUID) {
        var values = userPresets
        guard let index = values.firstIndex(where: { $0.id == id }) else { return }
        values[index].settings = model.project.exportSettings
        if let data = try? JSONEncoder().encode(values) { savedPresetsData = data }
    }
    private func deletePreset(_ id: UUID) {
        let values = userPresets.filter { $0.id != id }
        if let data = try? JSONEncoder().encode(values) { savedPresetsData = data; currentPreset = nil }
    }
}

private struct StudioExportPhotoPicker: View {
    @ObservedObject var model: AppModel
    @State private var search = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Export Selection").font(.headline)
                Spacer()
                Menu("Select") {
                    Button("Current Photo") {
                        if let photo = model.selectedImage {
                            model.setAllExportSelection(false)
                            model.toggleExportSelection(photo.id)
                        }
                    }
                    Button("Picked") { model.selectExportPicksOnly() }
                    Button("Client Picks") { model.selectExportClientPicksOnly() }
                    Button("4 Stars and Up") { model.selectExportRating(atLeast: 4) }
                    Button("All") { model.setAllExportSelection(true) }
                    Button("None") { model.setAllExportSelection(false) }
                }
                .disabled(model.isExporting)
            }.padding(14)
            TextField("Search photos", text: $search)
                .textFieldStyle(.roundedBorder).padding(.horizontal, 14)
            List {
                ForEach(model.project.images.filter { search.isEmpty || $0.fileName.localizedCaseInsensitiveContains(search) }) { photo in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { model.project.images.first(where: { $0.id == photo.id })?.selectedForExport ?? false },
                            set: { _ in model.toggleExportSelection(photo.id) }
                        )).labelsHidden().disabled(model.isExporting)
                        LocalThumbnail(url: model.thumbnailURL(for: photo), contentMode: .fit)
                            .frame(width: 50, height: 39)
                        Button(photo.fileName) { model.selectLibraryImage(photo.id) }
                            .buttonStyle(.plain)
                            .lineLimit(1)
                        Spacer()
                    }
                }
            }
        }
    }
}
