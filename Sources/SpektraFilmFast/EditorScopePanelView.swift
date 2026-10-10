import SwiftUI

/// Docked scopes strip shown beneath the canvas.
///
/// Two lessons are baked in here:
/// 1. It is *not* part of the adjustment rail — stacking scopes above the sliders
///    left the Edit inspector too short to work in.
/// 2. It is collapsed to a single slim row by default. A permanently expanded
///    scope panel is ~290pt tall, which meant it swallowed the entire bottom row
///    of the workspace instead of helping with it.
///
/// The strip reports its real measured height so the canvas reserves exactly the
/// right amount and the preview is never drawn underneath it.
struct EditorScopeStrip: View {
    /// Slim collapsed bar: header row only, plus a little breathing room.
    static let collapsedHeight: CGFloat = 34
    /// Fallback used for the expanded estimate before the first measurement lands.
    static let estimatedExpandedHeight: CGFloat = 292

    @ObservedObject var model: AppModel
    @Binding var isExpanded: Bool
    /// Reports the strip's real height so the canvas reserves exactly that much.
    let onHeightChange: @MainActor (CGFloat) -> Void

    /// Feed a *changed* measured height back on the next main-actor turn.
    ///
    /// The callback mutates `@State` that reserves this view's own height.
    /// Reporting synchronously inside the layout pass would create a
    /// layout -> state -> layout cycle, so it is deferred by one turn. The
    /// `previous == nil` guard drops the initial `onChange` callback, since the
    /// caller already seeds a sane collapsed-height fallback.
    private static func report(previous: CGFloat?, _ height: CGFloat, to handler: @escaping @MainActor (CGFloat) -> Void) {
        guard let previous, previous != height, height.isFinite, height > 0 else { return }
        Task { @MainActor in
            handler(height)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                EditorScopePanelView(model: model)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size.height) { previous, height in
                    Self.report(previous: previous, height, to: onHeightChange)
                }
            }
        )
        .studioGlassPane()
    }

    /// Collapsed row doubles as the expand affordance: a live numeric readout of
    /// the current scope, so it is worth the 34pt it occupies.
    private var header: some View {
        HStack(spacing: 8) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                    // Glyph + name only. The scope-mode name and the numeric
                    // readout follow as separate spans, so folding them in here
                    // produced "Scopes Histogram" plus a stray "Histogram".
                    Image(systemName: "waveform.path").foregroundStyle(.secondary)
                    Text("Scopes").font(StudioType.section)
                }
            }
            .buttonStyle(.plain)

            if !isExpanded {
                Text(collapsedReadout)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Expand") { isExpanded = true }
                    .buttonStyle(.borderless).controlSize(.small)
            } else {
                overlayToggles
                Spacer()
                if model.isScopeAnalyzing { ProgressView().controlSize(.mini) }
                Button("Collapse") { isExpanded = false }
                    .buttonStyle(.borderless).controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.collapsedHeight)
        .contentShape(Rectangle())
        .onTapGesture { isExpanded.toggle() }
    }

    private var collapsedReadout: String {
        let m = model.analysisMetrics
        return "\(model.project.preferences.scopeMode.rawValue) · high \(String(format: "%.1f", m.highlightPercent))% · low \(String(format: "%.1f", m.shadowPercent))%"
    }

    /// Clipping and skin overlays stay reachable while the strip is collapsed.
    /// They used to live in a "MONITOR" block inside the inspector, which is why
    /// they disappeared once scopes moved to the canvas.
    private var overlayToggles: some View {
        HStack(spacing: 5) {
            Toggle(isOn: Binding(
                get: { model.project.preferences.clippingEnabled },
                set: { model.setClippingEnabled($0) })) {
                Label("Clipping", systemImage: "arrowtriangle.up.fill")
            }
            .toggleStyle(.button).controlSize(.mini)
            .help("Warn when final output approaches white/red or black/blue. Bright warning is not always irreversible clipping.")

            Toggle(isOn: Binding(
                get: { model.project.preferences.skinCheckEnabled },
                set: { model.setSkinCheckEnabled($0) })) {
                Label("Skin", systemImage: "hand.raised.fill")
            }
            .toggleStyle(.button).controlSize(.mini)
            .help("Show a skin diagnostic on the rendered image")
        }
        .font(.caption2)
    }
}

