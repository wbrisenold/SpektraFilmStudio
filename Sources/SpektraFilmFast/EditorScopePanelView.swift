import SwiftUI

struct EditorScopePanelView: View {
    @ObservedObject var model: AppModel

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

            ZStack {
                Color(red: 0.035, green: 0.043, blue: 0.055)

                if let image = model.editorScopeImage {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .allowsHitTesting(false)
                } else {
                    Text(model.selectedImage == nil ? "Select an image to view scopes" : "Reading display scope")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 188)
            .clipped()
            .overlay(alignment: .top) {
                Rectangle().fill(StudioPalette.subtleBorder).frame(height: 1)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(StudioPalette.subtleBorder).frame(height: 1)
            }

            if model.project.preferences.scopeMode == .skinVectorscope {
                skinReadout
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(StudioPalette.panel)
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
        let tolerance = model.project.preferences.skinToleranceDegrees
        if metrics.skinMeanDeviationDegrees < -tolerance { return "Too Magenta" }
        if metrics.skinMeanDeviationDegrees > tolerance { return "Too Green" }
        return "On Target"
    }

    private var skinStatusColor: Color {
        switch skinStatusLabel {
        case "Too Magenta": return Color(red: 0.86, green: 0.36, blue: 0.54)
        case "Too Green": return Color(red: 0.28, green: 0.72, blue: 0.50)
        case "On Target": return Color(red: 0.90, green: 0.69, blue: 0.35)
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
        case .chromaticity: "triangle"
        }
    }
}
