import SwiftUI

struct FilmEffectsPanel: View {
    @ObservedObject var model: AppModel
    private var settings: FilmEffectsSettings { model.selectedLook.filmEffects ?? FilmEffectsSettings() }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Film Finish").font(.headline)
                Spacer()
                Button("Reset") { model.setFilmEffectsSettings { $0 = FilmEffectsSettings() } }
                    .buttonStyle(.borderless)
            }
            Text("Light Leaks").font(.caption.weight(.semibold))
            slider("Amount", \.leakAmount)
            slider("Warmth", \.leakWarmth, range: -100...100)
            slider("Variation", \.leakVariation)
            Divider()
            Text("Surface").font(.caption.weight(.semibold))
            slider("Dust", \.dustAmount)
            slider("Scratches", \.scratchAmount)
            Divider()
            Picker("Frame", selection: Binding(get: { settings.frameStyle }, set: { value in model.setFilmEffectsSettings { $0.frameStyle = value } })) {
                Text("None").tag(0)
                Text("Keyline").tag(1)
                Text("White Print").tag(2)
                Text("35 mm Rebate").tag(3)
                Text("Slide Mount").tag(4)
            }
            slider("Frame Size", \.frameSize)
            Text("Redlamp film effects · saved with the edit")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(12)
    }
    private func slider(_ title: String, _ key: WritableKeyPath<FilmEffectsSettings, Double>, range: ClosedRange<Double> = 0...100) -> some View {
        DraftScalarSlider(label: title, committedValue: settings[keyPath: key], range: range, precision: 0,
                          helpText: help(for: title), resetValue: FilmEffectsSettings()[keyPath: key],
                          onReset: { model.setFilmEffectsSettings { $0[keyPath: key] = FilmEffectsSettings()[keyPath: key] } },
                          onBegin: { model.beginEditGesture() },
                          onChange: { value in model.setFilmEffectsSettings(interactive: true) { $0[keyPath: key] = value } },
                          onEnd: { model.endEditGesture() })
    }
    private func help(for title: String) -> String {
        switch title {
        case "Amount": "Strength of the colored light entering from the frame edges."
        case "Warmth": "Move from cool blue leaks to warm orange and red leaks."
        case "Variation": "Choose a different repeatable arrangement of light leaks."
        case "Dust": "Add small dark and bright specks like dust on scanned film."
        case "Scratches": "Add fine vertical film-travel scratches."
        default: "Adjust the selected frame’s border width."
        }
    }
}
