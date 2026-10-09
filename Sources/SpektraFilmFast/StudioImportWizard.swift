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

    @State private var source: Source = .folder
    @State private var storage: Storage = .reference
    @State private var pickedURLs: [URL] = []
    @State private var primaryURL: URL?
    @State private var backupURL: URL?
    @State private var cloudParentURL: URL?
    @State private var problem: String?
    @State private var requestedInitialSource = false

    init(model: AppModel, preferredSource: String? = nil) {
        self.model = model
        let initial = Source.allCases.first(where: { $0.rawValue == preferredSource }) ?? .folder
        _source = State(initialValue: initial)
        _storage = State(initialValue: initial == .lightroom ? .cloud : .reference)
    }

    private var isCloudOnly: Bool { source == .cloudLibrary }
    private var isLightroom: Bool { source == .lightroom }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Import with Backup or Cloud").font(.title2.weight(.semibold))
                    Text("Choose your photos and storage on this screen.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    sourceStep
                    if !isCloudOnly { Divider(); storageStep }
                }.padding(20)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).padding(.horizontal, 20).padding(.bottom, 12)
            }
            Divider()
            HStack {
                Text("Your source files stay in place.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(isCloudOnly ? "Open Library" : "Import Photos") { commitImport() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(pickedURLs.isEmpty || model.isIngesting || model.isCloudSyncing)
            }.padding(20)
        }
        .frame(width: 700, height: 520)
        .background(StudioPalette.canvas)
        .onAppear {
            guard !requestedInitialSource else { return }
            requestedInitialSource = true
            chooseSource()
        }
    }

    private var sourceStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Source", selection: $source) {
                ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .onChange(of: source) { _, selected in
                pickedURLs = []
                problem = nil
                storage = selected == .lightroom ? .cloud : .reference
                chooseSource()
            }
            HStack {
                Text(pickedURLs.isEmpty ? "No source selected" : pickedURLs.count == 1 ? pickedURLs[0].path : "\(pickedURLs.count) photos selected")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                Spacer()
                Button(pickedURLs.isEmpty ? "Choose…" : "Change…") { chooseSource() }
            }
            if isLightroom {
                Text("Lightroom Classic .lrcat; originals must be accessible on this Mac or a connected drive.")
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
                destinationRow("Working folder", url: primaryURL) { chooseDestination("working") }
                destinationRow("Backup folder", url: backupURL) { chooseDestination("backup") }
            }
            if storage == .cloud || isLightroom {
                destinationRow("iCloud Drive destination", url: cloudParentURL) {
                    chooseDestination("cloud")
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

    private func commitImport() {
        problem = nil
        guard let first = pickedURLs.first else { problem = "Choose photos or a folder first."; return }
        if storage == .verified && source == .folder {
            guard let primaryURL, let backupURL,
                  primaryURL.standardizedFileURL != backupURL.standardizedFileURL else {
                problem = "Choose separate working and backup folders."; return
            }
        }
        if !isCloudOnly && (storage == .cloud || isLightroom) && cloudParentURL == nil {
            problem = "Choose an iCloud Drive destination."; return
        }
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
        dismiss()
    }

    private func chooseSource() {
        switch source {
        case .folder, .cloudLibrary:
            SpektraFilePanel.chooseFolder(title: source == .cloudLibrary ? "Choose Existing iCloud Library" : "Choose Photo Folder") { url in
                pickedURLs = [url]
                problem = nil
            }
        case .files, .lightroom:
            let isLightroom = source == .lightroom
            SpektraFilePanel.chooseFiles(title: isLightroom ? "Choose Lightroom Classic Catalog" : "Choose Photos",
                                         types: isLightroom ? nil : [.image, .rawImage],
                                         multiple: !isLightroom) { urls in
                guard !urls.isEmpty else { return }
                if isLightroom && (urls.count != 1 || urls[0].pathExtension.lowercased() != "lrcat") {
                    problem = "Choose one Lightroom Classic .lrcat catalog."
                    return
                }
                pickedURLs = urls
                problem = nil
            }
        }
    }

    private func chooseDestination(_ target: String) {
        SpektraFilePanel.chooseFolder(title: target == "working" ? "Choose Working Folder" :
                                     target == "backup" ? "Choose Backup Folder" : "Choose iCloud Destination") { url in
            switch target {
            case "working": primaryURL = url
            case "backup": backupURL = url
            default: cloudParentURL = url
            }
            problem = nil
        }
    }
}
