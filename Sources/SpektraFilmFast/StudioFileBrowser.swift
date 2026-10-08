import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// AppKit's open/save service can block in bookmark resolution before a panel exists.
/// This browser never contacts that service or resolves recent-folder bookmarks.
@MainActor
final class StudioFileBrowser: ObservableObject {
    struct Entry: Identifiable, Sendable {
        let url: URL
        let directory: Bool
        let selectable: Bool
        var id: URL { url }
    }
    enum Mode { case files, folder, save }
    let mode: Mode
    let types: [UTType]
    let multiple: Bool
    let complete: ([URL]) -> Void
    @Published var directory = FileManager.default.homeDirectoryForCurrentUser
    @Published var path = ""
    @Published var filename = ""
    @Published var entries: [Entry] = []
    @Published var selection: Set<URL> = []
    @Published var showHidden = false
    @Published var loading = false
    @Published var problem: String?
    @Published var overwriteURL: URL?
    @Published var newFolderName = ""
    private var generation = UUID()
    private var timeout: Task<Void, Never>?

    init(mode: Mode, types: [UTType], multiple: Bool, filename: String = "", complete: @escaping ([URL]) -> Void) {
        self.mode = mode
        self.types = types
        self.multiple = multiple
        self.filename = filename
        self.complete = complete
    }

    nonisolated static func accepts(_ url: URL, types: [UTType]) -> Bool {
        guard !types.isEmpty else { return true }
        let ext = url.pathExtension.lowercased()
        return types.contains { type in
            if type.identifier == "org.spektrafilm.project" { return ext == "spektrafilm" }
            if type.identifier == "com.spektrafilm.preset" { return ext == "sfpreset" }
            guard let candidate = UTType(filenameExtension: ext) else { return false }
            return candidate.conforms(to: type)
        }
    }

    /// A slow/unavailable drive cannot block the UI; stale results are ignored.
    private func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T,
                                     receive: @escaping (T) -> Void) {
        timeout?.cancel()
        let token = UUID()
        generation = token
        loading = true
        problem = nil
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, self.generation == token else { return }
            self.generation = UUID()
            self.loading = false
            self.problem = "This location is not responding. Choose another folder or check the drive connection."
        }
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result { try work() } }.value
            guard let self, self.generation == token else { return }
            self.timeout?.cancel()
            self.loading = false
            switch result {
            case .success(let value): receive(value)
            case .failure(let error): self.problem = error.localizedDescription
            }
        }
    }

    func navigate(_ url: URL) {
        directory = url.standardizedFileURL
        path = directory.path
        selection = []
        entries = []
        let folder = directory, hidden = showHidden, allowed = types
        perform({
            let fm = FileManager.default
            // Do not stat mounted drives just to display the Locations list.
            let volumes = folder.path == "/Volumes"
            let urls = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                options: hidden ? [] : [.skipsHiddenFiles])
            return try urls.map { url -> Entry in
                let isDirectory: Bool
                if volumes { isDirectory = true }
                else { isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
                return Entry(url: url, directory: isDirectory,
                             selectable: Self.accepts(url, types: allowed))
            }.sorted {
                if $0.directory != $1.directory { return $0.directory }
                return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
            }
        }, receive: { [weak self] in self?.entries = $0 })
    }

    func goToPath() {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, relativeTo: directory).standardizedFileURL
        perform({ try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }, receive: { [weak self] isDirectory in
            guard let self else { return }
            if isDirectory { self.navigate(url) }
            else {
                self.navigate(url.deletingLastPathComponent())
                self.filename = url.lastPathComponent
                self.selection = [url]
            }
        })
    }

    func cancel() {
        generation = UUID()
        timeout?.cancel()
        complete([])
    }

    func choose() {
        let urls: [URL]
        switch mode {
        case .folder: urls = selection.isEmpty ? [directory] : Array(selection)
        case .files: urls = Array(selection)
        case .save:
            guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/") else {
                problem = "Enter a file name without a slash."
                return
            }
            var url = directory.appendingPathComponent(filename)
            if url.pathExtension.isEmpty, let type = types.first {
                let ext = type.identifier == "org.spektrafilm.project" ? "spektrafilm" :
                    type.identifier == "com.spektrafilm.preset" ? "sfpreset" : type.preferredFilenameExtension
                if let ext { url.appendPathExtension(ext) }
            }
            urls = [url]
        }
        guard !urls.isEmpty, multiple || urls.count == 1 else {
            problem = multiple ? "Choose at least one file." : "Choose one item."
            return
        }
        let folderMode = mode == .folder, saveMode = mode == .save, allowed = types
        perform({
            let fm = FileManager.default
            for url in urls {
                if !folderMode && !Self.accepts(url, types: allowed) {
                    throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "Choose a supported file type."])
                }
                if saveMode && !fm.fileExists(atPath: url.path) { continue }
                let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                guard isDirectory == folderMode else {
                    throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: folderMode ? "Choose a folder." : "Choose a file."])
                }
            }
            return saveMode && fm.fileExists(atPath: urls[0].path)
        }, receive: { [weak self] exists in
            guard let self else { return }
            if exists { self.overwriteURL = urls[0] }
            else { self.complete(urls) }
        })
    }

    func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            problem = "Enter a folder name without a slash."
            return
        }
        let url = directory.appendingPathComponent(name, isDirectory: true)
        perform({ try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false); return url },
                receive: { [weak self] in self?.newFolderName = ""; self?.navigate($0) })
    }
    static func runResponsivenessTest(in folder: URL) async -> Bool {
        let browser = StudioFileBrowser(mode: .files, types: [], multiple: false) { _ in }
        browser.perform({ Thread.sleep(forTimeInterval: 0.4); return "stale" },
                        receive: { browser.problem = $0 })
        browser.navigate(folder)
        try? await Task.sleep(for: .seconds(1))
        guard !browser.loading, browser.problem == nil else { return false }
        browser.perform({ Thread.sleep(forTimeInterval: 9); return "late" },
                        receive: { browser.problem = $0 })
        try? await Task.sleep(for: .milliseconds(8300))
        guard !browser.loading, browser.problem?.contains("not responding") == true else { return false }
        browser.navigate(folder)
        try? await Task.sleep(for: .seconds(1))
        return !browser.loading && browser.problem == nil && browser.directory == folder.standardizedFileURL
    }

}

