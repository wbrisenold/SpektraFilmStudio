import SwiftUI

struct LensCharacterPanel: View {
    @ObservedObject var model: AppModel
    @Binding var isExpanded: Bool
    private var settings: LensEffectsSettings { model.selectedLook.lensEffects ?? LensEffectsSettings() }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Enable Optical Character", isOn: Binding(
                    get: { settings.enabled }, set: { enabled in model.setLensEffectsSettings { $0.enabled = enabled } }
                ))
                Picker("Optical profile", selection: Binding(
                    get: { settings.preset }, set: { preset in model.setLensEffectsSettings { $0.preset = preset } }
                )) { ForEach(LensCharacterPreset.allCases) { preset in Text(preset.rawValue).tag(preset) } }
                Text("These are artistic profiles, not measured lens calibrations. A protected sharp center transitions to curved peripheral blur, color fringing, and optical falloff.")
                    .font(.caption2).foregroundStyle(.secondary)

                Divider()
                Text("Optical Blur / Swirl").font(.caption.weight(.semibold))
                scalar("Rotational Blur", settings.resolved.edgeSoftness, 0...1) { value in update { s, v in s.edgeSoftness = v }(value) }
                scalar("Spherical Blur", settings.resolved.sphericalAberration, 0...1) { value in update { s, v in s.sphericalAberration = v }(value) }
                scalar("Swirl", settings.resolved.petzvalSwirl, 0...1) { value in update { s, v in s.petzvalSwirl = v }(value) }
                scalar("Protected Center", settings.resolved.swirlRadius, 0.02...0.94) { value in update { s, v in s.swirlRadius = v }(value) }
                scalar("Blur Thickness", settings.resolved.blurThickness, 0.1...3) { value in update { s, v in s.blurThickness = v }(value) }
                scalar("Lens Shape", settings.resolved.lensShape, 0.5...2) { value in update { s, v in s.lensShape = v }(value) }
                Divider()
                Text("Glass / Color Separation").font(.caption.weight(.semibold))
                scalar("Distortion", settings.resolved.distortion, -0.22...0.22) { value in update { s, v in s.distortion = v }(value) }
                scalar("Chromatic Aberration", settings.resolved.chromaticAberration, 0...8) { value in update { s, v in s.chromaticAberration = v }(value) }
                scalar("Highlight Fringing", settings.resolved.highlightChromaticAberration, 0...10) { value in update { s, v in s.highlightChromaticAberration = v }(value) }
                Picker("CA Channel", selection: Binding(
                    get: { settings.resolved.caChannel },
                    set: { value in model.setLensEffectsSettings { $0.bakePresetForEditing(); $0.caChannel = value } }
                )) { ForEach(LensCAChannel.allCases) { value in Text(value.rawValue).tag(value) } }
                Divider()
                Text("Light Falloff").font(.caption.weight(.semibold))
                scalar("Vignette", settings.resolved.vignette, 0...1) { value in update { s, v in s.vignette = v }(value) }
                scalar("Vignette Radius", settings.resolved.vignetteRadius, 0.1...0.98) { value in update { s, v in s.vignetteRadius = v }(value) }
                scalar("Vignette Falloff", settings.resolved.vignetteFalloff, 0.4...5) { value in update { s, v in s.vignetteFalloff = v }(value) }
                Text("Optical stage runs after the film renderer and before Crop/Geometry, identically for settled Edit previews and exported images.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(.top, 8)
        } label: {
            HStack {
                Text("Lens Character").font(.caption.weight(.semibold))
                Spacer()
                if settings.enabled { Text(settings.preset.rawValue).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .padding(10)
        .background(StudioPalette.recessed, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(StudioPalette.subtleBorder, lineWidth: 0.5) }
    }

    private func update(_ mutate: @escaping (inout LensEffectsSettings, Double) -> Void) -> (Double) -> Void {
        { value in model.setLensEffectsSettings { settings in settings.bakePresetForEditing(); mutate(&settings, value) } }
    }

    @ViewBuilder private func scalar(_ label: String, _ value: Double, _ range: ClosedRange<Double>, set: @escaping (Double) -> Void) -> some View {
        let action = LensScalarAction(set)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.caption2)
                Spacer()
                Text(value, format: .number.precision(.fractionLength(2))).font(.caption2.monospacedDigit())
            }
            Slider(value: Binding(get: { value }, set: { action.set($0) }), in: range)
        }
    }
}

private struct LensScalarAction: @unchecked Sendable {
    let set: (Double) -> Void
    init(_ set: @escaping (Double) -> Void) { self.set = set }
}
