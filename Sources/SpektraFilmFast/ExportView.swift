import SwiftUI
import AppKit

struct ExportWorkspaceView: View {
    @ObservedObject var model: AppModel
    // The legacy workspace remains solely for source compatibility.
    // The production entry points all use the same modal presentation.
    let isDialog: Bool
    let onClose: (() -> Void)?
    init(model: AppModel, isDialog: Bool = false, onClose: (() -> Void)? = nil) {
        self.model = model
        self.isDialog = isDialog
        self.onClose = onClose
    }
    @State private var dialogPhotosOpen = false
    @State private var sourceFilter: ExportSourceFilter = .all
    @State private var search = ""
    // Redlamp-inspired native three-pane layout: no blocking settings sheet.
    @AppStorage("SpektraFilmStudio.designA.v3.showExportBrowser") private var showExportBrowser = false
    @AppStorage("SpektraFilmStudio.export.showInspector.v1") private var showExportInspector = true
    @AppStorage("SpektraFilmStudio.export.savedPresets.v1") private var savedPresetsData = Data()
    @State private var selectedCustomPreset: UUID?
    @State private var showingSavePreset = false
    @State private var presetName = ""

    var body: some View {
        Group {
            if isDialog {
                exportDialog
            } else {
                VStack(spacing: 0) {
                    workspaceHeader
            // "Build Set" (What) then "Settings" (How) is the only ordering that
            // makes sense. Photos/Settings used to sit in that order and read as
            // if the browser changed the output settings.
            Divider()
            HSplitView {
                if showExportBrowser {
                    sourceBrowser.frame(minWidth: StudioLayout.presetSidebarWidth, idealWidth: StudioLayout.presetSidebarWidth, maxWidth: 380)
                        .padding(StudioLayout.paneInset).studioGlassPane()
                }
                previewAndQueue.frame(minWidth: 420)
                if showExportInspector {
                    inspector.frame(minWidth: StudioLayout.editorInspectorWidth, idealWidth: StudioLayout.editorInspectorWidth, maxWidth: 440)
                        .padding(StudioLayout.paneInset).studioGlassPane()
                }
            }
            Divider()
            // Progress only. The footer used to restate the photo count, format and
            // size that the preview already showed, then repeat the same two buttons
            // — a whole bar of duplication. When idle it collapses to nothing.
            if model.isExporting || model.activeExportJob != nil {
                actionFooter
            }
                }
            }
        }
        .background(StudioPalette.canvas)
        .alert("Save Export Preset", isPresented: $showingSavePreset) {
            TextField("Preset name", text: $presetName)
            Button("Save") { saveCustomPreset() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Save the current format, size, color, naming, metadata and destination settings.")
        }
    }

    // RedlampUI/Export/ExportSheet.swift @ 657beb41: grouped native form,
    // one preset selector, one fixed action row. Larger left preview is the
    // SpektraFilm extension; no old workspace/queue embedded in the modal.
    private var exportDialog: some View {
        StudioRedlampExportDialog(model: model) { onClose?() }
    }

    // Kept for existing documentation and UI smoke-test callers.
    var documentationSettings: some View { inspector.frame(width: 400, height: 720) }

    private var workspaceHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.and.arrow.up.on.square")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 38, height: 38)
                .background(StudioPalette.selected, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text("Export Studio").font(.title3.weight(.semibold))
                Text("Prepare, preview and deliver your photos")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text("\(model.selectedExportCount) selected")
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
            Menu {
                Button("All Photos") { model.setAllExportSelection(true) }
                Button("Picked Photos") { model.selectExportPicksOnly() }
                Button("Client Picks") { model.selectExportClientPicksOnly() }
                Button("4 Stars and Up") { model.selectExportRating(atLeast: 4) }
                Button("Highlighted in Library") {
                    model.setAllExportSelection(false)
                    model.batchSetExportSelection(true)
                }
                Divider()
                Button("Clear Selection") { model.setAllExportSelection(false) }
            } label: {
                Label("Build Set", systemImage: "checklist")
            }
            .disabled(model.isExporting)
            Button {
                showExportBrowser.toggle()
            } label: {
                Label("Photos", systemImage: "photo.on.rectangle.angled")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(showExportBrowser ? "Hide photo browser" : "Show photo browser")
            Button {
                showExportInspector.toggle()
            } label: {
                Label("Settings", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(showExportInspector ? "Hide export settings" : "Show export settings")
            exportActions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(StudioPalette.panel)
    }

    /// The deliver action lives in the header. It used to sit in a full-width
    /// footer bar under a three-pane workspace, which permanently stole vertical
    /// room from the preview for controls that are also reachable elsewhere.
    @ViewBuilder
    private var exportActions: some View {
        if model.isExporting {
            Button(role: .destructive) { model.stopExport() } label: {
                Label(model.isStoppingExport ? "Stopping…" : "Stop Export", systemImage: "stop.fill")
            }
            .disabled(model.isStoppingExport)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        } else {
            if model.project.exportSettings.destinationPath.isEmpty {
                Button("Choose Folder…") { requestExportFolder() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Button {
                model.exportSelected()
            } label: {
                Label("Export \(model.selectedExportCount) Photos", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
            .disabled(exportBlockingReason != nil)
            .help(exportBlockingReason ?? "Deliver the selected photos using the current settings")
        }
    }

    private var sourceBrowser: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("EXPORT SET")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("\(model.selectedExportCount) queued").font(.headline)
                    }
                    Spacer()
                    Menu {
                        Button("All Photos") { model.setAllExportSelection(true) }
                        Button("None") { model.setAllExportSelection(false) }
                        Divider()
                        Button("Picks Only") { model.selectExportPicksOnly() }
                        Button("Client Picks Only") { model.selectExportClientPicksOnly() }
                        Button("4 Stars & Up") { model.selectExportRating(atLeast: 4) }
                        Button("5 Stars Only") { model.selectExportRating(atLeast: 5) }
                    } label: {
                        Label("Build Set", systemImage: "checklist")
                    }
                    .controlSize(.small)
                    .disabled(model.isExporting)
                }

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Filter photos", text: $search)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background(StudioPalette.recessed, in: RoundedRectangle(cornerRadius: 7))

                Picker("Show photos", selection: $sourceFilter) {
                    ForEach(ExportSourceFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
            }
            .padding(11)
            .background(StudioPalette.panel)

            Divider()

            List {
                ForEach(filteredImages) { image in
                    HStack(spacing: 9) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { image.selectedForExport },
                                set: { _ in model.toggleExportSelection(image.id) }
                            )
                        )
                        .labelsHidden()
                        .disabled(model.isExporting)

                        LocalThumbnail(url: model.thumbnailURL(for: image), contentMode: .fit)
                            .frame(width: 66, height: 48)
                            .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(image.fileName).lineLimit(1)
                            HStack(spacing: 5) {
                                if image.rating > 0 { Text("\(image.rating)★") }
                                Text(image.flag.label)
                                if image.clientPicked { Image(systemName: "heart.fill") }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }

                        Spacer()
                        if image.selectedForExport {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if model.isCropToolActive {
                            model.beginExportCrop(image.id)
                        } else {
                            model.selectLibraryImage(image.id)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var filteredImages: [ProjectImageRecord] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.project.images.filter { image in
            let categoryMatch: Bool
            switch sourceFilter {
            case .all: categoryMatch = true
            case .queued: categoryMatch = image.selectedForExport
            case .picks: categoryMatch = image.flag == .picked
            case .client: categoryMatch = image.clientPicked
            case .rated: categoryMatch = image.rating >= 4
            case .rejected: categoryMatch = image.flag == .rejected
            }
            return categoryMatch &&
                (needle.isEmpty || image.fileName.localizedCaseInsensitiveContains(needle))
        }
    }

    private var previewAndQueue: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("LIVE DELIVERY PREVIEW")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(previewImage?.fileName ?? "Choose a photo")
                        .font(.headline).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if let image = previewImage {
                    Button {
                        if model.isCropToolActive {
                            model.finishExportCrop()
                        } else {
                            model.beginExportCrop(image.id)
                        }
                    } label: {
                        Label(model.isCropToolActive ? "Done Crop" : "Crop Photo", systemImage: "crop.rotate")
                    }
                    .disabled(model.isExporting)
                    Button {
                        if isDialog { onClose?() }
                        model.focusPhoto(image.id, destination: .edit)
                    } label: {
                        Label("Edit", systemImage: "slider.horizontal.3")
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(StudioPalette.panel)

            Divider()

            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11).fill(Color.black.opacity(0.92))
                    if let image = previewImage {
                        if model.isCropToolActive,
                           model.project.selectedImageID == image.id {
                            PreviewView(model: model)
                                .padding(4)
                        } else {
                            StudioExportPreview(model: model, image: image)
                                .padding(12)
                        }

                    } else {
                        ContentUnavailableView(
                            "No Export Preview",
                            systemImage: "photo.on.rectangle",
                            description: Text("Queue or select a photo.")
                        )
                    }
                }
                .frame(minHeight: 320)
                .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
                .overlay {
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(StudioPalette.subtleBorder, lineWidth: 0.5)
                }

                HStack(spacing: 8) {
                    summaryCell("Photos", "\(model.selectedExportCount)", "photo.stack")
                    summaryCell("Format", formatSummary, "doc.richtext")
                    summaryCell("Size", outputSizeSummary, "aspectratio")
                    summaryCell("Color", colorSummary, "paintpalette")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(StudioPalette.recessed)

            Divider()
            if model.activeExportJob != nil {
                queuePanel.frame(minHeight: 185, idealHeight: 225, maxHeight: 300)
            }
        }
    }

    private var queuePanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("QUEUE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let job = model.activeExportJob {
                    Text("· \(job.completedCount) done")
                        .font(.caption2).foregroundStyle(.secondary)
                    if let seconds = job.estimatedRemainingSeconds {
                        Text("· ETA \(Self.duration(seconds))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if let bytes = job.estimatedTotalOutputBytes {
                        Text("· ~\(Self.byteCount(bytes))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let job = model.activeExportJob, !model.isExporting, job.remainingCount > 0 {
                    Button("Resume") { model.resumeExport() }.controlSize(.small)
                        .disabled(model.exportQueueSettingsDiffer)
                    if job.failedCount > 0 {
                        Button("Retry Failed") { model.retryFailedExports() }.controlSize(.small)
                            .disabled(model.exportQueueSettingsDiffer)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(StudioPalette.panel)

            if model.exportQueueSettingsDiffer, let job = model.activeExportJob, job.remainingCount > 0 {
                Text("This queue uses saved settings. Use Export… to start a new queue with the settings shown now.")
                    .font(.caption).foregroundStyle(.orange)
                    .padding(.horizontal, 12).padding(.vertical, 6)
            }

            Divider()

            if let job = model.activeExportJob {
                List(job.items) { item in
                    HStack(spacing: 9) {
                        Image(systemName: item.state.systemImage)
                            .frame(width: 18)
                            .foregroundStyle(item.state == .failed ? Color.red : Color.secondary)
                        Text(item.sourceFileName).lineLimit(1)
                        Spacer()
                        Text(item.state.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.inset)
            } else {
                VStack(spacing: 5) {
                    Text("Queue is empty").font(.caption).foregroundStyle(.secondary)
                    Text("Use Select Photos above, choose a destination, then export.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(StudioPalette.panel)
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            inspectorHeader
            Divider()
            StudioExportSectionLayout(disabled: model.isExporting) {
                destinationControls
                namingControls
            } file: {
                fileControls
                deliveryControls
            } size: {
                sizeControls
            } metadata: {
                metadataControls
            }
        }
        .background(StudioPalette.panel)
    }

    private var inspectorHeader: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("DELIVERY SETTINGS")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(selectedPresetTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                Spacer()
                presetMenu
            }
            HStack(spacing: 6) {
                presetShortcut("High Quality", id: "rapidraw-hq")
                presetShortcut("Fast Web", id: "rapidraw-web")
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
    }

    private var presetMenu: some View {
        Menu {
            ForEach(ExportPresetCategory.allCases) { category in
                Menu(category.rawValue) {
                    ForEach(ExportPresetDefinition.all.filter { $0.category == category }) { preset in
                        Button(preset.name) {
                            model.applyExportPreset(preset.id)
                            selectedCustomPreset = nil
                        }
                    }
                }
            }
            if !savedPresets.isEmpty {
                Divider()
                Menu("My Presets") {
                    ForEach(savedPresets) { preset in
                        Button(preset.name) {
                            model.project.exportSettings = preset.settings
                            selectedCustomPreset = preset.id
                        }
                    }
                }
            }
            Divider()
            Button("Save Current as Preset…") {
                presetName = ""
                showingSavePreset = true
            }
            if let id = selectedCustomPreset,
               let preset = savedPresets.first(where: { $0.id == id }) {
                Button("Update \(preset.name)") { updateCustomPreset(id) }
                Button("Delete \(preset.name)", role: .destructive) { deleteCustomPreset(id) }
            }
        } label: {
            Label("Presets", systemImage: "square.stack.3d.up")
        }
        .controlSize(.small)
        .disabled(model.isExporting)
    }

    private func presetShortcut(_ title: String, id: String) -> some View {
        Button(title) {
            if let preset = ExportPresetDefinition.preset(id: id) {
                model.applyExportPreset(preset.id)
                selectedCustomPreset = nil
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
    }

    private var deliveryControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("Color delivery")
            Picker("Color delivery", selection: $model.project.exportSettings.colorMode) {
                ForEach(ExportColorMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            Text(
                model.project.exportSettings.colorMode == .sRGB
                    ? "Actual sRGB pixels for web, phone, messaging, and social delivery."
                    : "Preserve the renderer output for controlled color-managed workflows."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var fileControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                fieldLabel("Format")
                Spacer()
                Picker("Format", selection: $model.project.exportSettings.format) {
                    ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 145)
            }

            if model.project.exportSettings.format == .jpeg ||
               model.project.exportSettings.format == .heic {
                HStack {
                    fieldLabel("Quality")
                    Spacer()
                    Text("\(Int((model.project.exportSettings.jpegQuality * 100).rounded()))")
                        .font(.caption.monospacedDigit())
                }
                Slider(value: $model.project.exportSettings.jpegQuality, in: 0.1...1)
            }

            // Redlamp keeps bit depth in the SAME section as format and quality.
            HStack {
                fieldLabel("Bit depth")
                Spacer()
                if model.project.exportSettings.format == .tiff {
                    Toggle("16-bit", isOn: $model.project.exportSettings.tiff16Bit)
                        .toggleStyle(.switch).controlSize(.mini)
                } else {
                    Text("8-bit").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var sizeControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Resize", selection: $model.project.exportSettings.resizeMode) {
                Text("Full Size").tag(ExportResizeMode.none)
                Text("Long Edge").tag(ExportResizeMode.longEdge)
                Section("Target Size") {
                    Text("Fit Whole Photo · No Crop").tag(ExportResizeMode.fitBox)
                    Text("Fill Target · Crop Edges").tag(ExportResizeMode.cropToFill)
                }
                Section("Advanced") {
                    Text("Width Only").tag(ExportResizeMode.width)
                    Text("Height Only").tag(ExportResizeMode.height)
                }
            }

            switch model.project.exportSettings.resizeMode {
            case .none:
                Text("Keep the rendered photo's full pixel dimensions and framing.")
                    .font(.caption2).foregroundStyle(.secondary)
            case .longEdge:
                numericField("Long edge", value: $model.project.exportSettings.resizeLongEdge)
                Text("Aspect ratio stays unchanged. No crop.")
                    .font(.caption2).foregroundStyle(.secondary)
            case .width:
                numericField("Width", value: $model.project.exportSettings.resizeWidth)
                Text("Height follows the photo automatically. No crop.")
                    .font(.caption2).foregroundStyle(.secondary)
            case .height:
                numericField("Height", value: $model.project.exportSettings.resizeHeight)
                Text("Width follows the photo automatically. No crop.")
                    .font(.caption2).foregroundStyle(.secondary)
            case .fitBox, .cropToFill:
                numericField("Target width", value: $model.project.exportSettings.resizeWidth)
                numericField("Target height", value: $model.project.exportSettings.resizeHeight)
                if model.project.exportSettings.resizeMode == .fitBox {
                    Label("Fit keeps the whole photo. The target is a maximum box; no padding is exported.", systemImage: "arrow.down.right.and.arrow.up.left")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Label("Fill never stretches the photo. It center-crops edges until the target aspect is filled.", systemImage: "crop")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }

            if model.project.exportSettings.resizeMode != .none {
                Toggle("Don't enlarge smaller photos", isOn: $model.project.exportSettings.dontEnlarge)
            }

            Divider()
            HStack {
                fieldLabel("Platform target")
                Spacer()
                Text("sets size · defaults to Fit")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(ExportPresetDefinition.all.filter { $0.category == .social }) { preset in
                    Button(preset.name) { model.applyExportPreset(preset.id) }
                        .controlSize(.small)
                        .lineLimit(1)
                }
            }
        }
    }

    private var namingControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            fieldLabel("Quick pattern")
            HStack(spacing: 5) {
                quickName("Source", "{name}")
                quickName("Source + SF", "{name}_spektrafilm")
                quickName("Sequence", "Export_{sequence}")
            }

            TextField("Filename pattern", text: $model.project.exportSettings.filenameTemplate)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            HStack(spacing: 5) {
                fieldLabel("Insert field")
                Spacer()
                token("{name}")
                token("{sequence}")
                token("{original_filename}")
            }

            Stepper(
                "Sequence starts at \(model.project.exportSettings.sequenceStart)",
                value: $model.project.exportSettings.sequenceStart,
                in: 0...999999
            )

            if !model.exportPreflightNames.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    fieldLabel("Examples")
                    ForEach(
                        Array(model.exportPreflightNames.prefix(3).enumerated()),
                        id: \.offset
                    ) { _, name in
                        Text(name).font(.caption.monospaced()).lineLimit(1)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StudioPalette.recessed, in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    private var metadataControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Preserve source metadata", isOn: $model.project.exportSettings.preserveMetadata)
            if model.project.exportSettings.preserveMetadata {
                Toggle("Strip GPS location", isOn: $model.project.exportSettings.stripGPS)
            }
            Text("Orientation, output profile, dimensions, and bit depth always describe the exported pixels.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var destinationControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Redlamp's Location section: an "Export to" picker, then a saved-as
            // summary row. Ours was a bare path dump with two buttons under it.
            HStack {
                fieldLabel("Export to")
                Spacer()
                if model.project.exportSettings.destinationPath.isEmpty {
                    Text("Not set").foregroundStyle(.secondary)
                    Button("Choose…") { requestExportFolder() }
                        .controlSize(.small)
                } else {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            URL(fileURLWithPath: model.project.exportSettings.destinationPath)
                        ])
                    } label: {
                        Text(URL(fileURLWithPath: model.project.exportSettings.destinationPath).lastPathComponent)
                            .lineLimit(1).truncationMode(.middle)
                            .help(model.project.exportSettings.destinationPath)
                    }
                    .buttonStyle(.link)
                    Button("Change…") { requestExportFolder() }
                        .buttonStyle(.link)
                }
            }

            HStack {
                fieldLabel("Folder")
                Spacer()
                Text(model.project.exportSettings.destinationPath.isEmpty
                     ? "—" : model.project.exportSettings.destinationPath)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Label("Existing files are never silently overwritten.", systemImage: "checkmark.shield")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var actionFooter: some View {
        VStack(spacing: 10) {
            if let job = model.activeExportJob {
                HStack(spacing: 10) {
                    ProgressView(value: job.fractionComplete)
                        .frame(maxWidth: .infinity)
                    Text("\(job.processedCount) / \(job.items.count)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if let eta = job.estimatedRemainingSeconds, model.isExporting {
                        Text("ETA \(Self.duration(eta))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if job.failedCount > 0 {
                        Label("\(job.failedCount) failed", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
            }
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(model.selectedExportCount) photos · \(formatSummary) · \(outputSizeSummary)")
                        .font(.subheadline.weight(.medium)).lineLimit(1)
                    if let issue = exportBlockingReason, !model.isExporting {
                        Label(issue, systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(model.isExporting ? model.exportCurrentFileName : model.project.exportSettings.destinationPath)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
            }
            if !model.exportPerformanceSummary.isEmpty {
                Text(model.exportPerformanceSummary)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background(.regularMaterial)
    }

    private func requestExportFolder() { model.chooseExportDestination() }

    private var exportBlockingReason: String? {
        let settings = model.project.exportSettings
        if model.selectedExportCount == 0 { return "Select at least one photo to export" }
        // One chooser, per the Export must have one destination chooser rule.
        if settings.destinationPath.isEmpty { return "Choose a destination folder to enable Export" }
        if settings.sequenceStart < 1 { return "Sequence must start at 1 or later" }
        switch settings.resizeMode {
        case .none: break
        case .longEdge:
            if settings.resizeLongEdge < 1 { return "Long edge must be greater than zero" }
        case .width:
            if settings.resizeWidth < 1 { return "Width must be greater than zero" }
        case .height:
            if settings.resizeHeight < 1 { return "Height must be greater than zero" }
        case .fitBox, .cropToFill:
            if settings.resizeWidth < 1 || settings.resizeHeight < 1 {
                return "Output dimensions must be greater than zero"
            }
        }
        return nil
    }

    private var savedPresets: [StudioExportUserPreset] {
        (try? JSONDecoder().decode([StudioExportUserPreset].self, from: savedPresetsData)) ?? []
    }

    private var selectedPresetTitle: String {
        guard let id = selectedCustomPreset,
              let preset = savedPresets.first(where: { $0.id == id }) else {
            return "Custom Export"
        }
        return preset.settings == model.project.exportSettings ? preset.name : "\(preset.name) (edited)"
    }

    private func saveCustomPreset() {
        let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var all = savedPresets
        let item = StudioExportUserPreset(id: UUID(), name: name, settings: model.project.exportSettings)
        all.append(item)
        if let encoded = try? JSONEncoder().encode(all) {
            savedPresetsData = encoded
            selectedCustomPreset = item.id
        }
    }

    private func updateCustomPreset(_ id: UUID) {
        var all = savedPresets
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].settings = model.project.exportSettings
        if let encoded = try? JSONEncoder().encode(all) { savedPresetsData = encoded }
    }

    private func deleteCustomPreset(_ id: UUID) {
        let all = savedPresets.filter { $0.id != id }
        if let encoded = try? JSONEncoder().encode(all) {
            savedPresetsData = encoded
            selectedCustomPreset = nil
        }
    }

    private var previewImage: ProjectImageRecord? {
        model.selectedImage ?? model.project.images.first { $0.selectedForExport }
    }

    private var formatSummary: String {
        switch model.project.exportSettings.format {
        case .jpeg, .heic:
            return "\(model.project.exportSettings.format.rawValue) \(Int((model.project.exportSettings.jpegQuality * 100).rounded()))"
        case .tiff:
            return model.project.exportSettings.tiff16Bit ? "TIFF 16-bit" : "TIFF 8-bit"
        }
    }

    private var colorSummary: String {
        model.project.exportSettings.colorMode == .sRGB ? "sRGB" : "Match Renderer"
    }

    private var outputSizeSummary: String {
        let s = model.project.exportSettings
        switch s.resizeMode {
        case .none: return "Full Size"
        case .longEdge: return "\(s.resizeLongEdge) px long"
        case .width: return "\(s.resizeWidth) px wide"
        case .height: return "\(s.resizeHeight) px high"
        case .fitBox: return "Fit ≤ \(s.resizeWidth) × \(s.resizeHeight)"
        case .cropToFill: return "Crop \(s.resizeWidth) × \(s.resizeHeight)"
        }
    }

    private func badge(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .frame(height: 25)
            .background(.regularMaterial, in: Capsule())
    }

    private func summaryCell(_ label: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(label, systemImage: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioPalette.panel, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(StudioPalette.subtleBorder, lineWidth: 0.5)
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func numericField(_ label: String, value: Binding<Int>) -> some View {
        HStack {
            fieldLabel(label)
            Spacer()
            TextField(label, value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 105)
            Text("px").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func quickName(_ title: String, _ pattern: String) -> some View {
        Button(title) { model.project.exportSettings.filenameTemplate = pattern }
            .buttonStyle(.bordered)
            .controlSize(.mini)
    }

    private func token(_ value: String) -> some View {
        Button(value) { model.project.exportSettings.filenameTemplate += value }
            .buttonStyle(.borderless)
            .font(.caption2.monospaced())
    }

    private static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        let remainder = total % 60
        if minutes < 60 {
            return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s"
        }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
