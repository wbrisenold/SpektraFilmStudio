import SwiftUI
import AppKit

struct QuickExportRequest: Identifiable {
    let id: UUID
}

struct QuickExportSheet: View {
    @ObservedObject var model: AppModel
    let imageID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var settings: ExportSettings

    init(model: AppModel, imageID: UUID) {
        self.model = model
        self.imageID = imageID
        _settings = State(initialValue: model.project.exportSettings)
    }

    private var image: ProjectImageRecord? {
        model.project.images.first(where: { $0.id == imageID })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.up.on.square")
                    .font(.title2)
                    .frame(width: 40, height: 40)
                    .background(StudioPalette.selected, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Export Photo").font(.title3.weight(.semibold))
                    Text(image?.fileName ?? "Selected photo")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button {
                    model.beginExportCrop(imageID)
                    dismiss()
                } label: {
                    Label("Crop", systemImage: "crop.rotate")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(18)
            Divider()

            ScrollView {
                VStack(spacing: 10) {
                    quickSection("File", symbol: "doc.richtext") {
                        LabeledContent("Format") {
                            Picker("Format", selection: $settings.format) {
                                ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) }
                            }.labelsHidden().frame(width: 150)
                        }
                        LabeledContent("Color") {
                            Picker("Color", selection: $settings.colorMode) {
                                ForEach(ExportColorMode.allCases) { Text($0.rawValue).tag($0) }
                            }.labelsHidden().frame(width: 205)
                        }
                        if settings.format == .jpeg || settings.format == .heic {
                            HStack(spacing: 10) {
                                Text("Quality").font(.caption.weight(.medium))
                                Slider(value: $settings.jpegQuality, in: 0.1...1)
                                Text("\(Int((settings.jpegQuality * 100).rounded()))")
                                    .font(.caption.monospacedDigit()).frame(width: 32, alignment: .trailing)
                            }
                        } else {
                            Toggle("16-bit TIFF", isOn: $settings.tiff16Bit)
                        }
                    }
                    quickSection("Dimensions", symbol: "aspectratio") {
                        LabeledContent("Resize") {
                            Picker("Resize", selection: $settings.resizeMode) {
                                Text("Full Size").tag(ExportResizeMode.none)
                                Text("Long Edge").tag(ExportResizeMode.longEdge)
                                Text("Width").tag(ExportResizeMode.width)
                                Text("Height").tag(ExportResizeMode.height)
                                Text("Fit Inside").tag(ExportResizeMode.fitBox)
                                Text("Fill / Crop").tag(ExportResizeMode.cropToFill)
                            }.labelsHidden().frame(width: 185)
                        }
                        HStack {
                            sizeFields
                            Spacer(minLength: 0)
                        }
                        if settings.resizeMode != .none {
                            Toggle("Don't enlarge smaller photos", isOn: $settings.dontEnlarge)
                        }
                        if settings.resizeMode == .cropToFill {
                            Label("Fills the frame by cropping edges, never stretching pixels.", systemImage: "crop")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    quickSection("Metadata", symbol: "checkmark.shield") {
                        Toggle("Preserve source metadata", isOn: $settings.preserveMetadata)
                        if settings.preserveMetadata {
                            Toggle("Strip GPS location", isOn: $settings.stripGPS)
                        }
                    }
                    quickSection("Destination", symbol: "folder") {
                        HStack(spacing: 8) {
                            Text(settings.destinationPath.isEmpty ? "Choose a folder" : settings.destinationPath)
                                .font(.caption)
                                .foregroundStyle(settings.destinationPath.isEmpty ? .secondary : .primary)
                                .lineLimit(2).truncationMode(.middle)
                                .textSelection(.enabled)
                            Spacer(minLength: 4)
                            Button("Choose…") { chooseDestination() }.controlSize(.small)
                        }
                        Label("Existing files are never silently overwritten.", systemImage: "checkmark.shield")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
            }
            .disabled(model.isExporting)
            Divider()
            HStack(spacing: 12) {
                if let issue = blockingIssue {
                    Label(issue, systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(settings.format.rawValue) · \(settings.colorMode.rawValue)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    model.exportImage(imageID, settings: settings)
                    dismiss()
                } label: {
                    Label("Export Photo", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(blockingIssue != nil)
            }
            .padding(16)
            .background(.regularMaterial)
        }
        .frame(width: 510, height: 660)
        .background(StudioPalette.panel)
    }

    private var blockingIssue: String? {
        if model.isExporting { return "Another export is running" }
        if image == nil { return "Photo unavailable" }
        if settings.destinationPath.isEmpty { return "Choose a destination" }
        if settings.sequenceStart < 1 { return "Sequence must be positive" }
        switch settings.resizeMode {
        case .none: break
        case .longEdge: if settings.resizeLongEdge < 1 { return "Enter a positive long edge" }
        case .width: if settings.resizeWidth < 1 { return "Enter a positive width" }
        case .height: if settings.resizeHeight < 1 { return "Enter a positive height" }
        case .fitBox, .cropToFill:
            if settings.resizeWidth < 1 || settings.resizeHeight < 1 { return "Enter positive dimensions" }
        }
        return nil
    }

    private func quickSection<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(StudioPalette.canvas, in: RoundedRectangle(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(StudioPalette.subtleBorder, lineWidth: 0.5) }
    }

    @ViewBuilder
    private var sizeFields: some View {
        switch settings.resizeMode {
        case .none:
            Text("Original pixels").font(.caption).foregroundStyle(.secondary)
        case .longEdge:
            HStack(spacing: 5) {
                TextField("px", value: $settings.resizeLongEdge, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 80)
                Text("px").font(.caption).foregroundStyle(.secondary)
            }
        case .fitBox, .cropToFill:
            HStack(spacing: 4) {
                TextField("W", value: $settings.resizeWidth, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 68)
                Text("×").foregroundStyle(.secondary)
                TextField("H", value: $settings.resizeHeight, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 68)
            }
        case .width:
            TextField("Width", value: $settings.resizeWidth, format: .number)
                .textFieldStyle(.roundedBorder).frame(width: 80)
        case .height:
            TextField("Height", value: $settings.resizeHeight, format: .number)
                .textFieldStyle(.roundedBorder).frame(width: 80)
        }
    }

    private func chooseDestination() {
        SpektraFilePanel.chooseFolder(title: "Choose Export Folder") { url in
            settings.destinationPath = url.path
        }
    }
}
