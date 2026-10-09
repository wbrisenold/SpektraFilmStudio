import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One asynchronous browser for all studio open/save actions. NSOpenPanel itself
/// can hang before presentation while its XPC service resolves stale drive bookmarks.
@MainActor
enum SpektraFilePanel {
    private static var controller: BrowserWindow?
    private(set) static var lastPresentation = "not presented"
    static var isPickerVisible: Bool { controller?.window?.isVisible == true }

    @discardableResult
    static func chooseFiles(title: String, types: [UTType]? = nil, multiple: Bool = false,
                            completion: @escaping @MainActor ([URL]) -> Void) -> Bool {
        present(title: title, mode: .files, types: types ?? [], multiple: multiple) {
            if !$0.isEmpty { completion($0) }
        }
    }

    @discardableResult
    static func chooseFolder(title: String, completion: @escaping @MainActor (URL) -> Void) -> Bool {
        present(title: title, mode: .folder) { if let url = $0.first { completion(url) } }
    }

    static func folder(title: String) async -> URL? {
        await withCheckedContinuation { continuation in
            let started = present(title: title, mode: .folder) { continuation.resume(returning: $0.first) }
            if !started { continuation.resume(returning: nil) }
        }
    }

    static func saveFile(title: String, types: [UTType], filename: String,
                         completion: @escaping @MainActor (URL?) -> Void) {
        let started = present(title: title, mode: .save, types: types, filename: filename) { completion($0.first) }
        if !started { completion(nil) }
    }

    @discardableResult
    private static func present(title: String, mode: StudioFileBrowser.Mode, types: [UTType] = [],
                                multiple: Bool = false, filename: String = "",
                                completion: @escaping @MainActor ([URL]) -> Void) -> Bool {
        guard controller == nil else {
            controller?.window?.makeKeyAndOrderFront(nil)
            return false
        }
        let owner = NSApp.keyWindow ?? NSApp.mainWindow
        var finished = false
        let browser = StudioFileBrowser(mode: mode, types: types, multiple: multiple, filename: filename) { urls in
            guard !finished, let current = controller else { return }
            finished = true
            controller = nil
            if let window = current.window, let parent = window.sheetParent { parent.endSheet(window) }
            current.window?.orderOut(nil)
            lastPresentation = urls.isEmpty ? "cancelled" : "selected \(urls.count) item(s)"
            // Leave sheet teardown before model callbacks can replace the workspace.
            Task { @MainActor in completion(urls) }
        }
        let current = BrowserWindow(browser: browser, title: title)
        controller = current
        if let owner, owner.sheetParent == nil, owner.attachedSheet == nil, let window = current.window {
            lastPresentation = "sheet: \(title)"
            owner.beginSheet(window)
        } else {
            lastPresentation = "foreground: \(title)"
            current.window?.level = .floating
            current.showWindow(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        current.window?.makeKeyAndOrderFront(nil)
        browser.navigate(FileManager.default.homeDirectoryForCurrentUser)
        return true
    }

    private final class BrowserWindow: NSWindowController, NSWindowDelegate {
        let browser: StudioFileBrowser
        init(browser: StudioFileBrowser, title: String) {
            self.browser = browser
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 500),
                                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = title
            panel.isReleasedWhenClosed = false
            panel.contentViewController = NSHostingController(rootView: StudioFileBrowserView(browser: browser))
            super.init(window: panel)
            panel.delegate = self
            panel.center()
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func windowShouldClose(_ sender: NSWindow) -> Bool { browser.cancel(); return false }
    }
}

extension SpektraFilePanel {
    static func captureDocumentationBrowser(directory: URL, destination: URL) async -> Bool {
        guard let current = controller else { return false }
        current.browser.navigate(directory)
        try? await Task.sleep(for: .milliseconds(900))
        guard let view = current.window?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: destination) } catch { return false }
        current.browser.cancel()
        return true
    }

