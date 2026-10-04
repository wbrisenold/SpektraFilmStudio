import SwiftUI

struct ExportWorkspaceView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HSplitView {
            List {
                ForEach(model.project.images) { image in
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(
                            get: { image.selectedForExport },
                            set: { _ in model.toggleExportSelection(image.id) }
                        ))
                        .labelsHidden()
                        LocalThumbnail(url: image.url).frame(width: 72, height: 48)
                        VStack(alignment: .leading) {
                            Text(image.fileName).lineLimit(1)
                            Text("\(image.rating) stars · \(image.flag.label)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(minWidth: 330)

            Form {
                Section("Export Presets") {
                    ForEach(ExportPresetCategory.allCases) { category in
                        Menu(category.rawValue) {
                            ForEach(ExportPresetDefinition.all.filter { $0.category == category }) { preset in
                                Button {
                                    model.applyExportPreset(preset.id)
                                } label: {
                                    VStack(alignment: .leading) {
                                        Text(preset.name)
                                        Text(preset.detail)
                                    }
                                }
                            }
                        }
                    }
                    Text("Social presets preserve the photo's aspect ratio. For exact platform dimensions, use the matching Crop preset first. Presets never enlarge a smaller image by default.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Format") {
                    Picker("Format", selection: $model.project.exportSettings.format) {
                        ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if model.project.exportSettings.format == .jpeg || model.project.exportSettings.format == .heic {
                        LabeledContent("Quality") {
                            HStack {
                                Slider(value: $model.project.exportSettings.jpegQuality, in: 0.1...1)
                                    .help("Controls JPEG/HEIC compression. Move left for smaller files with more compression; move right for larger files with more detail. Around 90–95% is a strong final-delivery range.")
                                Button { model.project.exportSettings.jpegQuality = 0.92 } label: {
                                    Image(systemName: "arrow.counterclockwise")
                                        .font(.system(size: 9, weight: .medium))
                                }
                                .buttonStyle(.plain)
                                .help("Reset export quality to 92%.")
                                Text(model.project.exportSettings.jpegQuality, format: .percent.precision(.fractionLength(0)))
                                    .monospacedDigit()
                                    .frame(width: 44)
                            }
                        }
                    }
                    if model.project.exportSettings.format == .tiff {
                        Toggle("16-bit TIFF", isOn: $model.project.exportSettings.tiff16Bit)
                        Text(model.project.exportSettings.tiff16Bit
                             ? "Writes and verifies a real 16-bit-per-channel TIFF."
                             : "Writes an 8-bit TIFF.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Preserve metadata", isOn: $model.project.exportSettings.preserveMetadata)
                    if model.project.exportSettings.preserveMetadata {
                        Toggle("Strip GPS location", isOn: $model.project.exportSettings.stripGPS)
                            .help("Keeps normal metadata such as camera and copyright information, but removes embedded GPS coordinates from exported files.")
                    }
                    Text("Viewer diagnostics (Clipping and Skin Check) are never included in exported files.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Resize") {
                    Picker("Resize", selection: $model.project.exportSettings.resizeMode) {
                        ForEach(ExportResizeMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }

                    switch model.project.exportSettings.resizeMode {
                    case .none:
                        Text("Exports the full rendered pixel dimensions.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .longEdge:
                        Stepper("Long edge: \(model.project.exportSettings.resizeLongEdge) px", value: $model.project.exportSettings.resizeLongEdge, in: 64...20000, step: 64)
                    case .width:
                        Stepper("Width: \(model.project.exportSettings.resizeWidth) px", value: $model.project.exportSettings.resizeWidth, in: 64...20000, step: 64)
                    case .height:
                        Stepper("Height: \(model.project.exportSettings.resizeHeight) px", value: $model.project.exportSettings.resizeHeight, in: 64...20000, step: 64)
                    case .fitBox:
                        Stepper("Max width: \(model.project.exportSettings.resizeWidth) px", value: $model.project.exportSettings.resizeWidth, in: 64...20000, step: 64)
                        Stepper("Max height: \(model.project.exportSettings.resizeHeight) px", value: $model.project.exportSettings.resizeHeight, in: 64...20000, step: 64)
                        Text("Fits the current crop inside this box without stretching it. If the crop aspect matches the preset, the output lands at the exact target dimensions.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    if model.project.exportSettings.resizeMode != .none {
                        Toggle("Don't enlarge smaller images", isOn: $model.project.exportSettings.dontEnlarge)
                    }
                }

                Section("Naming") {
                    TextField("Filename template", text: $model.project.exportSettings.filenameTemplate)
                    Text("Tokens: {name}, {sequence}").font(.caption).foregroundStyle(.secondary)
                    Stepper("Sequence start: \(model.project.exportSettings.sequenceStart)", value: $model.project.exportSettings.sequenceStart, in: 0...999999)
                }

                Section("Destination") {
                    HStack {
                        Text(model.project.exportSettings.destinationPath.isEmpty ? "Not selected" : model.project.exportSettings.destinationPath)
                            .lineLimit(2)
                        Spacer()
                        Button("Choose…") { model.chooseExportDestination() }
                    }
                }

                if model.isExporting {
                    Section("Progress") {
                        ProgressView(value: model.exportProgress)
                        Text("Every file is encoded to a temporary file, decoded back for verification, then moved into the destination.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !model.exportFailures.isEmpty {
                    Section("Export Report") {
                        ForEach(Array(model.exportFailures.enumerated()), id: \.offset) { _, failure in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(failure.fileName).font(.caption.weight(.semibold))
                                Text(failure.message).font(.caption2).foregroundStyle(.red)
                            }
                        }
                    }
                }

                Section {
                    Button {
                        model.exportSelected()
                    } label: {
                        HStack {
                            if model.isExporting { ProgressView().controlSize(.small) }
                            Text(model.isExporting ? "Exporting…" : "Export Selected")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isExporting)
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 380, idealWidth: 450)
        }
    }
}
