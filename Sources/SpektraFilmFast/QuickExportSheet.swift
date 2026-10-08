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
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Export This Photo").font(.headline)
                    Text(image?.fileName ?? "Selected photo")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button {
                    model.beginExportCrop(imageID)
                    dismiss()
                } label: {
                    Label("Crop", systemImage: "crop")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Format").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Picker("Format", selection: $settings.format) {
                        ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Color").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Picker("Color", selection: $settings.colorMode) {
                        ForEach(ExportColorMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 175)
                }
            }

            if settings.format == .jpeg || settings.format == .heic {
                HStack {
                    Text("Quality").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Slider(value: $settings.jpegQuality, in: 0.5...1)
                    Text("\(Int((settings.jpegQuality * 100).rounded()))")
                        .font(.caption.monospacedDigit()).frame(width: 34)
                }
            } else {
                Toggle("16-bit TIFF", isOn: $settings.tiff16Bit)
            }

            Divider()

            HStack {
                Text("Size").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Picker("Size", selection: $settings.resizeMode) {
                    Text("Full Size").tag(ExportResizeMode.none)
                    Text("Long Edge").tag(ExportResizeMode.longEdge)
                    Text("Width").tag(ExportResizeMode.width)
                    Text("Height").tag(ExportResizeMode.height)
                    Text("Fit Box").tag(ExportResizeMode.fitBox)
                    Text("Fill / Crop").tag(ExportResizeMode.cropToFill)
                }
                .labelsHidden()
                Spacer()
                sizeFields
            }

            HStack {
                Toggle("Preserve metadata", isOn: $settings.preserveMetadata)
                if settings.preserveMetadata {
                    Toggle("Strip GPS", isOn: $settings.stripGPS)
                }
            }
            .font(.caption)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Destination").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack {
                    Text(settings.destinationPath.isEmpty ? "Choose a folder" : settings.destinationPath)
                        .font(.caption).foregroundStyle(settings.destinationPath.isEmpty ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { chooseDestination() }.controlSize(.small)
                }
            }

            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if model.isExporting {
                    ProgressView().controlSize(.small)
                    Text("Another export is running").font(.caption).foregroundStyle(.secondary)
                }
                Button("Export") {
                    model.exportImage(imageID, settings: settings)
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(settings.destinationPath.isEmpty || model.isExporting || image == nil)
            }
        }
        .padding(18)
        .frame(width: 470)
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
