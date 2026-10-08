import SwiftUI
import AppKit

private enum ExportSourceFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case queued = "Queued"
    case picks = "Picks"
    case client = "Client"
    case rated = "4+"
    case rejected = "Rejected"
    var id: String { rawValue }
}

struct ExportWorkspaceView: View {
    @ObservedObject var model: AppModel
    @State private var sourceFilter: ExportSourceFilter = .all
    @State private var search = ""
    @AppStorage("SpektraFilmStudio.designA.v2.showExportBrowser") private var showExportBrowser = false
    @AppStorage("SpektraFilmStudio.ux.v3.showExportInspector") private var showExportInspector = true

    var body: some View {
        HSplitView {
            if showExportBrowser {
                sourceBrowser
                    .frame(minWidth: 250, idealWidth: 290, maxWidth: 360)
            }

            HSplitView {
                previewAndQueue.frame(minWidth: 500)
                if showExportInspector {
                    inspector.frame(minWidth: 290, idealWidth: 320, maxWidth: 390)
                }
            }
        }
        .background(StudioPalette.canvas)
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
            VStack(spacing: 8) {
              HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("OUTPUT PREVIEW")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(previewImage?.fileName ?? "No photo selected")
                        .font(.headline)
                        .lineLimit(1)
                }
                Spacer()
                Menu("Select Photos") {
                    Button("All Photos") { model.setAllExportSelection(true) }
                    Button("Picked Photos") { model.selectExportPicksOnly() }
                    Button("Client Picks") { model.selectExportClientPicksOnly() }
                    Button("4 Stars and Up") { model.selectExportRating(atLeast: 4) }
                    Button("Highlighted in Library") { model.setAllExportSelection(false); model.batchSetExportSelection(true) }
                    Divider()
                    Button("Clear Export Selection") { model.setAllExportSelection(false) }
                }.disabled(model.isExporting)
                Button {
                    showExportBrowser.toggle()
                    if showExportBrowser { showExportInspector = false }
                } label: {
                    Label("Photos", systemImage: "photo.stack")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(showExportBrowser ? "Hide photo browser" : "Show photo browser")
                Button {
                    showExportInspector.toggle()
                    if showExportInspector { showExportBrowser = false }
                } label: {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Show or hide detailed export settings")
              }
              HStack {
                if model.isExporting {
                    ProgressView().controlSize(.mini)
                    Button("Stop") { model.stopExport() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    Button {
                        if model.project.exportSettings.destinationPath.isEmpty {
                            model.chooseExportDestination()
                        } else {
                            model.exportSelected()
                        }
                    } label: {
                        Label(model.project.exportSettings.destinationPath.isEmpty
                              ? "Set Destination" : "Export \(model.selectedExportCount)",
                              systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(model.selectedExportCount == 0)
                }
                if let image = previewImage {
                    Button {
                        if model.isCropToolActive {
                            model.finishExportCrop()
                        } else {
                            model.beginExportCrop(image.id)
                        }
                    } label: {
                        Label(
                            model.isCropToolActive ? "Done Crop" : "Crop Photo",
                            systemImage: model.isCropToolActive ? "checkmark.circle" : "crop"
                        )
                    }
                    .controlSize(.small)
                    .disabled(model.isExporting)

                    Button {
                        model.focusPhoto(image.id, destination: .edit)
                    } label: {
                        Label("Open in Edit", systemImage: "slider.horizontal.3")
                    }
                    .controlSize(.small)
                }
                Spacer(minLength: 0)
              }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
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
                queuePanel.frame(height: 180)
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
                    if job.failedCount > 0 {
                        Button("Retry Failed") { model.retryFailedExports() }.controlSize(.small)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(StudioPalette.panel)

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
            ScrollView {
                VStack(spacing: 0) {
                    inspectorHeader
                    section("Destination", "folder") { destinationControls }
                    section("File", "doc.richtext") { fileControls }
                    section("Size", "aspectratio") { sizeControls }
                    section("Color", "shippingbox") { deliveryControls }
                    DisclosureGroup("File names and metadata") {
                        section("Naming", "textformat") { namingControls }
                        section("Metadata", "info.circle") { metadataControls }
                    }.padding(12)
                }
            }
            Divider()
            actionFooter
        }
        .background(StudioPalette.panel)
    }

    private var inspectorHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("EXPORT")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Output Settings").font(.headline)
                }
                Spacer()
                Menu {
                    ForEach(ExportPresetCategory.allCases) { category in
                        Menu(category.rawValue) {
                            ForEach(ExportPresetDefinition.all.filter { $0.category == category }) { preset in
                                Button(preset.name) { model.applyExportPreset(preset.id) }
                            }
                        }
                    }
                } label: {
                    Label("Preset", systemImage: "wand.and.stars")
                }
                .controlSize(.small)
                .disabled(model.isExporting)
            }
        }
        .padding(12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(StudioPalette.divider).frame(height: 1)
        }
    }

    private func section<Content: View>(
        _ title: String,
        _ icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
            content()
        }
        .padding(12)
        .disabled(model.isExporting)
        .overlay(alignment: .bottom) {
            Rectangle().fill(StudioPalette.divider).frame(height: 1)
        }
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

            if model.project.exportSettings.format == .tiff {
                Toggle("16-bit TIFF", isOn: $model.project.exportSettings.tiff16Bit)
            }
        }
    }

    private var sizeControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("Output sizing")
            Picker("Output sizing", selection: $model.project.exportSettings.resizeMode) {
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
            Text(
                model.project.exportSettings.destinationPath.isEmpty
                    ? "No destination selected"
                    : model.project.exportSettings.destinationPath
            )
            .font(.caption)
            .lineLimit(3)
            .textSelection(.enabled)

            HStack {
                Button("Choose Folder…") { model.chooseExportDestination() }
                if !model.project.exportSettings.destinationPath.isEmpty {
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            URL(fileURLWithPath: model.project.exportSettings.destinationPath)
                        ])
                    }
                }
            }
            Label("Existing files are never silently overwritten.", systemImage: "checkmark.shield")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var actionFooter: some View {
        VStack(spacing: 9) {
            if !model.exportPerformanceSummary.isEmpty {
                Text(model.exportPerformanceSummary)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("Breakdown for the last completed photo. JPEG quality affects only the last stage.")
            }
            if let job = model.activeExportJob {
                HStack {
                    Text("\(job.completedCount)/\(max(1, job.items.count))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    ProgressView(value: job.fractionComplete)
                    if job.failedCount > 0 {
                        Text("\(job.failedCount) failed").font(.caption).foregroundStyle(.red)
                    }
                }
            }

            if model.isExporting {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Exporting").font(.subheadline.weight(.semibold))
                        Text(model.exportCurrentFileName)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button(role: .destructive) { model.stopExport() } label: {
                        Label(
                            model.isStoppingExport ? "Stopping…" : "Stop Export",
                            systemImage: "stop.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isStoppingExport)
                }
            } else {
                Button {
                    if model.project.exportSettings.destinationPath.isEmpty { model.chooseExportDestination() }
                    else { model.exportSelected() }
                } label: {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                        Text(
                            model.project.exportSettings.destinationPath.isEmpty ? "Choose Export Folder…" :
                            model.selectedExportCount == 1 ? "Export 1 Photo" : "Export \(model.selectedExportCount) Photos"
                        )
                        Spacer()
                        Text(model.project.exportSettings.format.rawValue)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(
                    model.selectedExportCount == 0
                )
            }
        }
        .padding(12)
        .background(.regularMaterial)
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
            .controlSize(.small)
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
