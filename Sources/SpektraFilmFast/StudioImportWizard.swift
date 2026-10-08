import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// First-run and subsequent imports share the same guided, non-destructive path.
/// The steps expose only options the current importer can actually perform.
struct StudioImportWizard: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private enum Source: String, CaseIterable, Identifiable {
        case files = "Photos"
        case folder = "Folder or card"
        case lightroom = "Lightroom Classic"
        case cloudLibrary = "Existing iCloud library"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .files: return "photo.on.rectangle.angled"
            case .folder: return "externaldrive"
            case .lightroom: return "square.stack.3d.up"
            case .cloudLibrary: return "icloud"
            }
        }
        var subtitle: String {
            switch self {
            case .files: return "Choose individual RAW or image files"
            case .folder: return "Import a shoot without selecting every file"
            case .lightroom: return "Transfer a Classic catalog and its originals"
            case .cloudLibrary: return "Continue a SpektraFilm library on this Mac"
            }
        }
    }

    private enum Storage: String, CaseIterable, Identifiable {
        case reference = "Keep originals in place"
        case verified = "Copy to working drive + backup"
        case cloud = "Move library to iCloud Drive"
        var id: String { rawValue }
    }

    @State private var step = 0
    @State private var source: Source = .folder
    @State private var storage: Storage = .reference
    @State private var pickedURLs: [URL] = []
    @State private var primaryURL: URL?
    @State private var backupURL: URL?
    @State private var cloudParentURL: URL?
    @State private var problem: String?
    @State private var started = false

    init(model: AppModel, preferredSource: String? = nil) {
        self.model = model
        let initial = Source.allCases.first(where: { $0.rawValue == preferredSource }) ?? .folder
        _source = State(initialValue: initial)
        _storage = State(initialValue: initial == .lightroom ? .cloud : .reference)
    }

    private var isCloudOnly: Bool { source == .cloudLibrary }
    private var isLightroom: Bool { source == .lightroom }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Import into SpektraFilm")
                    .font(.system(size: 20, weight: .semibold))
                Spacer()
                if !RecentSpektraProjects.urls.isEmpty {
                    Menu("Recent Projects") {
                        ForEach(RecentSpektraProjects.urls, id: \.path) { url in
                            Button(url.deletingPathExtension().lastPathComponent) {
                                dismiss()
                                model.openProject(at: url)
                            }
                        }
                    }
                }
                Button("Cancel") { dismiss() }
                    .buttonStyle(.borderless)
                    .disabled(started)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            HStack(spacing: 8) {
                stepLabel(0, "Source")
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                stepLabel(1, "Storage")
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                stepLabel(2, "Review")
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                stepLabel(3, "Started")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Rectangle().fill(StudioPalette.divider).frame(height: 1)

            Group {
                switch step {
                case 0: sourceStep
                case 1: storageStep
                case 2: reviewStep
                default: startedStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 8)
            }

            Rectangle().fill(StudioPalette.divider).frame(height: 1)

            HStack {
                if step > 0 && step < 3 {
                    Button("Back") {
                        problem = nil
                        step = step == 2 && isCloudOnly ? 0 : step - 1
                    }
                }
                Spacer()
                if step == 3 {
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(step == 2 ? "Start Import" : "Continue") {
                        advance()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 720, height: 495)
        .background(StudioPalette.canvas)
    }

    private func stepLabel(_ index: Int, _ name: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: index < step ? "checkmark.circle.fill" : "\(index + 1).circle.fill")
                .foregroundStyle(index <= step ? Color.accentColor : Color.secondary)
            Text(name)
                .foregroundStyle(index == step ? Color.primary : Color.secondary)
                .fontWeight(index == step ? .semibold : .regular)
        }
        .font(.caption)
    }

    private var sourceStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Where are your photos?").font(.title3.weight(.semibold))
            Text("Choose a source. SpektraFilm will preserve your existing originals and Lightroom catalog.")
                .font(.subheadline).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(Source.allCases) { option in
                    Button {
                        source = option
                        pickedURLs = []
                        problem = nil
                        if option == .lightroom { storage = .cloud }
                        else { storage = .reference }
                    } label: {
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: option.symbol)
                                .font(.system(size: 22, weight: .light))
                                .frame(width: 35)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(option.rawValue).font(.subheadline.weight(.semibold))
                                Text(option.subtitle)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 55, alignment: .leading)
                        .padding(12)
                        .background(source == option ? Color.accentColor.opacity(0.10) : StudioPalette.panel,
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(source == option ? Color.accentColor : StudioPalette.subtleBorder, lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 12) {
                Button(pickedURLs.isEmpty ? "Choose \(source == .files ? "Photos" : source == .lightroom ? "Catalog" : "Folder")…" : "Change Source…") {
                    chooseSource()
                }
                .buttonStyle(.bordered)
                if !pickedURLs.isEmpty {
                    Text(pickedURLs.count == 1 ? pickedURLs[0].lastPathComponent : "\(pickedURLs.count) photos selected")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
            if isLightroom {
                Text("Supports Lightroom Classic .lrcat. Original RAW files must be accessible from this Mac or a connected drive.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var storageStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isCloudOnly ? "Cloud library location" : "Where should the originals live?")
                .font(.title3.weight(.semibold))
            if !isCloudOnly && !isLightroom {
                storageRow(.reference,
                           subtitle: "Instant, non-destructive indexing; source files are never moved.")
                if source == .folder {
                    storageRow(.verified,
                               subtitle: "Managed import with separate working and backup folders, verified by SHA-256.")
                }
                storageRow(.cloud,
                           subtitle: "Transfer this project and its originals into a SpektraFilm library in iCloud Drive.")
            } else {
                Label(isLightroom ? "Lightroom catalog + originals will be migrated into iCloud Drive." : "Open an existing synced library without copying its originals.",
                      systemImage: "icloud")
                    .font(.subheadline)
            }

            if storage == .verified && source == .folder {
                destinationRow("Working folder", url: primaryURL) { primaryURL = selectFolder(prompt: "Choose Working Folder") }
                destinationRow("Backup folder", url: backupURL) { backupURL = selectFolder(prompt: "Choose Backup Folder") }
            }
            if storage == .cloud || isLightroom {
                destinationRow("iCloud Drive destination", url: cloudParentURL) {
                    cloudParentURL = selectFolder(prompt: "Use iCloud Folder")
                }
            }
            if storage == .cloud {
                Text("iCloud Drive manages device-to-device file delivery. Keep an independent backup of your originals during migration.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func storageRow(_ option: Storage, subtitle: String) -> some View {
        Button {
            storage = option
            problem = nil
        } label: {
            HStack(spacing: 12) {
                Image(systemName: storage == option ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(storage == option ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.rawValue).font(.subheadline.weight(.medium))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .background(storage == option ? Color.accentColor.opacity(0.07) : StudioPalette.panel,
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func destinationRow(_ label: String, url: URL?, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption.weight(.semibold)).frame(width: 144, alignment: .leading)
            Text(url?.path ?? "Not selected")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Choose…", action: action).controlSize(.small)
        }
    }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review import").font(.title3.weight(.semibold))
            Text("Confirm the source and storage plan before starting.")
                .font(.subheadline).foregroundStyle(.secondary)
            summary("Source", pickedURLs.count == 1 ? pickedURLs[0].path : "\(pickedURLs.count) selected files")
            summary("Storage", isCloudOnly ? "Open existing cloud library" : isLightroom ? "Lightroom migration to iCloud" : storage.rawValue)
            if storage == .verified {
                summary("Working", primaryURL?.path ?? "—")
                summary("Backup", backupURL?.path ?? "—")
            }
            if storage == .cloud {
                summary("Cloud", cloudParentURL?.path ?? "—")
            }
            Label("Original files remain untouched during reference imports. Managed copies and cloud migrations use separate destinations.",
                  systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func summary(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(value).font(.subheadline).lineLimit(2).truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private var startedStep: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("Import started", systemImage: "checkmark.circle.fill")
                .font(.title2.weight(.semibold)).foregroundStyle(.green)
            Text("You can continue working in SpektraFilm. Import, indexing, verification, and cloud transfer progress remain visible in the Library.")
                .foregroundStyle(.secondary)
            if model.isIngesting {
                ProgressView(value: model.ingestProgress)
                Text(model.ingestStatus).font(.caption).foregroundStyle(.secondary)
            } else if model.isCloudSyncing {
                ProgressView(value: model.cloudSyncProgress)
                Text(model.cloudLibraryStatus).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(model.status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func advance() {
        problem = nil
        switch step {
        case 0:
            guard !pickedURLs.isEmpty else {
                problem = "Choose a source before continuing."
                return
            }
            step = isCloudOnly ? 2 : 1
        case 1:
            if storage == .verified {
                guard let primaryURL, let backupURL else {
                    problem = "Choose both a working folder and a separate backup folder."
                    return
                }
                guard primaryURL.standardizedFileURL != backupURL.standardizedFileURL else {
                    problem = "Working and backup folders must be different."
                    return
                }
            }
            if storage == .cloud || isLightroom {
                guard cloudParentURL != nil else {
                    problem = "Choose an iCloud Drive destination."
                    return
                }
            }
            step = 2
        case 2:
            commitImport()
        default: break
        }
    }

    private func commitImport() {
        guard let first = pickedURLs.first else { return }
        switch source {
        case .cloudLibrary:
            model.openICloudLibrary(at: first)
        case .lightroom:
            guard let cloudParentURL else { return }
            model.importLightroomCatalogToICloud(catalogURL: first, parent: cloudParentURL)
        case .files:
            model.addImages(urls: pickedURLs)
            if storage == .cloud, let cloudParentURL {
                model.moveCurrentLibraryToICloud(parent: cloudParentURL)
            }
        case .folder:
            if storage == .verified,
               let primaryURL, let backupURL {
                model.beginManagedIngest(source: first, primary: primaryURL, backup: backupURL)
            } else {
                model.importFolder(at: first, cloudParent: storage == .cloud ? cloudParentURL : nil)
            }
        }
        started = true
        step = 3
    }

    private func chooseSource() {
        if source == .cloudLibrary {
            // Return to the main window before presenting its SwiftUI folder importer.
            dismiss()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                model.openICloudLibrary()
            }
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = source == .files
        panel.canChooseFiles = source == .files || source == .lightroom
        panel.canChooseDirectories = source == .folder || source == .cloudLibrary
        panel.canCreateDirectories = false
        panel.prompt = "Choose Source"
        if source == .files {
            panel.allowedContentTypes = [.image, .rawImage]
        } else if source == .lightroom,
                  let catalog = UTType(filenameExtension: "lrcat") {
            panel.allowedContentTypes = [catalog]
        }
        if source == .cloudLibrary {
            panel.directoryURL = SpektraCloudLibrary.defaultICloudDriveURL()
        }
        guard panel.runModal() == .OK else { return }
        pickedURLs = panel.urls
        problem = nil
    }

    private func selectFolder(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = SpektraCloudLibrary.defaultICloudDriveURL()
        return panel.runModal() == .OK ? panel.url : nil
    }
}