struct StudioFileBrowserView: View {
    @ObservedObject var browser: StudioFileBrowser
    private var selectedBinding: Binding<Set<URL>> {
        Binding(get: { browser.selection }, set: { values in
            if !browser.multiple && values.count > 1 {
                browser.selection = Set(values.subtracting(browser.selection).prefix(1))
            } else { browser.selection = values }
        })
    }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button { browser.navigate(browser.directory.deletingLastPathComponent()) } label: { Image(systemName: "arrow.up") }
                    .help("Parent folder")
                TextField("Folder or file path", text: $browser.path).onSubmit { browser.goToPath() }
                Button("Go") { browser.goToPath() }
            }
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    location("Home", "house", FileManager.default.homeDirectoryForCurrentUser)
                    location("Desktop", "desktopcomputer", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"))
                    location("Documents", "doc", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents"))
                    location("Downloads", "arrow.down.circle", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
                    location("Drives", "externaldrive", URL(fileURLWithPath: "/Volumes"))
                    Spacer()
                }.padding(12).frame(width: 135)
                Divider()
                List(selection: selectedBinding) {
                    ForEach(browser.entries) { entry in
                        HStack {
                            Image(systemName: entry.directory ? "folder" : "doc")
                            Text(entry.url.lastPathComponent).lineLimit(1)
                            Spacer()
                            if entry.directory {
                                Button { browser.navigate(entry.url) } label: { Image(systemName: "chevron.right") }
                                    .buttonStyle(.borderless).help("Open folder")
                            }
                        }
                        .foregroundStyle(entry.directory || entry.selectable ? .primary : .secondary)
                        .tag(entry.url)
                        .onTapGesture(count: 2) {
                            if entry.directory { browser.navigate(entry.url) }
                            else { browser.selection = [entry.url]; browser.choose() }
                        }
                    }
                }
            }.frame(minHeight: 300)
            if browser.mode == .save { TextField("File name", text: $browser.filename) }
            HStack {
                Toggle("Show hidden files", isOn: $browser.showHidden).onChange(of: browser.showHidden) { _, _ in browser.navigate(browser.directory) }
                Spacer()
                if browser.mode != .files {
                    TextField("New folder", text: $browser.newFolderName).frame(width: 150)
                    Button("Create") { browser.createFolder() }.disabled(browser.loading)
                }
            }
            HStack {
                if browser.loading { ProgressView().controlSize(.small); Text("Reading folder…").foregroundStyle(.secondary) }
                if let problem = browser.problem { Text(problem).foregroundStyle(.red).font(.caption) }
                Spacer()
                Button("Cancel") { browser.cancel() }.keyboardShortcut(.cancelAction)
                Button(browser.mode == .folder ? "Choose Folder" : browser.mode == .save ? "Save" : "Open") { browser.choose() }
                    .keyboardShortcut(.defaultAction).disabled(browser.loading)
            }
        }
        .padding(16).frame(minWidth: 720, minHeight: 470)
        .alert("Replace existing file?", isPresented: Binding(get: { browser.overwriteURL != nil }, set: { if !$0 { browser.overwriteURL = nil } }), presenting: browser.overwriteURL) { url in
            Button("Replace", role: .destructive) { browser.complete([url]) }
            Button("Cancel", role: .cancel) { browser.overwriteURL = nil }
        } message: { _ in Text("The existing file will be replaced when you save.") }
    }
    private func location(_ title: String, _ icon: String, _ url: URL) -> some View {
        Button { browser.navigate(url) } label: { Label(title, systemImage: icon) }.buttonStyle(.plain)
    }
}