    static func runSmokeTest(model: AppModel) async -> Bool {
        model.didStartProjectWorkflow = true
        func report(_ name: String, _ passed: Bool) -> Bool {
            print("PICKER \(name): \(passed ? "PASS" : "FAIL")")
            fflush(stdout)
            return passed
        }
        @MainActor func waitFor(_ predicate: () -> Bool) async -> Bool {
            for _ in 0..<100 {
                if predicate() { return true }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return predicate()
        }
        NSApp.activate(ignoringOtherApps: true)
        guard await waitFor({ NSApp.windows.contains { $0.isVisible } }) else { return report("app window visible", false) }
        NSApp.windows.first(where: { $0.isVisible })?.makeKeyAndOrderFront(nil)
        let actions: [(String, () -> Void)] = [
            ("open project", { model.openProject() }),
            ("standalone photo", { model.standalonePhotoMode() }),
            ("import images", { model.importImages() }),
            ("import folder", { model.importFolder() }),
            ("open cloud library", { model.openICloudLibrary() }),
            ("cloud destination", { model.moveCurrentLibraryToICloud() }),
            ("scratch folder", { model.chooseExternalOriginalScratch() }),
            ("cache folder", { model.chooseCacheFolder() }),
            ("export folder", { model.chooseExportDestination() }),
            ("import presets", { model.importPreset() })
        ]
        for (name, action) in actions {
            action()
            guard await waitFor({ isPickerVisible }) else { return report(name, false) }
            controller?.browser.cancel()
            guard await waitFor({ controller == nil }) else { return report(name + " cancel", false) }
            _ = report(name + " open/cancel", true)
        }
        model.showingLightroomImportWizard = true
        guard await waitFor({ NSApp.windows.contains { $0.attachedSheet != nil || $0.sheetParent != nil } })
        else { return report("wizard sheet", false) }
        // Guided imports now request their source immediately on presentation.
        guard await waitFor({ isPickerVisible }) else { return report("wizard opens source immediately", false) }
        controller?.browser.cancel()
        guard await waitFor({ controller == nil }) else { return false }
        var selected: URL?
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SpektraPicker-" + UUID().uuidString)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { return report("fixture folder", false) }
        defer {
            controller?.browser.cancel()
            model.showingLightroomImportWizard = false
            try? FileManager.default.removeItem(at: folder)
        }
        guard chooseFolder(title: "Nested Wizard Picker Smoke Test", completion: { selected = $0 }),
              await waitFor({ isPickerVisible }), report("nested foreground", lastPresentation.hasPrefix("foreground:"))
        else { return false }
        let original = controller
        guard report("duplicate rejected", !chooseFolder(title: "Duplicate") { _ in } && controller === original) else { return false }
        controller?.browser.navigate(folder)
        guard await waitFor({ controller?.browser.loading == false }) else { return false }
        controller?.browser.choose()
        guard await waitFor({ selected != nil && controller == nil }),
              report("selected folder callback", selected?.standardizedFileURL == folder.standardizedFileURL) else { return false }
        var cancelledCallback = false
        guard chooseFiles(title: "Reopen", completion: { _ in cancelledCallback = true }),
              await waitFor({ isPickerVisible }) else { return report("reopen", false) }
        controller?.browser.cancel()
        try? await Task.sleep(for: .milliseconds(100))
        guard report("cancel leaves callback untouched", !cancelledCallback) else { return false }
        model.showingLightroomImportWizard = false
        try? await Task.sleep(for: .milliseconds(400))
        let responsive = await StudioFileBrowser.runResponsivenessTest(in: folder)
        guard report("slow folder timeout and stale-result recovery", responsive) else { return false }
        var saved: Bool?
        model.saveProject(asNew: true) { saved = $0 }
        guard await waitFor({ isPickerVisible }) else { return report("save picker", false) }
        controller?.browser.cancel()
        guard await waitFor({ saved != nil }), report("save cancellation", saved == false) else { return false }
        saved = nil
        model.saveProject(asNew: true) { saved = $0 }
        controller?.browser.navigate(folder)
        controller?.browser.filename = "Saved.spektrafilm"
        guard await waitFor({ controller?.browser.loading == false }) else { return false }
        controller?.browser.choose()
        guard await waitFor({ saved != nil }), report("save callback and write", saved == true) else { return false }
        // Select a real serialized project through the same browser used by Open.
        let projectURL = folder.appendingPathComponent("Smoke.spektrafilm")
        var document = SpektraProjectDocument()
        document.name = "Picker End-to-End Test"
        document.images = [ProjectImageRecord(sourcePath: folder.appendingPathComponent("Missing.jpg").path, captureDate: nil)]
        document.selectedImageID = document.images.first?.id
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(document).write(to: projectURL)
        } catch { return report("project fixture", false) }
        model.openProject()
        controller?.browser.navigate(folder)
        guard await waitFor({ controller?.browser.loading == false }) else { return false }
        controller?.browser.selection = [projectURL]
        controller?.browser.choose()
        guard await waitFor({ model.projectURL == projectURL }),
              report("project decoded into Library", model.project.name == document.name && !model.showProjectHome && model.page == .library) else { return false }
        do {
            let original = folder.appendingPathComponent("copy-source.bin")
            let copy = folder.appendingPathComponent("copy-destination.bin")
            try Data([1, 2, 3]).write(to: original)
            try SpektraCloudLibrary.streamCopy(from: original, to: copy)
            try SpektraCloudLibrary.streamCopy(from: original, to: copy)
            try Data([4, 5, 6]).write(to: original)
            do {
                try SpektraCloudLibrary.streamCopy(from: original, to: copy)
                return report("conflicting cloud copy rejected", false)
            } catch SpektraCloudLibrary.CloudError.destinationConflict { }
            guard report("cloud copy preserves conflicting existing bytes", try Data(contentsOf: copy) == Data([1, 2, 3])) else { return false }
        } catch { return report("cloud copy regression", false) }
        let malformed = folder.appendingPathComponent("Broken.spektrafilm")
        do { try Data("not json".utf8).write(to: malformed) } catch { return false }
        model.openProject()
        controller?.browser.navigate(folder)
        guard await waitFor({ controller?.browser.loading == false }) else { return false }
        controller?.browser.selection = [malformed]
        controller?.browser.choose()
        guard await waitFor({ model.status.hasPrefix("Open failed:") }) else { return false }
        return report("malformed project preserves workspace", model.projectURL == projectURL && model.project.name == document.name)
    }
}
