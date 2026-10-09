// SPDX-License-Identifier: MPL-2.0
// Adapted from pdcgomes/redlamp at d8a892a259ccdaa12f1041ff01f88ce8e7ce68af.
// Originals:
// packages/RedlampUI/Sources/Editor/EditorView.swift (FloatingPane)
// packages/RedlampDesign/Sources/Tokens/Metrics.swift
// packages/RedlampUI/Sources/CommandPalette/CommandPaletteView.swift (PaletteMetrics)
// packages/RedlampUI/Sources/CommandPalette/PaletteQueryField.swift
// Name and owning-theme changes allow the controls to run inside SpektraFilmStudio's
// existing SwiftUI app target; the original Redlamp rendering logic is preserved.
import AppKit
import SwiftUI

// Direct port of Redlamp's exact panel metrics, with namespace changed to avoid
// colliding with host app symbols.
enum RedlampMetrics {
    static let labelWidth: CGFloat = 76
    static let valueWidth: CGFloat = 44
    static let rowHeight: CGFloat = 20
    static let rowSpacing: CGFloat = 6
    static let panelRowSpacing: CGFloat = 3
    static let panelPadding: CGFloat = 14
    static let panelBottomPadding: CGFloat = 14
    static let panelHeaderHeight: CGFloat = 32
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

enum RedlampPaletteMetrics {
    static let width: CGFloat = 620
    static let rowHeight: CGFloat = 32
    static let headerHeight: CGFloat = 26
    static let maxListHeight: CGFloat = 372
    static func paneOpacity(_ panelOpacity: Double) -> Double {
        max(panelOpacity, 0.78)
    }
}

/// Redlamp's macOS 26 floating pane modifier, with only the theme color changed
/// from ThemeColors(themeTokens).panelBackground to the host StudioPalette.panel.
@available(macOS 26.0, *)
struct RedlampFloatingPane: ViewModifier {
    let opacity: Double

    private var shape: ConcentricRectangle {
        ConcentricRectangle(corners: .concentric(minimum: .fixed(18)), isUniform: true)
    }

    func body(content: Content) -> some View {
        content
            .clipShape(shape)
            .background(StudioPalette.panel.opacity(opacity), in: shape)
            .glassEffect(.regular, in: shape)
    }
}

struct RedlampPaletteModifiers: OptionSet {
    let rawValue: Int
    static let shift = Self(rawValue: 1 << 0)
    static let option = Self(rawValue: 1 << 1)
}

enum RedlampPaletteKey {
    case up, down, left(RedlampPaletteModifiers), right(RedlampPaletteModifiers)
    case submit, escape, deleteBackward, reset
}

/// Adapted from Redlamp PaletteQueryField.swift. AppKit captures arrows, Return,
/// Escape and delete BEFORE the field editor uses them for native text navigation.
/// The host supplies its own command-catalog and state machine.
struct RedlampPaletteQueryField: NSViewRepresentable {
    let text: String
    let placeholder: String
    var font: NSFont = .systemFont(ofSize: 16)
    var alignment: NSTextAlignment = .natural
    let textColor: NSColor
    let placeholderColor: NSColor
    let colorScheme: ColorScheme
    let revision: Int
    let selectsAll: Bool
    var focuses = true
    let onChange: (String) -> Void
    let onKey: (RedlampPaletteKey) -> Bool

    func makeNSView(context: Context) -> RedlampPaletteTextField {
        let field = RedlampPaletteTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byClipping
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.takesFocus = focuses
        field.isEditable = focuses
        field.isSelectable = focuses
        field.selectsAllOnFocus = selectsAll
        context.coordinator.revision = revision
        configure(field)
        return field
    }

    func updateNSView(_ field: RedlampPaletteTextField, context: Context) {
        context.coordinator.parent = self
        configure(field)
        if context.coordinator.revision != revision {
            context.coordinator.revision = revision
            field.select(all: selectsAll)
        }
    }

    private func configure(_ field: RedlampPaletteTextField) {
        field.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        field.font = font
        field.alignment = alignment
        field.textColor = textColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: font, .foregroundColor: placeholderColor, .paragraphStyle: paragraph,
        ])
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RedlampPaletteQueryField
        var revision = 0
        init(parent: RedlampPaletteQueryField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.onChange(field.stringValue)
        }

        func control(_: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            var modifiers: RedlampPaletteModifiers = []
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.option) { modifiers.insert(.option) }
            switch selector {
            case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveUpAndModifySelection(_:)):
                return parent.onKey(.up)
            case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveDownAndModifySelection(_:)):
                return parent.onKey(.down)
            case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveLeftAndModifySelection(_:)),
                 #selector(NSResponder.moveWordLeft(_:)), #selector(NSResponder.moveWordLeftAndModifySelection(_:)):
                return parent.onKey(.left(modifiers))
            case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveRightAndModifySelection(_:)),
                 #selector(NSResponder.moveWordRight(_:)), #selector(NSResponder.moveWordRightAndModifySelection(_:)):
                return parent.onKey(.right(modifiers))
            case #selector(NSResponder.insertNewline(_:)):
                return parent.onKey(.submit)
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onKey(.escape)
            case #selector(NSResponder.deleteBackward(_:)):
                return textView.string.isEmpty && parent.onKey(.deleteBackward)
            case #selector(NSResponder.deleteToBeginningOfLine(_:)):
                return parent.onKey(.reset)
            case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
                return true
            default:
                return false
            }
        }
    }
}

/// Redlamp's focus-on-appear and text selection behavior.
final class RedlampPaletteTextField: NSTextField {
    var takesFocus = true
    var selectsAllOnFocus = true

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard takesFocus, window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window, window.firstResponder !== currentEditor() else { return }
            window.makeFirstResponder(self)
            select(all: selectsAllOnFocus)
        }
    }

    func select(all: Bool) {
        guard let editor = currentEditor() else { return }
        if all {
            editor.selectAll(nil)
        } else {
            editor.selectedRange = NSRange(location: (stringValue as NSString).length, length: 0)
        }
    }
}