struct EditorScopePanelView: View {
    @ObservedObject var model: AppModel
    // Larger dock size is supplied by EditWorkspaceView; the old compact well
    // remains available for legacy or future hosts.
    var wellHeight: CGFloat = 240
    @State private var histogramZone: Int?
    @State private var histogramStart: Double = 0
    @State private var histogramPhoto: UUID?
    /// Tracked via GeometryReader so drag deltas use real well width.
    @State private var lastWellWidth: CGFloat = 1

    var body: some View {
        // Order and metrics follow Redlamp's HistogramView: a 104pt well, a readout
        // row with a clipping indicator at each end, then the mode strip beneath.
        VStack(spacing: 6) {
            ZStack {
                Color(red: 0.032, green: 0.037, blue: 0.045)

                if let image = model.editorScopeImage {
                    if [.vectorscope, .skinVectorscope, .chromaticity].contains(model.project.preferences.scopeMode) {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .padding(8)
                            .allowsHitTesting(false)
                    } else {
                        // Preserve the source raster's measured aspect ratio. The
                        // old max-width/max-height path squeezed 768x320 waveforms
                        // into portrait-shaped wells and distorted x/level axes.
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(model.project.preferences.scopeMode == .histogram ? .high : .none)
                            .aspectRatio(CGFloat(image.width) / CGFloat(max(1, image.height)), contentMode: .fit)
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                } else {
                    Text(model.selectedImage == nil ? "Select an image to view scopes" : "Reading display scope")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: wellHeight)
            .contextMenu {
                // Scope choice lives here rather than as a permanent pill strip:
                // Redlamp's rail carries one histogram well and no mode bar.
                Picker("Scope", selection: Binding(
                    get: { model.project.preferences.scopeMode },
                    set: { model.setEditorScopeMode($0) })) {
                    ForEach(ScopeMode.allCases) { mode in
                        Label(mode.rawValue, systemImage: icon(mode)).tag(mode)
                    }
                }
            }
            .background(GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size.width) { _, w in
                    if w > 0 { lastWellWidth = w }
                }
            })
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75)
            }
            .overlay(alignment: .topLeading) {
                if model.project.preferences.scopeMode == .waveform ||
                   model.project.preferences.scopeMode == .parade {
                    Text("100%")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.58))
                        .padding(7)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if model.project.preferences.scopeMode == .waveform ||
                   model.project.preferences.scopeMode == .parade {
                    Text("0%")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.58))
                        .padding(7)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            // Never change tone by dragging a waveform, parade, vectorscope or
            // false-color preview. Only the histogram has tonal drag regions.
            .gesture(histogramDrag, including: model.project.preferences.scopeMode == .histogram ? .all : .none)

            HStack(spacing: 8) {
                if model.project.preferences.scopeMode == .histogram {
                    clippingIndicator(isClipped: model.analysisMetrics.hardShadowPercent > 0,
                                      value: model.analysisMetrics.hardShadowPercent,
                                      tint: .blue, isFlipped: false)
                    Spacer()
                    if let zone = histogramZone {
                        Text("\(tuningName(for: zone))  \(tuningValue(for: zone))")
                            .monospacedDigit().foregroundStyle(.primary)
                    } else {
                        Text("Drag histogram to adjust light").foregroundStyle(.secondary)
                    }
                    Spacer()
                    clippingIndicator(isClipped: model.analysisMetrics.hardHighlightPercent > 0,
                                      value: model.analysisMetrics.hardHighlightPercent,
                                      tint: .red, isFlipped: true)
                } else {
                    Text(" ").foregroundStyle(.secondary)
                }
            }
            .font(.caption2)

            if model.diagnosticsAreSettling {
                Label("Diagnostics waiting for exact render", systemImage: "clock.arrow.circlepath")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if !model.diagnosticStatus.isEmpty {
                Label(model.diagnosticStatus, systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }

            // Redlamp's rail has no scope caption and no mode strip: one fixed
            // histogram well, with the clipping/skin state on the readout row below.
            // The previous invented "SCOPES / Histogram" pill row was not Redlamp.
            HStack(spacing: 8) {
                if model.isScopeAnalyzing { ProgressView().controlSize(.mini) }
                Spacer()
                Text(model.project.preferences.scopeMode.rawValue)
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if model.project.preferences.scopeMode == .skinVectorscope {
                skinReadout
            } else if model.project.preferences.scopeMode == .falseColor {
                Text("Display-code \u{2032} \u{00B7} blue: low \u{00B7} green: shadows \u{00B7} gray: mid \u{00B7} yellow/orange: bright \u{00B7} red/white: near clip")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if ![14,15,16,17,18,24,25].contains(Int(model.selectedLook.values["outputColorSpace"]?.intValue ?? 25)) {
                    Label("Nonstandard output transfer: false color is not calibrated for this output space", systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange)
                }
            } else if model.project.preferences.scopeMode == .saturation {
                Text("HSV saturation \u{00B7} gray: low \u{00B7} teal: moderate \u{00B7} amber: strong \u{00B7} orange: high \u{00B7} pink: very high. Not a creative judgment.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .onDisappear { finishHistogramDrag() }
        .onChange(of: model.project.selectedImageID) { _, _ in finishHistogramDrag() }
        .onAppear {
            // Scopes are a persistent editor monitor in v0.4. Existing projects may
            // contain the old off preference, so normalize it when the editor appears.
            if !model.project.preferences.scopeEnabled {
                model.setEditorScopeEnabled(true)
            } else {
                model.requestEditorScopeUpdate()
            }
        }
    }

    /// Redlamp splits the well into five fixed regions (HistogramView.Region) and
    /// drags one tone parameter per region, rather than sampling arbitrary x.
    private static let regions: [(name: String, span: ClosedRange<Double>)] = [
        ("blacks", 0.00...0.08), ("shadows", 0.08...0.32), ("exposure", 0.32...0.68),
        ("highlights", 0.68...0.92), ("whites", 0.92...1.00),
    ]

    private static func regionIndex(at fraction: Double) -> Int {
        regions.firstIndex { $0.span.contains(fraction) } ?? 2
    }

    private var histogramDrag: some Gesture {
        DragGesture(minimumDistance: 2).onChanged { value in
            guard model.selectedImage != nil else { return }
            if histogramZone == nil {
                let fraction = Double(value.startLocation.x) / Double(max(lastWellWidth, 1))
                let zone = Self.regionIndex(at: fraction)
                histogramZone = zone
                histogramPhoto = model.project.selectedImageID
                let tone = model.selectedLook.tone ?? ToneSettings()
                histogramStart = [tone.blacks, tone.shadows, tone.exposureEV, tone.highlights, tone.whites][zone]
                model.beginEditGesture()
            }
            guard histogramPhoto == model.project.selectedImageID, let zone = histogramZone else { return }
            let delta = Double(value.translation.width / max(lastWellWidth, 1))
            let next = histogramStart + delta * (zone == 2 ? 10 : 200)
            switch zone {
            case 0: model.setToneBlacks(next, interactive: true)
            case 1: model.setToneShadows(next, interactive: true)
            case 2: model.setExposureEV(next, interactive: true)
            case 3: model.setToneHighlights(next, interactive: true)
            default: model.setToneWhites(next, interactive: true)
            }
        }.onEnded { _ in finishHistogramDrag() }
    }

    /// Clipping state *and* the overlay toggle, as one control per histogram end.
    private func clippingIndicator(isClipped: Bool, value: Double, tint: Color, isFlipped: Bool) -> some View {
        let overlayOn = model.project.preferences.clippingEnabled
        return Button {
            model.setClippingEnabled(!overlayOn)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrowtriangle.up.fill")
                    .font(.system(size: 8))
                    .rotationEffect(.degrees(isFlipped ? 45 : -45))
                Text(String(format: "%.2f%%", value))
                    .monospacedDigit()
            }
            .foregroundStyle(isClipped || overlayOn ? tint : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(overlayOn ? "Hide clipping overlay" : "Show clipping overlay")
        .accessibilityLabel(isFlipped ? "Highlight clipping" : "Shadow clipping")
        .accessibilityValue(isClipped ? "Clipped" : "Clear")
    }

    /// Redlamp prints the *tuned* value under the histogram while dragging, not the
/// clipped-pixel percentage, so the number moves as you drag.
    private func tuningName(for zone: Int) -> String {
        ["Blacks", "Shadows", "Exposure", "Highlights", "Whites"][min(max(0, zone), 4)]
    }

    private func tuningValue(for zone: Int) -> String {
        let tone = model.selectedLook.tone ?? ToneSettings()
        let raw: Double = switch zone {
        case 0: tone.blacks
        case 1: tone.shadows
        case 2: tone.exposureEV
        case 3: tone.highlights
        default: tone.whites
        }
        return String(format: "%+.0f", raw)
    }

    private func finishHistogramDrag() {
        if histogramZone != nil { model.endEditGesture() }
        histogramZone = nil; histogramPhoto = nil
    }


    private var skinReadout: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(skinStatusColor)
                    .frame(width: 6, height: 6)
                Text(skinStatusLabel.uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(skinStatusColor)
                Spacer()
                Text(String(format: "%+.1f° from target", model.analysisMetrics.skinMeanDeviationDegrees))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .frame(height: 22)

            Divider()

            HStack(spacing: 7) {
                Image(systemName: "arrow.right.circle")
                    .foregroundStyle(skinStatusColor)
                Text(skinCorrectionLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("WB to Skin") { model.autoWhiteBalanceToSkin() }
                    .controlSize(.mini)
                    .disabled(model.isSkinWhiteBalanceRunning || skinStatusLabel == "No reliable skin sample")
            }
            .padding(.horizontal, 7)
            .frame(height: 26)

            Divider()

            HStack(spacing: 0) {
                scopeMetric("ON TARGET", String(format: "%.0f%%", model.analysisMetrics.skinWithinTolerancePercent))
                Divider().frame(height: 22)
                scopeMetric("TOO MAGENTA", String(format: "%.0f%%", model.analysisMetrics.skinMagentaPercent))
                Divider().frame(height: 22)
                scopeMetric("TOO GREEN", String(format: "%.0f%%", model.analysisMetrics.skinGreenPercent))
                Divider().frame(height: 22)
                scopeMetric("CONF", String(format: "%.0f%%", model.analysisMetrics.skinMeasurementConfidencePercent))
            }
            .frame(height: 30)
        }
        .background(StudioPalette.recessed)
        .overlay {
            Rectangle().stroke(StudioPalette.subtleBorder, lineWidth: 0.5)
        }
    }

    private var skinStatusLabel: String {
        let metrics = model.analysisMetrics
        guard metrics.skinCandidatePercent > 0.01, metrics.skinMeasurementConfidencePercent > 2 else {
            return "No reliable skin sample"
        }
        let magenta = metrics.skinMagentaPercent
        let green = metrics.skinGreenPercent
        let onTarget = metrics.skinWithinTolerancePercent

        // One centroid can sit on the skin line when green-side and
        // magenta-side regions cancel. Call that mixed light instead.
        if magenta >= 18, green >= 18, abs(magenta - green) < 16 {
            return "Mixed Green / Magenta"
        }
        if green > max(onTarget, magenta), green >= 28 { return "Too Green" }
        if magenta > max(onTarget, green), magenta >= 28 { return "Too Magenta" }
        return "On Target"
    }

    private var skinCorrectionLabel: String {
        switch skinStatusLabel {
        case "Too Magenta":
            return "CORRECT → push tint toward GREEN"
        case "Too Green":
            return "CORRECT → push tint toward MAGENTA"
        case "On Target":
            return "ON LINE → no global hue/tint push needed"
        case "Mixed Green / Magenta":
            return "MIXED LIGHT → global WB will trade one region for another"
        default:
            return "Skin correction direction unavailable"
        }
    }

    private var skinStatusColor: Color {
        switch skinStatusLabel {
        case "Too Magenta": return Color(red: 0.86, green: 0.36, blue: 0.54)
        case "Too Green": return Color(red: 0.28, green: 0.72, blue: 0.50)
        case "On Target": return Color(red: 0.90, green: 0.69, blue: 0.35)
        case "Mixed Green / Magenta": return .orange
        default: return .secondary
        }
    }

    private func scopeMetric(_ label: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func icon(_ mode: ScopeMode) -> String {
        switch mode {
        case .histogram: "chart.bar.xaxis"
        case .waveform: "waveform.path.ecg"
        case .parade: "rectangle.split.3x1"
        case .vectorscope: "scope"
        case .skinVectorscope: "person.crop.circle"
        case .saturation: "drop.halffull"
        case .falseColor: "square.3.layers.3d.down.right"
        case .chromaticity: "triangle"
        }
    }
}
