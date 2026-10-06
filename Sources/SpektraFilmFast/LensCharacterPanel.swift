import SwiftUI

struct LensCharacterPanel: View {
    @ObservedObject var model: AppModel
    private var value: LensEffectsSettings { model.selectedLook.lensEffects ?? LensEffectsSettings() }
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 9) {
                Toggle("Enable Lens Character", isOn: Binding(get:{ value.enabled }, set:{ v in model.setLensEffectsSettings { $0.enabled=v } }))
                Picker("Lens", selection: Binding(get:{ value.preset }, set:{ p in model.setLensEffectsSettings { $0.preset=p } })) {
                    ForEach(LensCharacterPreset.allCases) { Text($0.rawValue).tag($0) }
                }
                scalar("Distortion", value.resolved.distortion, -0.22...0.22) { v in model.setLensEffectsSettings { $0.distortion=v; $0.preset = .custom } }
                scalar("Chromatic Aberration", value.resolved.chromaticAberration, 0...8) { v in model.setLensEffectsSettings { $0.chromaticAberration=v; $0.preset = .custom } }
                scalar("CA on Highlights", value.resolved.highlightChromaticAberration, 0...10) { v in model.setLensEffectsSettings { $0.highlightChromaticAberration=v; $0.preset = .custom } }
                scalar("Spherical Aberration", value.resolved.sphericalAberration, 0...1) { v in model.setLensEffectsSettings { $0.sphericalAberration=v; $0.preset = .custom } }
                scalar("Petzval Swirl", value.resolved.petzvalSwirl, 0...1) { v in model.setLensEffectsSettings { $0.petzvalSwirl=v; $0.preset = .custom } }
                scalar("Edge Softness", value.resolved.edgeSoftness, 0...1) { v in model.setLensEffectsSettings { $0.edgeSoftness=v; $0.preset = .custom } }
                scalar("Vignette", value.resolved.vignette, 0...1) { v in model.setLensEffectsSettings { $0.vignette=v; $0.preset = .custom } }
                Text("35mm Spherical, 50mm Standard, 85mm Portrait, 28mm Wide, Anamorphic 2×, Petzval and Vintage 58mm presets are parameterized from open-source lens-effect references. Effects run after film color and before Crop/Geometry.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(.top,8)
        } label: {
            HStack { Text("Lens Character").font(.caption.weight(.semibold)); Spacer(); if value.enabled { Text(value.preset.rawValue).font(.caption2).foregroundStyle(.secondary) } }
        }
        .padding(10)
        .background(StudioPalette.recessed, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(StudioPalette.subtleBorder, lineWidth: 0.5) }
    }
    @ViewBuilder private func scalar(_ name:String,_ current:Double,_ range:ClosedRange<Double>,_ set:@escaping(Double)->Void)->some View {
        let setter = ScalarSetter(apply: set)
        VStack(alignment:.leading,spacing:3){HStack{Text(name).font(.caption2);Spacer();Text(current,format:.number.precision(.fractionLength(2))).font(.caption2.monospacedDigit())};Slider(value:Binding(get:{current},set:{ setter.apply($0) }),in:range)}
    }
}

private struct ScalarSetter: @unchecked Sendable {
    let apply: (Double) -> Void
}
