import SwiftUI

struct EditorScopePanelView: View {
    @ObservedObject var model: AppModel
    @State private var histogramZone: Int?
    @State private var histogramStart: Double = 0
    @State private var histogramPhoto: UUID?

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("SCOPES")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(model.project.preferences.scopeMode.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                if model.isScopeAnalyzing {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.horizontal, 2)

            scopeModeNav

            if model.diagnosticsAreSettling {
                Label("Diagnostics waiting for exact render", systemImage: "clock.arrow.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if !model.diagnosticStatus.isEmpty {
                Label(model.diagnosticStatus, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            ZStack {
                Color(red: 0.035, green: 0.043, blue: 0.055)

                if let image = model.editorScopeImage {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(model.project.preferences.scopeMode == .histogram ? .high : .none)
                        .scaledToFit()
                        .allowsHitTesting(false)
                } else {
                    Text(model.selectedImage == nil ? "Select an image to view scopes" : "Reading display scope")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 188)
            .overlay {
                if model.project.preferences.scopeMode == .histogram {
                    GeometryReader { geometry in
                        Color.clear.contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 2).onChanged { drag in
                                guard model.selectedImage != nil else { return }
                                if histogramZone == nil {
                                    let zone = min(4, max(0, Int(drag.startLocation.x / max(1, geometry.size.width) * 5)))
                                    histogramZone = zone
                                    histogramPhoto = model.project.selectedImageID
                                    let tone = model.selectedLook.tone ?? ToneSettings()
                                    histogramStart = [tone.blacks, tone.shadows, tone.exposureEV, tone.highlights, tone.whites][zone]
                                    model.beginEditGesture()
                                }
                                guard histogramPhoto == model.project.selectedImageID, let zone = histogramZone else { return }
                                let delta = Double(drag.translation.width / max(1, geometry.size.width))
                                let value = histogramStart + delta * (zone == 2 ? 10 : 200)
                                switch zone {
                                case 0: model.setToneBlacks(value, interactive: true)
                                case 1: model.setToneShadows(value, interactive: true)
                                case 2: model.setExposureEV(value, interactive: true)
                                case 3: model.setToneHighlights(value, interactive: true)
                                default: model.setToneWhites(value, interactive: true)
                                }
                            }.onEnded { _ in finishHistogramDrag() })
                    }
                }
            }
            .clipped()
            .overlay(alignment: .top) {
                Rectangle().fill(StudioPalette.subtleBorder).frame(height: 1)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(StudioPalette.subtleBorder).frame(height: 1)
            }

            if model.project.preferences.scopeMode == .histogram {
                HStack {
                    Button { model.setClippingEnabled(!model.project.preferences.clippingEnabled) } label: {
                        Label(String(format: "%.2f%%", model.analysisMetrics.hardShadowPercent), systemImage: "triangle.fill")
                            .foregroundStyle(model.analysisMetrics.hardShadowPercent > 0 ? Color.blue : Color.secondary)
                    }.buttonStyle(.plain).help("Shadow clipping · toggle clipping overlay")
                    Spacer()
                    Text(histogramZone.map { ["Blacks", "Shadows", "Exposure", "Highlights", "Whites"][$0] } ?? "Drag histogram to adjust light")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.setClippingEnabled(!model.project.preferences.clippingEnabled) } label: {
                        Label(String(format: "%.2f%%", model.analysisMetrics.hardHighlightPercent), systemImage: "triangle.fill")
                            .foregroundStyle(model.analysisMetrics.hardHighlightPercent > 0 ? Color.red : Color.secondary)
                    }.buttonStyle(.plain).help("Highlight clipping · toggle clipping overlay")
                }.font(.caption2)
            }

            if model.project.preferences.scopeMode == .skinVectorscope {
                skinReadout
            } else if model.project.preferences.scopeMode == .falseColor {
                Text("Display-code Y′ · blue: low · green: shadows · gray: mid · yellow/orange: bright · red/white: near clip")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if ![14,15,16,17,18,24,25].contains(Int(model.selectedLook.values["outputColorSpace"]?.intValue ?? 25)) {
                    Label("Nonstandard output transfer: false color is not calibrated for this output space", systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange)
                }
            } else if model.project.preferences.scopeMode == .saturation {
                Text("HSV saturation · gray: low · teal: moderate · amber: strong · orange: high · pink: very high. Not a creative judgment.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(StudioPalette.panel)
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

    private func finishHistogramDrag() {
        if histogramZone != nil { model.endEditGesture() }
        histogramZone = nil; histogramPhoto = nil
    }

    private var scopeModeNav: some View {
        HStack(spacing: 2) {
            ForEach(ScopeMode.allCases) { mode in
                let selected = model.project.preferences.scopeMode == mode
                Button {
                    model.setEditorScopeMode(mode)
                } label: {
                    Image(systemName: icon(mode))
                        .font(.system(size: 11, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 27)
                        .background(selected ? StudioPalette.selected : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(mode.rawValue)
            }
        }
        .padding(3)
        .background(StudioPalette.recessed, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(StudioPalette.subtleBorder, lineWidth: 0.5)
        }
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
