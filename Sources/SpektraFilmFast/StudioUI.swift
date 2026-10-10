import SwiftUI
import AppKit

// Inspired by Redlamp's neutral, color-accurate editing surfaces and its compact
// macOS 26 workspace system. Original SpektraFilmStudio adaptation; no Redlamp source
// has been copied. Exact reference: pdcgomes/redlamp d8a892a (MPL-2.0).
enum StudioLayout {
    static let toolbarHeight: CGFloat = 48
    static let statusHeight: CGFloat = 26
    static let presetSidebarWidth: CGFloat = 300
    static let editorInspectorWidth: CGFloat = 316
    static let panelCornerRadius: CGFloat = 16
    static let compactCornerRadius: CGFloat = 8
    static let panelPadding: CGFloat = 14
    static let paneInset: CGFloat = 8
    /// Redlamp PanelMetrics: the filmstrip floats at a fixed height and is
    /// revealed by hovering the bottom edge, so neither value is user-resizable.
    static let filmstripHeight: CGFloat = 110
    static let filmstripTrigger: CGFloat = 14
}

/// Redlamp Typography.swift + Metrics.swift, verbatim. `section` carries the
/// 0.6pt tracking and the row metrics are Redlamp's (76pt labels, 20pt rows),
/// which is why our rows were visibly wider and looser than Redlamp's.
enum StudioType {
    // MARK: Typography
    static let label = Font.system(size: 11)
    static let value = Font.system(size: 11).monospacedDigit()
    static let panelTitle = Font.system(size: 11.5, weight: .semibold)
    /// Redlamp Typography.section: 10pt semibold, 0.6pt letter spacing.
    static let section = Font.system(size: 10, weight: .semibold)
    static let sectionTracking: CGFloat = 0.6
    static let caption = Font.system(size: 10)
    static let badge = Font.system(size: 9, weight: .medium)

    // MARK: Metrics
    static let labelWidth: CGFloat = 76
    static let valueWidth: CGFloat = 44
    static let rowHeight: CGFloat = 20
    static let rowSpacing: CGFloat = 6
    static let panelRowSpacing: CGFloat = 3
    static let panelSymbolSlot: CGFloat = 16
    static let controlRowMinHeight: CGFloat = 24
    static let thumbSize: CGFloat = 11
    static let trackHeight: CGFloat = 16
    static let subsectionTopPadding: CGFloat = 10
    static let subsectionBottomPadding: CGFloat = 2
    static let groupGap: CGFloat = 4
    static let cardRadius: CGFloat = 8
    static let cardPadding: CGFloat = 8
}

// These neutral greys adapt to the user's macOS appearance. Photo pixels remain
// wholly isolated from UI tint, even when a different system accent is selected.
/// Redlamp's Palette.swift `standard` tokens, verbatim.
///
/// The previous values used `Color.primary` / `Color.secondary`, which are the
/// *system* label colors — blue-tinted on macOS. Redlamp's editing surfaces are
/// deliberately neutral: an explicit white-alpha ramp over near-black, so nothing
/// tints the photographer's judgement of colour. That difference is most of why our
/// rail did not read as Redlamp's.
enum StudioPalette {
    private static func white(_ alpha: CGFloat) -> Color { Color.white.opacity(alpha) }
    private static func black(_ alpha: CGFloat) -> Color { Color.black.opacity(alpha) }

    // MARK: Text ramp
    static let label = white(0.72)
    static let labelHover = white(0.95)
    static let secondaryLabel = white(0.45)
    static let tertiaryLabel = white(0.28)
    static let value = white(0.90)

    // MARK: Surfaces
    /// The canvas the photo sits on: black 0.28 behind everything.
    static let canvas = black(0.28)
    /// Floating pane fill.
    static let panel = white(0.115)
    /// Wells (histogram, tool strip, pickers).
    static let recessed = black(0.28)
    static let raised = white(0.16)

    // MARK: Lines and states
    static let divider = white(0.07)
    static let hover = white(0.055)
    static let selected = white(0.10)
    static let selectedBorder = white(0.38)
    static let subtleBorder = white(0.07)

    // MARK: Slider
    static let track = white(0.16)
    static let trackFill = white(0.55)
    static let thumb = white(0.92)
    static let editedDot = white(0.55)

