import AppKit
import Foundation
import UniformTypeIdentifiers

/// One visible, non-blocking, native system file chooser for the whole studio.
///
/// In v0.6.8 multiple SwiftUI `.fileImporter` modifiers were attached to the same
/// workspace and to nested import/setup sheets. In practice those presentations
/// could be dropped without an error, leaving Open/Import buttons inert.
///
/// `NSOpenPanel.begin` runs asynchronously; unlike `runModal` it does not start
/// another nested modal event loop. An app-modal chooser also works when an
/// import/setup SwiftUI sheet is already visible. Only ONE chooser is active.
@MainActor
enum SpektraFilePanel {
    private static var activePanel: NSOpenPanel?

    @discardableResult
    static func chooseFiles(
        title: String,
        types: [UTType]? = nil,
        multiple: Bool = false,
        completion: @escaping @MainActor ([URL]) -> Void
    ) -> Bool {
        present(title: title, chooseDirectories: false, types: types,
                multiple: multiple, completion: completion)
    }

    @discardableResult
    static func chooseFolder(
        title: String,
        completion: @escaping @MainActor (URL) -> Void
    ) -> Bool {
        present(title: title, chooseDirectories: true, types: nil, multiple: false) { urls in
            if let folder = urls.first { completion(folder) }
        }
    }

    @discardableResult
    private static func present(
        title: String,
        chooseDirectories: Bool,
        types: [UTType]?,
        multiple: Bool,
        completion: @escaping @MainActor ([URL]) -> Void
    ) -> Bool {
        // Do not race two panels or silently replace an existing system dialog.
        guard activePanel == nil else {
            NSSound.beep()
            return false
        }

        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = chooseDirectories ? "Choose Folder" : "Open"
        panel.canChooseFiles = !chooseDirectories
        panel.canChooseDirectories = chooseDirectories
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = multiple && !chooseDirectories
        panel.resolvesAliases = true
        if let types, !types.isEmpty { panel.allowedContentTypes = types }

        activePanel = panel
        // Bring the application forward first; a nonactivating SwiftUI sheet or
        // a stale keyWindow must not hide the Finder-style system chooser.
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak panel] response in
            // AppKit's completion runs on the main event loop. Make actor isolation
            // explicit under Swift 6 rather than passing NSOpenPanel across tasks.
            MainActor.assumeIsolated {
                let urls = response == .OK ? (panel?.urls ?? []) : []
                activePanel = nil
                if response == .OK { completion(urls) }
            }
        }
        return true
    }
}
