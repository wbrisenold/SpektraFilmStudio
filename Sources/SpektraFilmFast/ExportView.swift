import SwiftUI

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

    var body: some View {
        HSplitView {
            sourceBrowser
                .frame(minWidth: 360, idealWidth: 430, maxWidth: 560)

            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        deliveryCard
                        destinationCard
                        namingCard
                        fileCard
                        resizeCard
                        metadataCard
                        queueCard
                    }
                    .padding(14)
                }
                .background(StudioPalette.recessed)

                Divider()
                footer
            }
            .frame(minWidth: 540)
        }
        .background(StudioPalette.canvas)
    }

    private var sourceBrowser: some View {
        VStack(spacing: 0) {
            VStack(spacing: 9) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("EXPORT SET")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(
                            "\(model.selectedExportCount) of " +
                            "\(model.project.images.count) queued"
                        )
                        .font(.headline)
                    }

                    Spacer()

                    Menu {
                        Button("All Photos") {
                            model.setAllExportSelection(true)
                        }
                        Button("None") {
                            model.setAllExportSelection(false)
                        }

                        Divider()

                        Button("Picks Only") {
                            model.selectExportPicksOnly()
                        }
                        Button("Client Picks Only") {
                            model.selectExportClientPicksOnly()
                        }
                        Button("4 Stars & Up") {
                            model.selectExportRating(atLeast: 4)
                        }
                        Button("5 Stars Only") {
                            model.selectExportRating(atLeast: 5)
                        }
                    } label: {
                        Label("Build Set", systemImage: "checklist")
                    }
                    .disabled(model.isExporting)
                }

                TextField("Filter export browser…", text: $search)
                    .textFieldStyle(.roundedBorder)

                Picker("Sources", selection: $sourceFilter) {
                    ForEach(ExportSourceFilter.allCases) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(12)
            .background(StudioPalette.panel)

            Divider()

            List {
                ForEach(filteredImages) { image in
                    HStack(spacing: 10) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { image.selectedForExport },
                                set: { _ in
                                    model.toggleExportSelection(image.id)
                                }
                            )
                        )
                        .labelsHidden()
                        .disabled(model.isExporting)

                        LocalThumbnail(
                            url: image.url,
                            contentMode: .fit
                        )
                        .frame(width: 82, height: 58)
                        .background(
                            Color.black.opacity(0.20),
                            in: RoundedRectangle(cornerRadius: 5)
                        )

                        VStack(alignment: .leading, spacing: 4) {
                            Text(image.fileName).lineLimit(1)

                            HStack(spacing: 6) {
                                if image.rating > 0 {
                                    Text("\(image.rating)★")
                                }
                                Text(image.flag.label)
                                if image.clientPicked {
                                    Label(
                                        "Client",
                                        systemImage: "heart.fill"
                                    )
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if image.selectedForExport {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.selectImage(image.id, renderPreview: false)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var filteredImages: [ProjectImageRecord] {
        let needle = search.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        return model.project.images.filter { image in
            let category: Bool
            switch sourceFilter {
            case .all:
                category = true
            case .queued:
                category = image.selectedForExport
            case .picks:
                category = image.flag == .picked
            case .client:
                category = image.clientPicked
            case .rated:
                category = image.rating >= 4
            case .rejected:
                category = image.flag == .rejected
            }

            let textMatch =
                needle.isEmpty ||
                image.fileName.localizedCaseInsensitiveContains(needle)
            return category && textMatch
        }
    }

    private var deliveryCard: some View {
        card("Delivery", icon: "shippingbox") {
            HStack {
                Menu {
                    ForEach(ExportPresetCategory.allCases) { category in
                        Menu(category.rawValue) {
                            ForEach(
                                ExportPresetDefinition.all.filter {
                                    $0.category == category
                                }
                            ) { preset in
                                Button(preset.name) {
                                    model.applyExportPreset(preset.id)
                                }
                            }
                        }
                    }
                } label: {
                    Label("Apply Preset", systemImage: "wand.and.stars")
                }
                .disabled(model.isExporting)

                Spacer()

                Picker(
                    "Delivery color",
                    selection: $model.project.exportSettings.colorMode
                ) {
                    ForEach(ExportColorMode.allCases) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .frame(width: 270)
                .disabled(model.isExporting)
            }

            if model.project.exportSettings.colorMode == .sRGB {
                Label(
                    "Renders actual sRGB pixels for predictable web, phone, " +
                    "messaging and social-media delivery.",
                    systemImage: "iphone"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Label(
                    "Preserves the photo's renderer output space for controlled " +
                    "color-managed master workflows.",
                    systemImage: "display"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var destinationCard: some View {
        card("Destination", icon: "folder") {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        model.project.exportSettings.destinationPath.isEmpty
                            ? "No folder selected"
                            : model.project.exportSettings.destinationPath
                    )
                    .lineLimit(2)

                    if !model.project.exportSettings.destinationPath.isEmpty {
                        Text("Existing files are never silently overwritten.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button("Choose…") {
                    model.chooseExportDestination()
                }
                .disabled(model.isExporting)
            }
        }
    }

    private var namingCard: some View {
        card("File Naming", icon: "textformat") {
            HStack {
                TextField(
                    "Filename template",
                    text: $model.project.exportSettings.filenameTemplate
                )
                .textFieldStyle(.roundedBorder)
                .disabled(model.isExporting)

                Stepper(
                    "Start \(model.project.exportSettings.sequenceStart)",
                    value: $model.project.exportSettings.sequenceStart,
                    in: 0...999999
                )
                .fixedSize()
                .disabled(model.isExporting)
            }

            Text("Tokens: {name}, {original_filename}, {sequence}")
                .font(.caption2)
                .foregroundStyle(.secondary)

            let names = model.exportPreflightNames
            if !names.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("NAME PREVIEW")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(
                        Array(names.enumerated()),
                        id: \.offset
                    ) { _, name in
                        Text(name)
                            .font(.caption2.monospaced())
                            .lineLimit(1)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    StudioPalette.recessed,
                    in: RoundedRectangle(cornerRadius: 7)
                )
            }
        }
    }

    private var fileCard: some View {
        card("File & Quality", icon: "doc.richtext") {
            HStack {
                Picker(
                    "Format",
                    selection: $model.project.exportSettings.format
                ) {
                    ForEach(ExportFormat.allCases) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .frame(width: 190)

                if model.project.exportSettings.format == .jpeg ||
                   model.project.exportSettings.format == .heic {
                    Text("Quality")
                    Slider(
                        value: $model.project.exportSettings.jpegQuality,
                        in: 0.1...1
                    )
                    Text(
                        "\(Int((model.project.exportSettings.jpegQuality * 100).rounded()))"
                    )
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
                }

                if model.project.exportSettings.format == .tiff {
                    Toggle(
                        "16-bit",
                        isOn: $model.project.exportSettings.tiff16Bit
                    )
                }
            }
            .disabled(model.isExporting)
        }
    }

    private var resizeCard: some View {
        card("Dimensions", icon: "aspectratio") {
            Picker(
                "Resize",
                selection: $model.project.exportSettings.resizeMode
            ) {
                ForEach(ExportResizeMode.allCases) {
                    Text($0.rawValue).tag($0)
                }
            }
            .pickerStyle(.segmented)

            Group {
                switch model.project.exportSettings.resizeMode {
                case .none:
                    Text("Full rendered dimensions")
                        .foregroundStyle(.secondary)

                case .longEdge:
                    Stepper(
                        "Long edge " +
                        "\(model.project.exportSettings.resizeLongEdge) px",
                        value: $model.project.exportSettings.resizeLongEdge,
                        in: 256...30000,
                        step: 64
                    )

                case .width:
                    Stepper(
                        "Width \(model.project.exportSettings.resizeWidth) px",
                        value: $model.project.exportSettings.resizeWidth,
                        in: 256...30000,
                        step: 64
                    )

                case .height:
                    Stepper(
                        "Height \(model.project.exportSettings.resizeHeight) px",
                        value: $model.project.exportSettings.resizeHeight,
                        in: 256...30000,
                        step: 64
                    )

                case .fitBox:
                    HStack {
                        Stepper(
                            "Width \(model.project.exportSettings.resizeWidth)",
                            value: $model.project.exportSettings.resizeWidth,
                            in: 256...30000,
                            step: 64
                        )
                        Stepper(
                            "Height \(model.project.exportSettings.resizeHeight)",
                            value: $model.project.exportSettings.resizeHeight,
                            in: 256...30000,
                            step: 64
                        )
                    }
                }
            }
            .disabled(model.isExporting)

            if model.project.exportSettings.resizeMode != .none {
                Toggle(
                    "Don't enlarge smaller images",
                    isOn: $model.project.exportSettings.dontEnlarge
                )
                .disabled(model.isExporting)
            }
        }
    }

    private var metadataCard: some View {
        card("Metadata & Privacy", icon: "info.circle") {
            Toggle(
                "Preserve source metadata",
                isOn: $model.project.exportSettings.preserveMetadata
            )
            .disabled(model.isExporting)

            if model.project.exportSettings.preserveMetadata {
                Toggle(
                    "Strip GPS location",
                    isOn: $model.project.exportSettings.stripGPS
                )
                .disabled(model.isExporting)
            }

            Text(
                "Orientation, dimensions, output profile and bit depth describe " +
                "the exported pixels, not the source RAW."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var queueCard: some View {
        card("Queue & Recovery", icon: "list.bullet.rectangle") {
            if let job = model.activeExportJob {
                HStack {
                    Text("\(job.completedCount) done")
                    Text("·")
                    Text("\(job.remainingCount) remaining")
                    if let seconds = job.estimatedRemainingSeconds {
                        Text("· ETA \(Self.duration(seconds))")
                    }
                    if let bytes = job.estimatedTotalOutputBytes {
                        Text("· ~\(Self.byteCount(bytes))")
                    }
                    if job.failedCount > 0 {
                        Text("· \(job.failedCount) failed")
                            .foregroundStyle(.red)
                    }

                    Spacer()

                    if !model.isExporting, job.remainingCount > 0 {
                        Button("Resume") { model.resumeExport() }
                        if job.failedCount > 0 {
                            Button("Retry Failed") {
                                model.retryFailedExports()
                            }
                        }
                        Button("Discard") {
                            model.discardRecoveredExportJob()
                        }
                    }
                }
                .font(.caption)

                ProgressView(value: job.fractionComplete)

                ForEach(job.items.suffix(8)) { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.state.systemImage)
                        Text(item.sourceFileName).lineLimit(1)
                        Spacer()
                        Text(item.state.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(
                    "The queue is crash-recoverable. Decode, GPU render and " +
                    "encode/write run as a bounded pipeline."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.isExporting {
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        model.isStoppingExport ? "Stopping…" : "Exporting"
                    )
                    .font(.headline)
                    Text(model.exportCurrentFileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                ProgressView(value: model.exportProgress)
                    .frame(width: 180)

                Button(role: .destructive) {
                    model.stopExport()
                } label: {
                    Label(
                        model.isStoppingExport ? "Stopping…" : "Stop Export",
                        systemImage: "stop.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isStoppingExport)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        "\(model.selectedExportCount) photo" +
                        "\(model.selectedExportCount == 1 ? "" : "s") ready"
                    )
                    .font(.headline)
                    Text(model.project.exportSettings.colorMode.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    model.exportSelected()
                } label: {
                    Label(
                        "Export \(model.selectedExportCount)",
                        systemImage: "square.and.arrow.up"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(
                    model.selectedExportCount == 0 ||
                    model.project.exportSettings.destinationPath.isEmpty
                )
            }
        }
        .padding(14)
        .background(.regularMaterial)
    }

    private static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        let remainder = total % 60
        if minutes < 60 { return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func card<Content: View>(
        _ title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline)
            Divider()
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            StudioPalette.panel,
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(StudioPalette.subtleBorder, lineWidth: 0.5)
        }
    }
}
