import SwiftUI
import AppKit
import Darwin

@main
struct SpektraFilmFastApp: App {
    @NSApplicationDelegateAdaptor(SpektraApplicationDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear {
                    if CommandLine.arguments.contains("--mask-overlay-self-test") {
                        exit(Int32(RedlampMaskSmokeTest.run()))
                    } else if CommandLine.arguments.contains("--self-test") || CommandLine.arguments.contains("--studio-soak-test") {
                        Task {
                            let result = CommandLine.arguments.contains("--studio-soak-test")
                                ? await ProductionSelfTest.runSoak()
                                : await ProductionSelfTest.run()
                            fflush(stdout)
                            fflush(stderr)
                            exit(result)
                        }
                    } else {
                        ShortcutMonitor.shared.install(model: model)
                        appDelegate.model = model
                        Task { await model.promptForRecoveryIfAvailable() }
                    }
                }
        }
        .commands { SpektraCommands(model: model) }

        Settings { SettingsView(model: model) }
    }
}

struct SpektraCommands: Commands {
    @ObservedObject var model: AppModel
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project") { model.newProject() }.keyboardShortcut("n")
            Button("Open Project…") { model.openProject() }.keyboardShortcut("o")
            Button("Standalone Photo Mode…") { model.standalonePhotoMode() }.keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("Import Folder…") { model.importFolder() }.keyboardShortcut("i")
            Button("Import Images…") { model.importImages() }.keyboardShortcut("i", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Project") { model.saveProject() }.keyboardShortcut("s")
            Button("Save Project As…") { model.saveProject(asNew: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
        }
        CommandMenu("Cloud Library") {
            Button("Import Lightroom Catalog to iCloud…") { model.importLightroomCatalogToICloud() }
            Button("Move Current Library to iCloud…") { model.moveCurrentLibraryToICloud() }
                .disabled(model.project.images.isEmpty || model.isCloudLibraryConnected)
            Button("Open iCloud Library…") { model.openICloudLibrary() }
            Divider()
            Button("Sync Now") { Task { await model.synchronizeCloudNow() } }
                .disabled(!model.isCloudLibraryConnected || model.isCloudSyncing)
            Button("Keep Selected Downloaded") { model.keepSelectedCloudOriginalsDownloaded() }
                .disabled(!model.isCloudLibraryConnected)
            Button("Free Selected Local Copies") { model.freeSelectedCloudOriginals() }
                .disabled(!model.isCloudLibraryConnected)
            Divider()
            Button("Disconnect iCloud Library") { model.disconnectCloudLibrary() }
                .disabled(!model.isCloudLibraryConnected)
        }
        CommandMenu("Media") {
            Button("Relink Missing Media…") { model.relinkMissingMedia() }
            Divider()
            Button("Reveal Cache in Finder") { model.revealCacheInFinder() }
            Button("Choose Cache Folder…") { model.chooseCacheFolder() }
            Button("Clear Local Caches") { model.clearLocalCaches() }
        }
        CommandMenu("Edit Look") {
            Button("Undo Look") { model.undo() }.keyboardShortcut("z")
            Button("Redo Look") { model.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
            Divider()
            Button("Copy Look") { model.copyLook() }.keyboardShortcut("c", modifiers: [.command, .option])
            Button("Paste Look") { model.pasteLook() }.keyboardShortcut("v", modifiers: [.command, .option])
            Button("Reset Look") { model.resetLook() }
        }
        CommandMenu("Photo") {
            Button("Previous") { model.selectRelative(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("Next") { model.selectRelative(1) }.keyboardShortcut(.rightArrow, modifiers: [])
            Divider()
            Button("Rate 1") { model.setRating(1) }.keyboardShortcut("1", modifiers: [])
            Button("Rate 2") { model.setRating(2) }.keyboardShortcut("2", modifiers: [])
            Button("Rate 3") { model.setRating(3) }.keyboardShortcut("3", modifiers: [])
            Button("Rate 4") { model.setRating(4) }.keyboardShortcut("4", modifiers: [])
            Button("Rate 5") { model.setRating(5) }.keyboardShortcut("5", modifiers: [])
            Divider()
            Button("Pick") { model.setFlag(.picked) }
            Button("Reject") { model.setFlag(.rejected) }
            Button("Unflag") { model.setFlag(.unflagged) }
        }
    }
}

@MainActor
final class SpektraApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftPM is packaged into a hand-built .app bundle. Set the Dock/app-switcher
        // icon explicitly so Finder, the Dock, and the in-app brand mark all use the
        // bundled SpektraFilm artwork instead of the generic executable icon.
        if let url = Bundle.main.url(forResource: "SpektraFilm", withExtension: "icns"),
           let icon = NSImage(contentsOfFile: url.path) {
            NSApp.applicationIconImage = icon
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        return model.prepareForTermination() ? .terminateNow : .terminateCancel
    }
}

@MainActor
final class ShortcutMonitor {
    static let shared = ShortcutMonitor()
    private var monitor: Any?

    func install(model: AppModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model] event in
            // AppKit local event monitors are delivered on the main thread, but Swift 6 does
            // not infer MainActor isolation for this escaping callback. Make the boundary
            // explicit so AppModel access stays actor-correct without per-keypress Tasks.
            // Return Bool (not NSEvent) so the non-Sendable event never crosses the
            // isolation boundary; the outer closure maps it back to nil/event.
            let handled: Bool = MainActor.assumeIsolated {
                guard let model else { return false }
                // Never intercept native text editing / search / numeric fields.
                if NSApp.keyWindow?.firstResponder is NSTextView || NSApp.keyWindow?.firstResponder is NSTextField { return false }
                let key = Self.keyName(event)
                let shortcutFlags = event.modifierFlags.intersection([.command, .option, .control, .shift])
                if model.page == .edit, shortcutFlags == .command {
                    if key.lowercased() == "c" { model.copyLook(); return true }
                    if key.lowercased() == "v" { model.pasteLook(); return true }
                }
                let p = model.project.preferences
                let inLibrary = model.page == .library

                @MainActor func applyRating(_ value: Int) {
                    if inLibrary { model.batchSetRating(value) }
                    else { model.setRating(value) }
                }
                @MainActor func applyFlag(_ value: ProjectFlag) {
                    if inLibrary { model.batchSetFlag(value) }
                    else { model.setFlag(value) }
                }

                // Lightroom-style number keys work anywhere; in Library they apply to the
                // highlighted set instead of silently changing only the active thumbnail.
                if event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                   let value = Int(key), (0...5).contains(value) {
                    applyRating(value)
                    return true
                }

                if inLibrary,
                   event.modifierFlags.contains(.command),
                   key.lowercased() == "a" {
                    model.selectAllVisible()
                    return true
                }

                switch key.lowercased() {
                case p.shortcutPrevious.lowercased(): model.selectRelative(-1); return true
                case p.shortcutNext.lowercased(): model.selectRelative(1); return true
                case p.shortcutPick.lowercased(): applyFlag(.picked); return true
                case p.shortcutReject.lowercased(): applyFlag(.rejected); return true
                case p.shortcutUnflag.lowercased(): applyFlag(.unflagged); return true
                default: return false
                }
            }
            return handled ? nil : event
        }
    }

    private static func keyName(_ event: NSEvent) -> String {
        switch event.keyCode {
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        default: return event.charactersIgnoringModifiers ?? ""
        }
    }
}