    static let muted = secondaryLabel
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
    // Redlamp uses one FloatingPane for every overlay panel; only the palette
    // (⌘K) gets a different surface. Keeping these aliases distinct invited
    // pages to drift into different corner radii.
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

// SFS-UI-SETTINGS-20261009-R2: Redlamp-style collapsible panel header.
// Edited state is derived from real RenderLook values, not UI-only state.
struct StudioDevelopSectionHeader: View {
    let title: String
    let expanded: Bool
    let edited: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 12)
                Text(title)
                    .font(StudioType.panelTitle)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if edited {
                    Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                        .accessibilityLabel("Edited")
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, StudioLayout.panelPadding)
            .frame(height: RedlampMetrics.panelHeaderHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(expanded ? "expanded" : "collapsed")")
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

/// Redlamp draws its own slider (SliderTrackView): a 16pt rounded track at
/// white 0.16 with a white 0.55 fill and an 11pt white 0.92 thumb. The system
/// `Slider` is a different height, a different thumb and a blue fill, which is
/// the most obvious remaining difference in the rail.

/// ⌘-scroll capture for SwiftUI views. SwiftUI has no scrollWheel hook, so a
/// transparent NSView intercepts the event; the handler returns true to consume.
private final class CommandScrollWheelCaptureView: NSView {
    var handler: (Double, NSEvent.ModifierFlags) -> Bool = { _, _ in false }

    override func scrollWheel(with event: NSEvent) {
        if handler(event.scrollingDeltaY, event.modifierFlags) { return }
        super.scrollWheel(with: event)
    }
}

private struct CommandScrollWheelRepresentable: NSViewRepresentable {
    let handler: (Double, NSEvent.ModifierFlags) -> Bool

    func makeNSView(context: Context) -> CommandScrollWheelCaptureView {
        let view = CommandScrollWheelCaptureView()
        view.handler = handler
        return view
    }

    func updateNSView(_ nsView: CommandScrollWheelCaptureView, context: Context) {
        nsView.handler = handler
    }
}

extension View {
    /// Handler receives (scrollingDeltaY, modifierFlags); return true to consume.
    func onScrollWheel(_ handler: @escaping (Double, NSEvent.ModifierFlags) -> Bool) -> some View {
        background(CommandScrollWheelRepresentable(handler: handler))
    }
}

struct StudioSliderTrack: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var enabled: Bool = true
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var dragging = false
    /// Redlamp accumulates precise scroll deltas so a trackpad nudge moves one step
    /// rather than a hair (SliderRowView.scrollWheel).
    @State private var scrollRemainder: Double = 0

    private var step: Double {
        let span = range.upperBound - range.lowerBound
        return span > 0 ? span / 100 : 0
    }

    private func clamp(_ raw: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, raw))
    }

    /// ⌘-scroll adjusts the slider (Shift x10, Option x0.1), as Redlamp does.
    private func adjust(by steps: Double, flags: NSEvent.ModifierFlags, onEdit: @escaping (Double) -> Void) {
        let multiplier = flags.contains(.shift) ? 10.0 : flags.contains(.option) ? 0.1 : 1.0
        onEdit(clamp(value + steps * step * multiplier))
    }

    /// `,` `.` select the slider; `-` `=` nudge it, as Redlamp's FocusMarker does.
    func handleKey(_ key: KeyEquivalent, flags: NSEvent.ModifierFlags, onEdit: @escaping (Double) -> Void) {
        let nudge: Double? = switch key {
        case KeyEquivalent("-"): -1
        case KeyEquivalent("="): 1
        default: nil
        }
        if let nudge {
            adjust(by: nudge, flags: flags, onEdit: onEdit)
            return
        }
        if key == KeyEquivalent(",") || key == KeyEquivalent(".") {
            adjust(by: flags.contains(.shift) ? 10 : 1, flags: flags, onEdit: onEdit)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let span = range.upperBound - range.lowerBound
            let fraction = span > 0 ? min(1, max(0, (value - range.lowerBound) / span)) : 0
            // Use ONE coordinate system for the visible thumb, filled track,
            // click position and drag position. The thumb's center moves only
            // across the usable width; capsule and circle are both vertically
            // centered by the same ZStack (no .position into a 4pt child view).
            let thumbRadius = StudioType.thumbSize / 2
            let usableWidth = max(0, width - StudioType.thumbSize)
            let thumbX = thumbRadius + usableWidth * fraction

            ZStack(alignment: .leading) {
                Capsule().fill(StudioPalette.track)
                    .frame(height: StudioType.trackHeight)
                Capsule()
                    .fill(StudioPalette.trackFill)
                    .frame(width: thumbX, height: StudioType.trackHeight)
                Circle()
                    .fill(StudioPalette.thumb)
                    .frame(width: StudioType.thumbSize, height: StudioType.thumbSize)
                    .offset(x: thumbX - thumbRadius)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onScrollWheel { delta, flags in
                guard flags.contains(.command), enabled else { return false }
                scrollRemainder += delta
                let steps = scrollRemainder.rounded(.towardZero)
                guard steps != 0 else { return true }
                scrollRemainder -= steps
                let flagsNow = NSEvent.modifierFlags
                let multiplier = flagsNow.contains(.shift) ? 10.0 : flagsNow.contains(.option) ? 0.1 : 1.0
                if !dragging { dragging = true; onEditingChanged(true) }
                value = clamp(value + steps * step * multiplier)
                return true
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard enabled, span > 0 else { return }
                        if !dragging { dragging = true; onEditingChanged(true) }
                        let usable = max(1, usableWidth)
                        let t = min(1, max(0, (drag.location.x - StudioType.thumbSize / 2) / usable))
                        value = clamp(range.lowerBound + t * span)
                    }
                    .onEnded { _ in
                        guard dragging else { return }
                        dragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: StudioType.controlRowMinHeight)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityValue(String(format: "%.0f", value))
    }
}
