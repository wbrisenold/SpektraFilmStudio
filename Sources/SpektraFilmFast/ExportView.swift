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
                        .disabled(model.isExporting)

                        LocalThumbnail(url: image.url).frame(width: 72, height: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(image.fileName).lineLimit(1)
                            Text("\(image.rating) stars · \(image.flag.label)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(minWidth: 330)

            VStack(spacing: 0) {
                Form {
                    if let job = model.activeExportJob,
                       !model.isExporting,
                       job.state != .completed,
                       job.remainingCount > 0 {
                        Section("Recovery") {
                            Label(
                                "\(job.completedCount) finished · \(job.remainingCount) remaining",
                                systemImage: "arrow.clockwise.circle.fill"
                            )
                            HStack {
                                Button("Resume Export") { model.resumeExport() }
                                    .buttonStyle(.borderedProminent)
                                Button("Discard Recovery") { model.discardRecoveredExportJob() }
                            }
                        }
                    }

                    Section("Destination") {
                        HStack {
                            Text(model.project.exportSettings.destinationPath.isEmpty
                                 ? "Not selected"
                                 : model.project.exportSettings.destinationPath)
                                .lineLimit(2)
                            Spacer()
                            Button("Choose…") { model.chooseExportDestination() }
                                .disabled(model.isExporting)
                        }
                    }

                    Section("Naming") {
                        TextField("Filename template", text: $model.project.exportSettings.filenameTemplate)
                            .disabled(model.isExporting)
                        Text("Tokens: {name}, {original_filename}, {sequence}")
                            .font(.caption).foregroundStyle(.secondary)
                        if model.selectedExportCount > 1,
                           !model.project.exportSettings.filenameTemplate.contains("{name}"),
                           !model.project.exportSettings.filenameTemplate.contains("{original_filename}"),
                           !model.project.exportSettings.filenameTemplate.contains("{sequence}") {
                            Label(
                                "Static titles are automatically numbered. They can never collapse a batch into one file.",
                                systemImage: "checkmark.shield"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        let names = model.exportPreflightNames
                        if !names.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Preflight").font(.caption.weight(.semibold))
                                ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                                    Text(name).font(.caption2.monospaced()).lineLimit(1)
                                }
                            }
                        }
                        Stepper(
                            "Sequence start: \(model.project.exportSettings.sequenceStart)",
                            value: $model.project.exportSettings.sequenceStart,
                            in: 0...999999
                        )
                        .disabled(model.isExporting)
                    }

                    Section("Format") {
                        Picker("Format", selection: $model.project.exportSettings.format) {
                            ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .disabled(model.isExporting)

                        if model.project.exportSettings.format == .jpeg || model.project.exportSettings.format == .heic {
                            LabeledContent("Quality") {
                                Slider(value: $model.project.exportSettings.jpegQuality, in: 0.1...1)
                            }
                        }
                        if model.project.exportSettings.format == .tiff {
                            Toggle("16-bit TIFF", isOn: $model.project.exportSettings.tiff16Bit)
                        }
                        Toggle("Preserve metadata", isOn: $model.project.exportSettings.preserveMetadata)
                        if model.project.exportSettings.preserveMetadata {
                            Toggle("Strip GPS location", isOn: $model.project.exportSettings.stripGPS)
                        }

                        Menu("Apply preset") {
                            ForEach(ExportPresetCategory.allCases) { category in
                                Menu(category.rawValue) {
                                    ForEach(ExportPresetDefinition.all.filter { $0.category == category }) { preset in
                                        Button(preset.name) { model.applyExportPreset(preset.id) }
                                    }
                                }
                            }
                        }
                    }
                    .disabled(model.isExporting)

                    Section("Resize") {
                        Picker("Resize", selection: $model.project.exportSettings.resizeMode) {
                            ForEach(ExportResizeMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        switch model.project.exportSettings.resizeMode {
                        case .none:
                            Text("Full rendered dimensions").font(.caption).foregroundStyle(.secondary)
                        case .longEdge:
                            Stepper("Long edge: \(model.project.exportSettings.resizeLongEdge) px",
                                    value: $model.project.exportSettings.resizeLongEdge,
                                    in: 64...20000, step: 64)
                        case .width:
                            Stepper("Width: \(model.project.exportSettings.resizeWidth) px",
                                    value: $model.project.exportSettings.resizeWidth,
                                    in: 64...20000, step: 64)
                        case .height:
                            Stepper("Height: \(model.project.exportSettings.resizeHeight) px",
                                    value: $model.project.exportSettings.resizeHeight,
                                    in: 64...20000, step: 64)
                        case .fitBox:
                            Stepper("Max width: \(model.project.exportSettings.resizeWidth) px",
                                    value: $model.project.exportSettings.resizeWidth,
                                    in: 64...20000, step: 64)
                            Stepper("Max height: \(model.project.exportSettings.resizeHeight) px",
                                    value: $model.project.exportSettings.resizeHeight,
                                    in: 64...20000, step: 64)
                        }
                        if model.project.exportSettings.resizeMode != .none {
                            Toggle("Don't enlarge smaller images", isOn: $model.project.exportSettings.dontEnlarge)
                        }
                    }
                    .disabled(model.isExporting)

                    if let job = model.activeExportJob {
                        Section("Export Queue") {
                            ProgressView(value: job.fractionComplete)
                            HStack {
                                Text("\(job.completedCount) / \(job.items.count) complete")
                                if job.failedCount > 0 {
                                    Text("· \(job.failedCount) failed").foregroundStyle(.red)
                                }
                                Spacer()
                                if job.failedCount > 0 && !model.isExporting {
                                    Button("Retry Failed") { model.retryFailedExports() }
                                }
                            }
                            .font(.caption)

                            ForEach(job.items.prefix(10)) { item in
                                HStack(spacing: 8) {
                                    Image(systemName: item.state.systemImage)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.sourceFileName).font(.caption).lineLimit(1)
                                        Text(URL(fileURLWithPath: item.destinationPath).lastPathComponent)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        if let error = item.errorMessage {
                                            Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
                                        }
                                    }
                                    Spacer()
                                    Text(item.state.label).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .formStyle(.grouped)

                Divider()

                HStack(spacing: 12) {
                    if model.isExporting {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.isStoppingExport ? "Stopping…" : "Exporting")
                                .font(.headline)
                            Text(model.exportCurrentFileName)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        ProgressView(value: model.exportProgress).frame(width: 140)
                        Button(role: .destructive) {
                            model.stopExport()
                        } label: {
                            Label(model.isStoppingExport ? "Stopping…" : "Stop Export", systemImage: "stop.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isStoppingExport)
                    } else {
                        Text("\(model.selectedExportCount) photo\(model.selectedExportCount == 1 ? "" : "s") ready")
                            .font(.headline)
                        Spacer()
                        Button {
                            model.exportSelected()
                        } label: {
                            Label(
                                "Export \(model.selectedExportCount) Photo\(model.selectedExportCount == 1 ? "" : "s")",
                                systemImage: "square.and.arrow.up"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            model.selectedExportCount == 0 ||
                            model.project.exportSettings.destinationPath.isEmpty
                        )
                    }
                }
                .padding(14)
                .background(.regularMaterial)
            }
            .frame(minWidth: 460)
        }
    }
}
