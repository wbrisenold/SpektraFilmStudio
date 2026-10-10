import SwiftUI
import AppKit

/// Floating contextual scope monitor. Data still comes from the canonical ScopeEngine:
/// resizing the window never resamples or changes scope measurements.
/// Position is stored as relative coordinates so it survives window resizing.
struct StudioFloatingScopes: View {
    @ObservedObject var model: AppModel
    let onClose: () -> Void

    @AppStorage("SpektraFilmStudio.ui.scopesRailWidth") private var panelWidth = 376.0
    @AppStorage("SpektraFilmStudio.ui.floatingScopesHeight") private var panelHeight = 316.0
    @AppStorage("SpektraFilmStudio.ui.floatingScopesX") private var xFraction = 0.94
    @AppStorage("SpektraFilmStudio.ui.floatingScopesY") private var yFraction = 0.08

    @State private var dragStart: CGPoint?
    @State private var resizeStart: CGSize?

    var body: some View {
        GeometryReader { geometry in
            let canvas = geometry.size
            let width = min(CGFloat(panelWidth), max(150, canvas.width - 20))
            let height = min(CGFloat(panelHeight), max(150, canvas.height - 20))
            let cx = canvas.width <= width + 16 ? canvas.width / 2 :
                max(width / 2 + 8, min(canvas.width - width / 2 - 8, canvas.width * CGFloat(xFraction)))
            let cy = canvas.height <= height + 16 ? canvas.height / 2 :
                max(height / 2 + 8, min(canvas.height - height / 2 - 8, canvas.height * CGFloat(yFraction)))

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 12))
                    Text("SCOPES")
                        .font(StudioType.section)
                        .tracking(StudioType.sectionTracking)
                    Menu {
                        ForEach(ScopeMode.allCases) { mode in
                            Button {
                                model.setEditorScopeMode(mode)
                            } label: {
                                if model.project.preferences.scopeMode == mode {
                                    Label(mode.rawValue, systemImage: "checkmark")
                                } else { Text(mode.rawValue) }
                            }
                        }
                    } label: {
                        Text(model.project.preferences.scopeMode.rawValue)
                            .font(.caption).lineLimit(1)
                    }
                    .menuStyle(.borderlessButton)
                    Spacer(minLength: 2)
                    Button { resetPosition() } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.plain).help("Reset scope position")
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain).help("Hide scopes")
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { drag in
                            if dragStart == nil { dragStart = CGPoint(x: CGFloat(xFraction), y: CGFloat(yFraction)) }
                            let initial = dragStart ?? CGPoint(x: CGFloat(xFraction), y: CGFloat(yFraction))
                            xFraction = Double(max(0, min(1, initial.x + drag.translation.width / max(1, canvas.width))))
                            yFraction = Double(max(0, min(1, initial.y + drag.translation.height / max(1, canvas.height))))
                        }
                        .onEnded { _ in dragStart = nil }
                )
                .help("Drag to move the scopes without moving the photo")
                Rectangle().fill(StudioPalette.divider).frame(height: 1)
                ScrollView(.vertical) {
                    EditorScopePanelView(model: model, wellHeight: max(150, height - 128))
                        .padding(.horizontal, 7)
                }
                .scrollIndicators(.automatic)
                HStack(spacing: 12) {
                    Toggle("Clipping", isOn: Binding(
                        get: { model.project.preferences.clippingEnabled },
                        set: { model.setClippingEnabled($0) }
                    ))
                    Toggle("Skin", isOn: Binding(
                        get: { model.project.preferences.skinCheckEnabled },
                        set: { model.setSkinCheckEnabled($0) }
                    ))
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 24)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .onChanged { value in
                                    if resizeStart == nil { resizeStart = CGSize(width: panelWidth, height: panelHeight) }
                                    let start = resizeStart ?? CGSize(width: panelWidth, height: panelHeight)
                                    panelWidth = min(650, max(260, Double(start.width + value.translation.width)))
                                    panelHeight = min(680, max(245, Double(start.height + value.translation.height)))
                                }
                                .onEnded { _ in resizeStart = nil }
                        )
                        .help("Drag to resize the scopes")
                }
                .toggleStyle(.checkbox)
                .font(.caption2)
                .padding(.horizontal, 12).frame(height: 28)
            }
            .frame(width: width, height: height)
            .studioOmniPane()
            .position(x: cx, y: cy)
        }
        .accessibilityLabel("Movable floating scopes")
    }

    private func resetPosition() {
        xFraction = 0.94
        yFraction = 0.08
    }
}
