import SwiftUI

struct LensCharacterPanel: View {
    @ObservedObject var model: AppModel
    @Binding var isExpanded: Bool
    private var settings:LensEffectsSettings { model.selectedLook.lensEffects ?? LensEffectsSettings() }

    var body: some View {
        DisclosureGroup(isExpanded:$isExpanded) {
            VStack(alignment:.leading,spacing:10) {
                Toggle("Enable Optical Character",isOn:Binding(get:{settings.enabled},set:{v in model.setLensEffectsSettings{$0.enabled=v}}))
                Picker("Optical profile",selection:Binding(get:{settings.preset},set:{v in model.setLensEffectsSettings{$0.preset=v}})) {
                    ForEach(LensCharacterPreset.allCases){Text($0.rawValue).tag($0)}
                }
                HStack {
                    Button {
                        model.isLensCenterEditing.toggle()
                    } label: {
                        Label(model.isLensCenterEditing ? "Done Editing Center":"Edit Center on Photo",
                              systemImage:model.isLensCenterEditing ? "checkmark.circle":"scope")
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    Button("Reset Center") {
                        model.setLensEffectsSettings{$0.centerX=0.5;$0.centerY=0.5}
                    }.controlSize(.small)
                }
                Text("Cyan = protected blur/swirl start · orange = vignette start. Drag the center pin on the photo.")
                    .font(.caption2).foregroundStyle(.secondary)
                Divider()
                Text("Optical Blur / Swirl").font(.caption.weight(.semibold))
                scalar("Rotational Blur",settings.resolved.edgeSoftness,0...1){v in update{$0.edgeSoftness=v}}
                scalar("Spherical Blur",settings.resolved.sphericalAberration,0...1){v in update{$0.sphericalAberration=v}}
                scalar("Swirl",settings.resolved.petzvalSwirl,0...1){v in update{$0.petzvalSwirl=v}}
                scalar("Protected Center",settings.resolved.swirlRadius,0.02...0.94){v in update{$0.swirlRadius=v}}
                scalar("Blur Thickness",settings.resolved.blurThickness,0.1...3){v in update{$0.blurThickness=v}}
                scalar("Lens Shape",settings.resolved.lensShape,0.5...2){v in update{$0.lensShape=v}}
                Divider()
                Text("Glass / Color Separation").font(.caption.weight(.semibold))
                scalar("Distortion",settings.resolved.distortion,-0.22...0.22){v in update{$0.distortion=v}}
                scalar("Chromatic Aberration",settings.resolved.chromaticAberration,0...8){v in update{$0.chromaticAberration=v}}
                scalar("Highlight Fringing",settings.resolved.highlightChromaticAberration,0...10){v in update{$0.highlightChromaticAberration=v}}
                Picker("CA Channel",selection:Binding(get:{settings.resolved.caChannel},set:{v in model.setLensEffectsSettings{$0.bakePresetForEditing();$0.caChannel=v}})){
                    ForEach(LensCAChannel.allCases){Text($0.rawValue).tag($0)}
                }
                Divider()
                Text("Light Falloff").font(.caption.weight(.semibold))
                scalar("Vignette",settings.resolved.vignette,0...1){v in update{$0.vignette=v}}
                scalar("Vignette Radius",settings.resolved.vignetteRadius,0.1...0.98){v in update{$0.vignetteRadius=v}}
                scalar("Vignette Falloff",settings.resolved.vignetteFalloff,0.4...5){v in update{$0.vignetteFalloff=v}}
            }.padding(.top,8)
        } label:{
            HStack{
                Text("Lens Character").font(.caption.weight(.semibold))
                Spacer()
                if settings.enabled{Text(settings.preset.rawValue).font(.caption2).foregroundStyle(.secondary)}
            }
        }
        .padding(10).background(StudioPalette.recessed,in:RoundedRectangle(cornerRadius:8))
        .overlay{RoundedRectangle(cornerRadius:8).stroke(StudioPalette.subtleBorder,lineWidth:0.5)}
    }

    private func update(_ body:@escaping(inout LensEffectsSettings)->Void) {
        model.setLensEffectsSettings { s in s.bakePresetForEditing(); body(&s) }
    }
    @ViewBuilder private func scalar(_ label:String,_ value:Double,_ range:ClosedRange<Double>,set:@escaping(Double)->Void)->some View {
        VStack(alignment:.leading,spacing:3){
            HStack{Text(label).font(.caption2);Spacer();Text(value,format:.number.precision(.fractionLength(2))).font(.caption2.monospacedDigit())}
            Slider(value:Binding(get:{value},set:set),in:range)
        }
    }
}
