import SwiftUI
import AppKit

// Inspired by Redlamp's neutral, color-accurate editing surfaces and its compact
// macOS 26 workspace system. Original SpektraFilmStudio adaptation; no Redlamp source
// has been copied. Exact reference: pdcgomes/redlamp d8a892a (MPL-2.0).
enum StudioLayout {
    static let toolbarHeight: CGFloat = 48
    static let statusHeight: CGFloat = 26
    static let librarySidebarWidth: CGFloat = 240
    static let libraryInspectorWidth: CGFloat = 286
    static let presetSidebarWidth: CGFloat = 252
    static let editorInspectorWidth: CGFloat = 336
    static let filmstripHeight: CGFloat = 112
    static let panelCornerRadius: CGFloat = 16
    static let compactCornerRadius: CGFloat = 8
    static let panelPadding: CGFloat = 14
    static let paneInset: CGFloat = 8
}

enum StudioType {
    static let label = Font.system(size: 11)
    static let value = Font.system(size: 11).monospacedDigit()
    static let panelTitle = Font.system(size: 11.5, weight: .semibold)
    static let section = Font.system(size: 10, weight: .semibold)
    static let caption = Font.system(size: 10)
    static let title = Font.system(size: 13, weight: .semibold)
    static let controlRowHeight: CGFloat = 21
    static let labelWidth: CGFloat = 85
    static let valueWidth: CGFloat = 44
}

// These neutral greys adapt to the user's macOS appearance. Photo pixels remain
// wholly isolated from UI tint, even when a different system accent is selected.
enum StudioPalette {
    private static func surface(dark: CGFloat, light: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let darkMode = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(calibratedWhite: darkMode ? dark : light, alpha: 1)
        })
    }
    static let canvas = surface(dark: 0.075, light: 0.970)
    static let panel = surface(dark: 0.115, light: 0.935)
    static let recessed = surface(dark: 0.060, light: 0.900)
    static let raised = surface(dark: 0.160, light: 0.990)
    static let divider = Color.primary.opacity(0.075)
    static let hover = Color.primary.opacity(0.055)
    static let selected = Color.primary.opacity(0.095)
    static let selectedBorder = Color.primary.opacity(0.38)
    static let subtleBorder = Color.primary.opacity(0.095)
    static let muted = Color.secondary
}

// Blur belongs to the interface, never to the photo or an image stage. This also
// works on macOS 15, where the new macOS 26 native glass is not available.
// Native Liquid Glass on macOS 26 and material fallback on macOS 15.
// No image or output pixels are blended with these window-chrome effects.
private struct StudioGlassPaneModifier: ViewModifier {
    let isPalette: Bool
    @AppStorage("SpektraFilmStudio.ui.glassEnabled") private var enabled = true
    @AppStorage("SpektraFilmStudio.ui.glassTransparency") private var transparency = 0.60
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let opacity = isPalette ? RedlampPaletteMetrics.paneOpacity(1 - transparency) : 1 - transparency
        if reduceTransparency || !enabled {
            content
                .background(StudioPalette.panel, in: shape)
                .clipShape(shape)
                .overlay(shape.strokeBorder(StudioPalette.subtleBorder, lineWidth: 0.5))
        } else if #available(macOS 26.0, *) {
            // Direct Redlamp FloatingPane implementation; no blur on photo pixels.
            content.modifier(RedlampFloatingPane(opacity: opacity))
        } else {
            content
                .background(.regularMaterial, in: shape)
                .background(StudioPalette.panel.opacity(opacity), in: shape)
                .clipShape(shape)
                .overlay(shape.strokeBorder(StudioPalette.subtleBorder, lineWidth: 0.5))
        }
    }
}

extension View {
    func studioGlassPane() -> some View { modifier(StudioGlassPaneModifier(isPalette: false)) }
    func studioFloatingPane() -> some View { studioGlassPane() }
    func studioOmniPane() -> some View { modifier(StudioGlassPaneModifier(isPalette: true)) }
}

struct StudioPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background(StudioPalette.panel.opacity(0.16))
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
