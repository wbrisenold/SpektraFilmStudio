import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Captures the real native views at compact and wide desktop sizes, using temporary photos.
@MainActor
enum StudioUXSmokeTest {
    static func run(model: AppModel) async -> Bool {
        guard let window = NSApp.windows.first(where: { $0.contentView != nil && $0.canBecomeMain }) else { return false }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpektraUX-\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let photo = root.appendingPathComponent("Photo.jpg")
            var pixels = [Float](repeating: 1, count: 320 * 200 * 4)
            for y in 0..<200 { for x in 0..<320 {
                let p = (y * 320 + x) * 4
                pixels[p] = Float(x) / 320
                pixels[p + 1] = Float(y) / 200
                pixels[p + 2] = 0.4
            } }
            guard let cg = PixelBufferF32(width: 320, height: 200, pixels: pixels).makeCGImage8(colorSpace: CGColorSpaceCreateDeviceRGB()),
                  let writer = CGImageDestinationCreateWithURL(photo as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
            CGImageDestinationAddImage(writer, cg, nil)
            guard CGImageDestinationFinalize(writer) else { return false }
            if let index = CommandLine.arguments.firstIndex(of: "--ux-fixture"), index + 1 < CommandLine.arguments.count {
                try FileManager.default.removeItem(at: photo)
                try FileManager.default.copyItem(atPath: CommandLine.arguments[index + 1], toPath: photo.path)
            }
            var image = ProjectImageRecord(sourcePath: photo.path, captureDate: nil)
            image.flag = .picked
            image.selectedForExport = true
            model.project.images = [image]
            model.project.selectedImageID = image.id
            model.project.name = "Workflow Review"
            model.project.preferences.autosaveEnabled = false
            model.project.preferences.scopeMode = .histogram
            model.isProjectDirty = false
            model.librarySelection = [image.id]
            for (label, size) in [("compact", NSSize(width: 1100, height: 760)), ("wide", NSSize(width: 1440, height: 900))] {
                window.setContentSize(size)
                model.page = .library
                model.showProjectHome = true
                guard await capture(window, to: root.appendingPathComponent("\(label)-home.png")) else { return false }
                for page in WorkspacePage.allCases {
                    model.showProjectHome = false
                    model.page = page
                    if page == .edit {
                        for _ in 0..<100 {
                            if model.frameState.renderedPreview != nil && !model.frameState.isRendering { break }
                            try? await Task.sleep(for: .milliseconds(200))
                        }
                        guard model.frameState.renderedPreview != nil else {
                            print("UX_SMOKE_FAIL editor preview missing"); return false
                        }
                    }
                    guard await capture(window, to: root.appendingPathComponent("\(label)-\(page.rawValue).png")) else { return false }
                }
            }
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 700, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.contentView = NSHostingView(rootView: StudioImportWizard(model: model))
            panel.orderFront(nil)
            guard await capture(panel, to: root.appendingPathComponent("advanced-import.png")) else { return false }
            guard await SpektraFilePanel.captureDocumentationBrowser(directory: root, destination: root.appendingPathComponent("file-browser.png")) else { return false }
            panel.contentView = NSHostingView(rootView: SettingsView(model: model))
            panel.setContentSize(NSSize(width: 660, height: 540))
            guard await capture(panel, to: root.appendingPathComponent("settings.png")) else { return false }
            panel.contentView = NSHostingView(rootView: ControlsView(model: model, mode: .film, initialSection: "film.film").background(StudioPalette.panel).preferredColorScheme(.dark))
            panel.setContentSize(NSSize(width: 360, height: 760))
            guard await capture(panel, to: root.appendingPathComponent("film-inspector.png")) else { return false }
            panel.contentView = NSHostingView(rootView: FilmEffectsPanel(model: model).background(StudioPalette.panel).preferredColorScheme(.dark))
            panel.setContentSize(NSSize(width: 360, height: 580))
            guard await capture(panel, to: root.appendingPathComponent("film-finish.png")) else { return false }
            panel.setContentSize(NSSize(width: 360, height: 760))
            var grade = LocalGradeRecord(name: "Subject Light")
            grade.masks.sources = [MaskSourceRecord(name: "Radial", kind: .radial)]
            model.project.images[0].look.localGrades = [grade]
            model.selectLocalGrade(grade.id)
            panel.contentView = NSHostingView(rootView: ControlsView(model: model, mode: .masks).background(StudioPalette.panel).preferredColorScheme(.dark))
            guard await capture(panel, to: root.appendingPathComponent("masks-inspector.png")) else { return false }
            panel.contentView = NSHostingView(rootView: ExportWorkspaceView(model: model).documentationSettings)
            panel.setContentSize(NSSize(width: 540, height: 720))
            guard await capture(panel, to: root.appendingPathComponent("export-settings.png")) else { return false }
            panel.contentView = NSHostingView(rootView: CullWorkspaceView(model: model, initialFiltersVisible: true).preferredColorScheme(.dark))
            panel.setContentSize(NSSize(width: 1100, height: 760))
            guard await capture(panel, to: root.appendingPathComponent("cull-filters.png")) else { return false }
            panel.orderOut(nil)
            print("UX_SMOKE_PASS screenshots=\(root.path)")
            return true
        } catch {
            print("UX_SMOKE_FAIL \(error.localizedDescription)")
            return false
        }
    }

    private static func capture(_ window: NSWindow, to url: URL) async -> Bool {
        try? await Task.sleep(for: .milliseconds(900))
        guard let view = window.contentView else { return false }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]), data.count > 1000 else { return false }
        do { try data.write(to: url); return true } catch { return false }
    }
}
