import SwiftUI
import AppKit

enum StudioLayout {
    static let toolbarHeight: CGFloat = 48
    static let statusHeight: CGFloat = 26
    static let librarySidebarWidth: CGFloat = 212
    static let libraryInspectorWidth: CGFloat = 286
    static let presetSidebarWidth: CGFloat = 270
    static let editorInspectorWidth: CGFloat = 336
    static let filmstripHeight: CGFloat = 112
    static let panelCornerRadius: CGFloat = 10
    static let compactCornerRadius: CGFloat = 7
    static let panelPadding: CGFloat = 10
}

enum StudioPalette {
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let recessed = Color(nsColor: .underPageBackgroundColor)
    static let divider = Color.primary.opacity(0.10)
    static let hover = Color.primary.opacity(0.055)
    static let selected = Color.primary.opacity(0.10)
    static let selectedBorder = Color.primary.opacity(0.72)
    static let subtleBorder = Color.primary.opacity(0.11)
    static let muted = Color.secondary
}

struct StudioPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background(StudioPalette.panel)
    }
}

struct StudioIconButton: View {
    let systemImage: String
    let help: String
    var isSelected = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 27, height: 27)
                .background(isSelected ? StudioPalette.selected : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct StudioSelectionOutline: ViewModifier {
    let selected: Bool

    func body(content: Content) -> some View {
        content
            .background(selected ? StudioPalette.selected : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? StudioPalette.selectedBorder : StudioPalette.subtleBorder, lineWidth: selected ? 1 : 0.5)
            }
    }
}

extension View {
    func studioSelection(_ selected: Bool) -> some View {
        modifier(StudioSelectionOutline(selected: selected))
    }
}

struct SpektraApplicationIconView: View {
    private var iconImage: NSImage {
        let bundle = Bundle.main
        if let url = bundle.url(forResource: "SpektraFilm", withExtension: "icns"),
           let image = NSImage(contentsOfFile: url.path) {
            return image
        }
        if let url = bundle.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOfFile: url.path) {
            return image
        }
        return NSApp.applicationIconImage
    }

    var body: some View {
        Image(nsImage: iconImage)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
    }
}
