import SwiftUI

struct FilmEffectsPanel: View {
    @ObservedObject var model: AppModel
    private var settings: FilmEffectsSettings { model.selectedLook.filmEffects ?? FilmEffectsSettings() }

    /// The photo's own aspect, so only borders whose window matches are offered.
    private var photoAspect: CGFloat? {
        if let preview = model.renderedPreview {
            return CGFloat(preview.width) / CGFloat(max(1, preview.height))
        }
        return nil
    }
    /// Catalog indices of the frames that fit the current photo's aspect.
    private var availableFrameIndices: [Int] {
        guard let aspect = photoAspect else { return Array(TextureEffectCatalog.frames.indices) }
        let matching = Set(TextureEffectCatalog.frames(forAspect: aspect).map(\.id))
        return TextureEffectCatalog.frames.indices.filter { matching.contains(TextureEffectCatalog.frames[$0].id) }
    }

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
            variationPicker
            Divider()
            Text("Surface").font(.caption.weight(.semibold))
            paperPicker
            if settings.paperTextureIndex >= 0 {
                slider("Paper Strength", \.paperTextureAmount)
            }
            slider("Dust", \.dustAmount)
            slider("Scratches", \.scratchAmount)
            Divider()
            Picker(
                "Frame",
                selection: Binding(
                    get: { settings.frameStyle },
                    set: { value in model.setFilmEffectsSettings { $0.frameStyle = value } })
            ) {
                Text("None").tag(0)
                Text("Keyline").tag(1)
                Text("White Print").tag(2)
                Text("35 mm Rebate").tag(3)
                Text("Slide Mount").tag(4)
            }
            slider("Frame Size", \.frameSize)
            framePicker
            Text("Redlamp film effects · saved with the edit")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(12)
    }

    /// Repeatable leak arrangements, now picked from a list instead of a slider so the
    /// selection is a stable, named choice saved with the edit.
    private var variationPicker: some View {
        Picker(
            "Variation",
            selection: Binding(
                get: { Int(settings.leakVariation.rounded()) },
                set: { value in model.setFilmEffectsSettings { $0.leakVariation = Double(value) } })
        ) {
            ForEach(0..<6) { index in
                Text("Arrangement \(index + 1)").tag(index)
            }
        }
        .help("Choose a different repeatable arrangement of light leaks.")
    }

    private var framePicker: some View {
        Picker(
            "Border",
            selection: Binding(
                get: { settings.frameTextureIndex },
                set: { value in model.setFilmEffectsSettings { $0.frameTextureIndex = value } })
        ) {
            Text("None").tag(-1)
            // Tags carry the catalog index so a saved choice stays valid when the
            // aspect filter narrows the visible list.
            ForEach(availableFrameIndices, id: \.self) { index in
                Text(TextureEffectCatalog.frames[index].displayName).tag(index)
            }
        }
        .help(
            "A film border drawn over the photo, replacing the procedural frame style. "
                + "Only borders whose window fits this photo's shape are listed.")
    }

    private var paperPicker: some View {
        Picker(
            "Paper",
            selection: Binding(
                get: { settings.paperTextureIndex },
                set: { value in
                    model.setFilmEffectsSettings {
                        $0.paperTextureIndex = value
                        if value < 0 { $0.paperTextureAmount = 50 }
                    }
                })
        ) {
            Text("None").tag(-1)
            ForEach(Array(TextureEffectCatalog.papers.enumerated()), id: \.offset) { index, asset in
                Text(asset.displayName).tag(index)
            }
        }
    }
    private func slider(
        _ title: String, _ key: WritableKeyPath<FilmEffectsSettings, Double>, range: ClosedRange<Double> = 0...100
    ) -> some View {
        DraftScalarSlider(
            label: title, committedValue: settings[keyPath: key], range: range, precision: 0,
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
        case "Paper Strength": "How strongly the selected paper surface reads through the photo."
        default: "Adjust the selected frame’s border width."
        }
    }
}
