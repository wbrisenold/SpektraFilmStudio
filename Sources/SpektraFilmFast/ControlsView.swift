import SwiftUI

struct ControlsView: View {
    @ObservedObject var model: AppModel
    @State private var geometryExpanded = false
    private let catalog = BridgeCatalog.shared

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 7) {
                rawSection
                toneSection
                colorDensitySection
                geometrySection

                ForEach(catalog.groups.filter { $0.id != "raw" }) { group in
                    let descriptors = catalog.parameters(in: group.id, flavor: .pro)
                    if !descriptors.isEmpty {
                        DisclosureGroup {
                            VStack(spacing: 10) {
                                ForEach(descriptors) { descriptor in
                                    ParameterControlRow(
                                        model: model,
                                        descriptor: descriptor,
                                        options: catalog.options(for: descriptor)
                                    )
                                }
                            }
                            .padding(.top, 8)
                        } label: {
                            HStack {
                                Text(group.label)
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Button { model.resetParameterGroup(group.id) } label: {
                                    Image(systemName: "arrow.counterclockwise")
                                }
                                .buttonStyle(.plain)
                                .help("Reset every control in this section to its default value.")
                            }
                        }
                        .padding(10)
                        .background(StudioPalette.recessed, in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(StudioPalette.subtleBorder, lineWidth: 0.5)
                        }
                    }
                }
            }
            .padding(9)
        }
        .tint(Color.primary.opacity(0.78))
    }

    private var rawSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Picker("White Balance", selection: Binding(
                    get: { model.selectedLook.raw.whiteBalanceMode },
                    set: { mode in model.setWhiteBalanceMode(mode) }
                )) {
                    ForEach(RawWhiteBalanceMode.allCases) { Text($0.rawValue).tag($0) }
                }

                WhiteBalanceTemperatureSlider(
                    label: "Temperature",
                    committedKelvin: model.whiteBalanceDisplayTemperature,
                    disabled: model.isResolvingWhiteBalanceReference,
                    helpText: "Makes the image warmer or cooler. Move right for warmer/yellower light and left for cooler/bluer light. In As Shot or Auto, this starts from that mode's current white balance instead of jumping to a fixed value.",
                    onReset: { model.resetWhiteBalanceSliders() },
                    onBegin: { model.beginEditGesture() },
                    onChange: { value in model.setWhiteBalanceTemperature(value, interactive: true) },
                    onEnd: { model.endEditGesture() }
                )

                DraftScalarSlider(
                    label: "Tint",
                    committedValue: model.whiteBalanceDisplayTint,
                    range: -150...150,
                    precision: 1,
                    disabled: model.isResolvingWhiteBalanceReference,
                    helpText: "Fixes a green or magenta color cast. Move right toward magenta and left toward green. It stays relative to As Shot or Auto when those modes are selected.",
                    onReset: { model.resetWhiteBalanceSliders() },
                    onBegin: { model.beginEditGesture() },
                    onChange: { value in model.setWhiteBalanceTint(value, interactive: true) },
                    onEnd: { model.endEditGesture() }
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text("Quick WB")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 6) {
                        Button {
                            model.autoWhiteBalanceToSkin()
                        } label: {
                            if model.isSkinWhiteBalanceRunning {
                                ProgressView().controlSize(.mini)
                            } else {
                                Label("WB to Skin", systemImage: "person.crop.circle.badge.checkmark")
                            }
                        }
                        .controlSize(.small)
                        .disabled(model.isSkinWhiteBalanceRunning || model.selectedImage == nil)
                        .help("Starts from this photo's As Shot white balance, measures reliable skin against the vectorscope skin line, then solves a conservative per-photo temperature/tint correction.")

                        Menu("From As Shot") {
                            Section("Technical") {
                                ForEach(WhiteBalanceQuickPreset.technicalPresets) { preset in
                                    Button(preset.name) {
                                        model.applyWhiteBalancePreset(baseMode: .asShot, preset: preset)
                                    }
                                    .help(preset.help)
                                }
                            }
                            Section("Creative") {
                                ForEach(WhiteBalanceQuickPreset.creativePresets) { preset in
                                    Button(preset.name) {
                                        model.applyWhiteBalancePreset(baseMode: .asShot, preset: preset)
                                    }
                                    .help(preset.help)
                                }
                            }
                        }
                        .controlSize(.small)
                        .help("Starts from this photo's camera white balance, then applies the chosen relative shift.")

                        Menu("From Auto") {
                            Section("Technical") {
                                ForEach(WhiteBalanceQuickPreset.technicalPresets) { preset in
                                    Button(preset.name) {
                                        model.applyWhiteBalancePreset(baseMode: .auto, preset: preset)
                                    }
                                    .help(preset.help)
                                }
                            }
                            Section("Creative") {
                                ForEach(WhiteBalanceQuickPreset.creativePresets) { preset in
                                    Button(preset.name) {
                                        model.applyWhiteBalancePreset(baseMode: .auto, preset: preset)
                                    }
                                    .help(preset.help)
                                }
                            }
                        }
                        .controlSize(.small)
                        .help("Starts from this photo's own Auto White Balance result, then applies the chosen relative shift.")
                    }
                }

                HStack(spacing: 6) {
                    if model.isResolvingWhiteBalanceReference {
                        ProgressView().controlSize(.mini)
                        Text("Reading current neutral…")
                    } else if model.selectedLook.raw.whiteBalanceMode == .custom {
                        Text("Absolute custom white balance")
                    } else {
                        Text("Adjusting from \(model.selectedLook.raw.whiteBalanceMode.rawValue)")
                    }
                    Spacer()
                    if model.selectedLook.raw.whiteBalanceMode == .auto {
                        Button("Recalculate") { model.recalculateAutoWhiteBalance() }
                            .controlSize(.small)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                if model.selectedLook.raw.whiteBalanceMode == .auto,
                   !model.autoWhiteBalanceStatus.isEmpty {
                    Text(model.autoWhiteBalanceStatus)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if !model.skinWhiteBalanceStatus.isEmpty {
                    Text(model.skinWhiteBalanceStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Toggle("Vendor Lens Correction", isOn: Binding(
                    get: { model.selectedLook.raw.lensCorrection },
                    set: { enabled in model.setRawSettings({ $0.lensCorrection = enabled }, interactive: false) }
                ))
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Text("RAW")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button { model.resetRawSection() } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.plain)
                    .help("Reset the RAW section, including white balance and lens correction.")
            }
        }
        .padding(10)
        .background(StudioPalette.recessed, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(StudioPalette.subtleBorder, lineWidth: 0.5)
        }
    }

    private var toneSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                DraftScalarSlider(
                    label: "Exposure (EV)",
                    committedValue: model.selectedLook.tone?.exposureEV ?? 0,
                    range: -10...10,
                    precision: 2,
                    helpText: "Changes the whole image brighter or darker before the film look. +1 is one stop brighter. -1 is one stop darker.",
                    resetValue: 0,
                    onReset: { model.setExposureEV(0, interactive: false) },
                    onBegin: { model.beginEditGesture() },
                    onChange: { value in model.setExposureEV(value, interactive: true) },
                    onEnd: { model.endEditGesture() }
                )

                DraftScalarSlider(
                    label: "Brightness",
                    committedValue: model.selectedLook.tone?.brightness ?? 0,
                    range: -100...100,
                    precision: 0,
                    helpText: "Changes how bright the picture feels, mostly through the middle tones, without acting like another camera Exposure control. Move right for a brighter-looking image; move left for a darker-looking image.",
                    resetValue: 0,
                    onReset: { model.setToneBrightness(0, interactive: false) },
                    onBegin: { model.beginEditGesture() },
                    onChange: { model.setToneBrightness($0, interactive: true) },
                    onEnd: { model.endEditGesture() }
                )

                DraftScalarSlider(
                    label: "Contrast",
                    committedValue: model.selectedLook.tone?.contrast ?? 0,
                    range: -100...100,
                    precision: 0,
                    helpText: "Changes the separation between dark and bright tones around middle gray. Move right for more punch; move left for a flatter, softer image.",
                    resetValue: 0,
                    onReset: { model.setToneContrast(0, interactive: false) },
                    onBegin: { model.beginEditGesture() },
                    onChange: { model.setToneContrast($0, interactive: true) },
                    onEnd: { model.endEditGesture() }
                )

                DraftScalarSlider(
                    label: "Midtones",
                    committedValue: model.selectedLook.tone?.midtones ?? 0,
                    range: -100...100,
                    precision: 0,
                    helpText: "Targets the middle brightness range where faces and most subjects often live. Move right to lift the middle tones; move left to darken them while leaving the deepest blacks and brightest whites less affected.",
                    resetValue: 0,
                    onReset: { model.setToneMidtones(0, interactive: false) },
                    onBegin: { model.beginEditGesture() },
                    onChange: { model.setToneMidtones($0, interactive: true) },
                    onEnd: { model.endEditGesture() }
                )

                DraftScalarSlider(
                    label: "Highlights",
                    committedValue: model.selectedLook.tone?.highlights ?? 0,
                    range: -100...100,
                    precision: 0,
                    helpText: "Targets bright detail without moving the whole image as much. Move left to pull bright areas down; move right to make highlights brighter and more open.",
                    resetValue: 0,
                    onReset: { model.setToneHighlights(0, interactive: false) },
                    onBegin: { model.beginEditGesture() },
                    onChange: { model.setToneHighlights($0, interactive: true) },
                    onEnd: { model.endEditGesture() }
                )

                DraftScalarSlider(
                    label: "Highlight Recovery",
                    committedValue: model.selectedLook.tone?.highlightRecovery ?? 0,
                    range: 0...100,
                    precision: 0,
                    helpText: "Pulls back very bright detail without simply darkening the whole image. Use it when bright skin, clouds, lamps, or reflections are getting too hot. Higher values compress and gently neutralize the brightest areas more strongly.",
                    resetValue: 0,
                    onReset: { model.setHighlightRecovery(0, interactive: false) },
                    onBegin: { model.beginEditGesture() },
                    onChange: { model.setHighlightRecovery($0, interactive: true) },
                    onEnd: { model.endEditGesture() }
                )

                DraftScalarSlider(
                    label: "Shadows",
                    committedValue: model.selectedLook.tone?.shadows ?? 0,
                    range: -100...100,
                    precision: 0,
                    helpText: "Targets darker detail. Move right to open dark areas; move left to make shadows deeper.",
                    resetValue: 0,
                    onReset: { model.setToneShadows(0, interactive: false) },
                    onBegin: { model.beginEditGesture() },
                    onChange: { model.setToneShadows($0, interactive: true) },
                    onEnd: { model.endEditGesture() }
                )

                DraftScalarSlider(
                    label: "Shadow Recovery",
                    committedValue: model.selectedLook.tone?.shadowRecovery ?? 0,
                    range: 0...100,
                    precision: 0,
                    helpText: "Recovers detail from the darkest useful tones while fading out before the midtones. Use it when hair, suits, interiors, or backgrounds are disappearing into black. Higher values open more shadow detail.",
                    resetValue: 0,
                    onReset: { model.setShadowRecovery(0, interactive: false) },
                    onBegin: { model.beginEditGesture() },
                    onChange: { model.setShadowRecovery($0, interactive: true) },
                    onEnd: { model.endEditGesture() }
                )

                DraftScalarSlider(
                    label: "Whites",
                    committedValue: model.selectedLook.tone?.whites ?? 0,
                    range: -100...100,
                    precision: 0,
                    helpText: "Moves the bright end of the image. Use it after Exposure to control how strong the whites feel without changing the shadow floor.",
                    resetValue: 0,
                    onReset: { model.setToneWhites(0, interactive: false) },
                    onBegin: { model.beginEditGesture() },
                    onChange: { model.setToneWhites($0, interactive: true) },
                    onEnd: { model.endEditGesture() }
                )

                DraftScalarSlider(
                    label: "Blacks",
                    committedValue: model.selectedLook.tone?.blacks ?? 0,
                    range: -100...100,
                    precision: 0,
                    helpText: "Moves the darkest end of the image. Move left for deeper blacks; move right to lift the black floor.",
                    resetValue: 0,
                    onReset: { model.setToneBlacks(0, interactive: false) },
                    onBegin: { model.beginEditGesture() },
                    onChange: { model.setToneBlacks($0, interactive: true) },
                    onEnd: { model.endEditGesture() }
                )

                DraftScalarSlider(
                    label: "White Point",
                    committedValue: model.selectedLook.tone?.whitePoint ?? 0,
                    range: -100...100,
                    precision: 0,
                    helpText: "Sets where the bright end reaches white before the film look. Move right to make whites reach their endpoint sooner; move left to leave more headroom in the brightest tones.",
                    resetValue: 0,
                    onReset: { model.setWhitePoint(0, interactive: false) },
                    onBegin: { model.beginEditGesture() },
                    onChange: { model.setWhitePoint($0, interactive: true) },
                    onEnd: { model.endEditGesture() }
                )

                DraftScalarSlider(
                    label: "Black Point",
                    committedValue: model.selectedLook.tone?.blackPoint ?? 0,
                    range: -100...100,
                    precision: 0,
                    helpText: "Sets where the dark end reaches black before the film look. Move right for a firmer, deeper black point; move left to keep more room below the darkest visible tones.",
                    resetValue: 0,
                    onReset: { model.setBlackPoint(0, interactive: false) },
                    onBegin: { model.beginEditGesture() },
                    onChange: { model.setBlackPoint($0, interactive: true) },
                    onEnd: { model.endEditGesture() }
                )

                Divider().opacity(0.5)

                HStack {
                    Text("Tone Curve")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Menu("Presets") {
                        ForEach(ToneCurvePresetGroup.allCases) { group in
                            Section(group.rawValue) {
                                ForEach(ToneCurvePreset.allCases.filter { $0.group == group }) { preset in
                                    Button(preset.rawValue) { model.applyToneCurvePreset(preset) }
                                        .help(preset.summary)
                                }
                            }
                        }
                    }
                    .controlSize(.small)
                    .help("Choose a technical, film-response, or creative tone curve. Film-response curves shape contrast only; the Film section still controls the actual stock simulation.")
                    Button("Reset") { model.resetToneCurve() }
                        .controlSize(.small)
                }

                ToneCurveEditorView(model: model)
                    .frame(height: 230)

                Text("Drag points to shape the curve. Click empty space to add a point. Right-click an interior point to remove it. Double-click the graph to reset.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Text("Exposure & Curves")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button { model.resetToneSection() } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.plain)
                    .help("Reset all Exposure & Curves controls, recovery controls, points, and the Tone Curve to neutral.")
            }
        }
        .padding(10)
        .background(StudioPalette.recessed, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(StudioPalette.subtleBorder, lineWidth: 0.5)
        }
    }
    private var colorDensitySection: some View {
        let density = model.selectedLook.colorDensity ?? ColorDensitySettings()
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text("Density changes how deep a color feels in the log-domain host grade before the film simulation. It is different from Saturation: density can make a color feel richer without simply pushing every channel farther apart.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                DensitySlider(label: "Master", value: density.master, key: "master", model: model,
                              help: "Moves all six color-density corners together. Right makes colors feel denser/richer; left makes them lighter/thinner.")
                DensitySlider(label: "Red", value: density.red, key: "red", model: model,
                              help: "Changes density around reds while smoothly blending into neighboring colors.")
                DensitySlider(label: "Yellow", value: density.yellow, key: "yellow", model: model,
                              help: "Changes density around yellows while smoothly blending into neighboring colors.")
                DensitySlider(label: "Green", value: density.green, key: "green", model: model,
                              help: "Changes density around greens while smoothly blending into neighboring colors.")
                DensitySlider(label: "Cyan", value: density.cyan, key: "cyan", model: model,
                              help: "Changes density around cyans while smoothly blending into neighboring colors.")
                DensitySlider(label: "Blue", value: density.blue, key: "blue", model: model,
                              help: "Changes density around blues while smoothly blending into neighboring colors.")
                DensitySlider(label: "Magenta", value: density.magenta, key: "magenta", model: model,
                              help: "Changes density around magentas while smoothly blending into neighboring colors.")

                Toggle("Preserve Luminance", isOn: Binding(
                    get: { density.preserveLuma },
                    set: { model.setColorDensityPreserveLuma($0) }
                ))
                .help("Tries to keep brightness steady while density changes colorfulness. Turn it off if you want density to also affect brightness.")
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Text("Color Density")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button { model.resetColorDensity() } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.plain)
                    .help("Reset all Color Density controls.")
            }
        }
        .padding(10)
        .background(StudioPalette.recessed, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(StudioPalette.subtleBorder, lineWidth: 0.5)
        }
    }

    private var geometrySection: some View {
        let geometry = model.selectedLook.geometry ?? GeometrySettings()
        return DisclosureGroup(isExpanded: $geometryExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Crop handles are live in the viewer while this section is open.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Menu("Aspect") {
                        ForEach(CropPresetCategory.allCases) { category in
                            Section(category.rawValue) {
                                ForEach(CropAspectPreset.all.filter { $0.category == category }) { preset in
                                    Button(preset.label) { model.applyCropPreset(preset) }
                                }
                            }
                        }
                    }
                    .controlSize(.small)
                    .help("Choose a common photo, print, social-media, or cinema frame shape.")
                }

                Picker("Guide", selection: Binding(
                    get: { geometry.overlayGuide },
                    set: { value in model.setGeometrySettings(interactive: false, changedParameter: "cropGuide") { $0.overlayGuide = value } }
                )) {
                    ForEach(CropOverlayGuide.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .help("Changes only the crop guide drawn over the photo. It does not change the image.")

                Divider().opacity(0.5)

                HStack {
                    Text("Geometry")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    if model.isGeometryAnalyzing { ProgressView().controlSize(.mini) }
                    Menu(geometry.autoMode.rawValue == "Off" ? "Auto Geometry" : geometry.autoMode.rawValue) {
                        ForEach(GeometryAutoMode.allCases.filter { $0 != .off && $0 != .guided }) { mode in
                            Button(mode.rawValue) { model.autoGeometry(mode) }
                        }
                    }
                    .controlSize(.small)
                    .help("Level straightens the horizon. Vertical corrects leaning vertical lines. Full corrects both vertical and horizontal perspective. Auto chooses a balanced correction.")
                }

                DraftScalarSlider(
                    label: "Straighten",
                    committedValue: geometry.rotationDegrees,
                    range: -45...45,
                    precision: 2,
                    helpText: "Rotates the photo to level a tilted horizon. Move left or right until horizontal lines look level.",
                    resetValue: 0,
                    onReset: { model.setGeometrySettings(interactive: false, changedParameter: "geometryRotation") { $0.rotationDegrees = 0 } },
                    onBegin: { model.beginEditGesture() },
                    onChange: { value in model.setGeometrySettings(interactive: true, changedParameter: "geometryRotation") { $0.rotationDegrees = value } },
                    onEnd: { model.endEditGesture() }
                )

                DraftScalarSlider(
                    label: "Vertical",
                    committedValue: geometry.verticalPerspective,
                    range: -100...100,
                    precision: 1,
                    helpText: "Corrects vertical lines that lean inward or outward, like buildings photographed from below or above.",
                    resetValue: 0,
                    onReset: { model.setGeometrySettings(interactive: false, changedParameter: "geometryVertical") { $0.verticalPerspective = 0 } },
                    onBegin: { model.beginEditGesture() },
                    onChange: { value in model.setGeometrySettings(interactive: true, changedParameter: "geometryVertical") { $0.verticalPerspective = value } },
                    onEnd: { model.endEditGesture() }
                )

                DraftScalarSlider(
                    label: "Horizontal",
                    committedValue: geometry.horizontalPerspective,
                    range: -100...100,
                    precision: 1,
                    helpText: "Corrects sideways perspective when one side of the scene looks farther away than the other.",
                    resetValue: 0,
                    onReset: { model.setGeometrySettings(interactive: false, changedParameter: "geometryHorizontal") { $0.horizontalPerspective = 0 } },
                    onBegin: { model.beginEditGesture() },
                    onChange: { value in model.setGeometrySettings(interactive: true, changedParameter: "geometryHorizontal") { $0.horizontalPerspective = value } },
                    onEnd: { model.endEditGesture() }
                )

                DraftScalarSlider(
                    label: "Aspect",
                    committedValue: geometry.aspect,
                    range: -100...100,
                    precision: 1,
                    helpText: "Stretches or squeezes the corrected image horizontally. Use it when perspective correction makes people or objects look too wide or too narrow.",
                    resetValue: 0,
                    onReset: { model.setGeometrySettings(interactive: false, changedParameter: "geometryAspect") { $0.aspect = 0 } },
                    onBegin: { model.beginEditGesture() },
                    onChange: { value in model.setGeometrySettings(interactive: true, changedParameter: "geometryAspect") { $0.aspect = value } },
                    onEnd: { model.endEditGesture() }
                )

                DraftScalarSlider(
                    label: "Scale",
                    committedValue: geometry.scale,
                    range: 50...400,
                    precision: 1,
                    helpText: "Zooms the corrected photo in or out. Increase it to hide empty edges after straightening or perspective correction.",
                    resetValue: 100,
                    onReset: { model.setGeometrySettings(interactive: false, changedParameter: "geometryScale") { $0.scale = 100 } },
                    onBegin: { model.beginEditGesture() },
                    onChange: { value in model.setGeometrySettings(interactive: true, changedParameter: "geometryScale") { $0.scale = value } },
                    onEnd: { model.endEditGesture() }
                )

                DraftScalarSlider(
                    label: "X Offset",
                    committedValue: geometry.xOffset,
                    range: -100...100,
                    precision: 1,
                    helpText: "Moves the corrected image left or right inside the frame. Use it after perspective correction to reposition the subject without changing the crop shape.",
                    resetValue: 0,
                    onReset: { model.setGeometrySettings(interactive: false, changedParameter: "geometryXOffset") { $0.xOffset = 0 } },
                    onBegin: { model.beginEditGesture() },
                    onChange: { value in model.setGeometrySettings(interactive: true, changedParameter: "geometryXOffset") { $0.xOffset = value } },
                    onEnd: { model.endEditGesture() }
                )

                DraftScalarSlider(
                    label: "Y Offset",
                    committedValue: geometry.yOffset,
                    range: -100...100,
                    precision: 1,
                    helpText: "Moves the corrected image up or down inside the frame. It is useful for centering architecture or giving a portrait more headroom after correction.",
                    resetValue: 0,
                    onReset: { model.setGeometrySettings(interactive: false, changedParameter: "geometryYOffset") { $0.yOffset = 0 } },
                    onBegin: { model.beginEditGesture() },
                    onChange: { value in model.setGeometrySettings(interactive: true, changedParameter: "geometryYOffset") { $0.yOffset = value } },
                    onEnd: { model.endEditGesture() }
                )

                HStack(spacing: 8) {
                    Toggle("Auto Fill Edges", isOn: Binding(
                        get: { geometry.autoCrop },
                        set: { value in model.setGeometrySettings(interactive: false, changedParameter: "geometryAutoCrop") { $0.autoCrop = value } }
                    ))
                    .help("Automatically adds only the zoom needed to keep the active crop free of black edges after rotation or perspective correction.")
                    Spacer()
                    Button { model.rotateCropQuarterTurn(clockwise: false) } label: { Image(systemName: "rotate.left") }
                        .help("Rotate 90° left")
                    Button { model.rotateCropQuarterTurn(clockwise: true) } label: { Image(systemName: "rotate.right") }
                        .help("Rotate 90° right")
                    Button {
                        model.setGeometrySettings(interactive: false, changedParameter: "geometryFlipH") { $0.flipHorizontal.toggle() }
                    } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                    .help("Flip the photo left-to-right")
                    Button {
                        model.setGeometrySettings(interactive: false, changedParameter: "geometryFlipV") { $0.flipVertical.toggle() }
                    } label: { Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down") }
                    .help("Flip the photo top-to-bottom")
                }
                .buttonStyle(.borderless)
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Text("Crop & Geometry")
                    .font(.caption.weight(.semibold))
                Spacer()
                if geometryExpanded {
                    Image(systemName: "crop")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Button { model.resetGeometry() } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.plain)
                    .help("Reset crop, rotation, perspective, scale, flips, and geometry guides.")
            }
        }
        .onChange(of: geometryExpanded) { _, expanded in
            model.setCropToolActive(expanded)
        }
        .padding(10)
        .background(StudioPalette.recessed, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(StudioPalette.subtleBorder, lineWidth: 0.5)
        }
    }
}

private struct DensitySlider: View {
    let label: String
    let value: Double
    let key: String
    @ObservedObject var model: AppModel
    let help: String

    var body: some View {
        DraftScalarSlider(
            label: label,
            committedValue: value,
            range: -1...1,
            precision: 2,
            helpText: help,
            resetValue: 0,
            onReset: { model.setColorDensity(key, value: 0, interactive: false) },
            onBegin: { model.beginEditGesture() },
            onChange: { model.setColorDensity(key, value: $0, interactive: true) },
            onEnd: { model.endEditGesture() }
        )
    }
}

struct ParameterControlRow: View {
    @ObservedObject var model: AppModel
    let descriptor: ParameterDescriptor
    let options: [String]

    private var value: ParameterValue {
        model.selectedLook.values[descriptor.name] ?? descriptor.defaultValue
    }

    var body: some View {
        switch descriptor.kind {
        case .bool:
            Toggle(descriptor.label, isOn: Binding(
                get: { if case .bool(let v) = value { return v }; return descriptor.defaultInt != 0 },
                set: { model.setParameter(descriptor.name, value: .bool($0), interactive: false) }
            ))

        case .choice, .filmStock, .printPaper:
            Picker(descriptor.label, selection: Binding(
                get: { Int(value.intValue) },
                set: { model.setParameter(descriptor.name, value: .int(Int32($0)), interactive: false) }
            )) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, label in
                    Text(label).tag(index)
                }
            }
            .pickerStyle(.menu)

        case .int:
            IntegerParameterControl(model: model, descriptor: descriptor, value: Int(value.intValue))

        case .double:
            DraftScalarSlider(
                label: descriptor.label,
                committedValue: value.scalarValue,
                range: descriptor.minimum...descriptor.maximum,
                precision: 3,
                helpText: EditorBeginnerHelp.parameter(descriptor),
                resetValue: descriptor.defaults.0,
                onReset: { model.resetParameter(descriptor.name) },
                onBegin: { model.beginEditGesture() },
                onChange: { model.setParameter(descriptor.name, value: .scalar($0), interactive: true) },
                onEnd: { model.endEditGesture() }
            )

        case .double2:
            VectorParameterControl(model: model, descriptor: descriptor, count: 2, value: value)

        case .double3:
            VectorParameterControl(model: model, descriptor: descriptor, count: 3, value: value)
        }
    }
}

private struct IntegerParameterControl: View {
    @ObservedObject var model: AppModel
    let descriptor: ParameterDescriptor
    let value: Int

    var body: some View {
        HStack {
            Text(descriptor.label)
            Spacer()
            Button { model.resetParameter(descriptor.name) } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 9, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Reset \(descriptor.label)")
            Stepper(
                value: Binding(
                    get: { value },
                    set: { model.setParameter(descriptor.name, value: .int(Int32($0)), interactive: false) }
                ),
                in: Int(descriptor.minimum.rounded())...Int(descriptor.maximum.rounded())
            ) {
                Text("\(value)").monospacedDigit().frame(minWidth: 58, alignment: .trailing)
            }
            .help(EditorBeginnerHelp.parameter(descriptor))
        }
        .help(EditorBeginnerHelp.parameter(descriptor))
    }
}

private struct DraftScalarSlider: View {
    let label: String
    let committedValue: Double
    let range: ClosedRange<Double>
    let precision: Int
    let disabled: Bool
    let helpText: String
    let resetValue: Double?
    let onReset: (() -> Void)?
    let onBegin: () -> Void
    let onChange: (Double) -> Void
    let onEnd: () -> Void

    @State private var draft: Double
    @State private var editing = false

    init(
        label: String,
        committedValue: Double,
        range: ClosedRange<Double>,
        precision: Int,
        disabled: Bool = false,
        helpText: String = "",
        resetValue: Double? = nil,
        onReset: (() -> Void)? = nil,
        onBegin: @escaping () -> Void,
        onChange: @escaping (Double) -> Void,
        onEnd: @escaping () -> Void
    ) {
        self.label = label
        self.committedValue = committedValue
        self.range = range
        self.precision = precision
        self.disabled = disabled
        self.helpText = helpText
        self.resetValue = resetValue
        self.onReset = onReset
        self.onBegin = onBegin
        self.onChange = onChange
        self.onEnd = onEnd
        _draft = State(initialValue: committedValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(label)
                Spacer()
                if let onReset {
                    Button {
                        if let resetValue { draft = resetValue }
                        onReset()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .help("Reset \(label)")
                }
                Text(draft, format: .number.precision(.fractionLength(0...precision)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { draft },
                set: { newValue in
                    draft = newValue
                    onChange(newValue)
                }
            ), in: range, onEditingChanged: { isEditing in
                editing = isEditing
                if isEditing { onBegin() } else { onEnd() }
            })
            .disabled(disabled)
            .help(helpText.isEmpty ? "Move left to reduce \(label.lowercased()) and right to increase it." : helpText)
        }
        .help(helpText.isEmpty ? "Move left to reduce \(label.lowercased()) and right to increase it." : helpText)
        .onChange(of: committedValue) { _, newValue in
            if !editing { draft = newValue }
        }
    }
}

private struct VectorParameterControl: View {
    @ObservedObject var model: AppModel
    let descriptor: ParameterDescriptor
    let count: Int
    let value: ParameterValue

    @State private var draft: [Double]
    @State private var editing = false

    init(model: AppModel, descriptor: ParameterDescriptor, count: Int, value: ParameterValue) {
        self.model = model
        self.descriptor = descriptor
        self.count = count
        self.value = value
        let initial: [Double]
        switch value {
        case .vector2(let a, let b): initial = [a, b, 0]
        case .vector3(let a, let b, let c): initial = [a, b, c]
        default: initial = [descriptor.defaults.0, descriptor.defaults.1, descriptor.defaults.2]
        }
        _draft = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(descriptor.label)
                Spacer()
                Button { model.resetParameter(descriptor.name) } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 9, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Reset \(descriptor.label)")
            }
            ForEach(0..<count, id: \.self) { component in
                HStack {
                    Text(["R", "G", "B"][component]).frame(width: 16)
                    Slider(value: Binding(
                        get: { draft[component] },
                        set: { newValue in
                            draft[component] = newValue
                            let p: ParameterValue = count == 2
                                ? .vector2(draft[0], draft[1])
                                : .vector3(draft[0], draft[1], draft[2])
                            model.setParameter(descriptor.name, value: p, interactive: true)
                        }
                    ), in: descriptor.minimum...descriptor.maximum, onEditingChanged: { isEditing in
                        editing = isEditing
                        if isEditing { model.beginEditGesture() } else { model.endEditGesture() }
                    })
                    .help(EditorBeginnerHelp.parameter(descriptor) + " This slider adjusts the \(["R", "G", "B"][component]) component.")
                    Text(draft[component], format: .number.precision(.fractionLength(2)))
                        .monospacedDigit()
                        .frame(width: 54)
                }
            }
        }
        .onChange(of: value) { _, newValue in
            guard !editing else { return }
            switch newValue {
            case .vector2(let a, let b): draft = [a, b, 0]
            case .vector3(let a, let b, let c): draft = [a, b, c]
            default: break
            }
        }
    }
}

private struct WhiteBalanceTemperatureSlider: View {
    let label: String
    let committedKelvin: Double
    let disabled: Bool
    let helpText: String
    let onReset: (() -> Void)?
    let onBegin: () -> Void
    let onChange: (Double) -> Void
    let onEnd: () -> Void

    @State private var draftKelvin: Double
    @State private var editing = false

    init(
        label: String,
        committedKelvin: Double,
        disabled: Bool = false,
        helpText: String = "",
        onReset: (() -> Void)? = nil,
        onBegin: @escaping () -> Void,
        onChange: @escaping (Double) -> Void,
        onEnd: @escaping () -> Void
    ) {
        self.label = label
        self.committedKelvin = committedKelvin
        self.disabled = disabled
        self.helpText = helpText
        self.onReset = onReset
        self.onBegin = onBegin
        self.onChange = onChange
        self.onEnd = onEnd
        _draftKelvin = State(initialValue: PixelBufferF32.clampedKelvin(committedKelvin))
    }

    private var reciprocalPosition: Double {
        -1_000_000.0 / PixelBufferF32.clampedKelvin(draftKelvin)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(label)
                Spacer()
                if let onReset {
                    Button(action: onReset) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .help("Reset \(label)")
                }
                Text("\(Int(draftKelvin.rounded())) K")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { reciprocalPosition },
                    set: { position in
                        let kelvin = PixelBufferF32.clampedKelvin(-1_000_000.0 / position)
                        draftKelvin = kelvin
                        onChange(kelvin)
                    }
                ),
                in: -500 ... -20,
                onEditingChanged: { isEditing in
                    editing = isEditing
                    if isEditing { onBegin() } else { onEnd() }
                }
            )
            .disabled(disabled)
            .help(helpText)
        }
        .help(helpText)
        .onChange(of: committedKelvin) { _, newValue in
            if !editing { draftKelvin = PixelBufferF32.clampedKelvin(newValue) }
        }
    }
}

private enum EditorBeginnerHelp {
    static func parameter(_ descriptor: ParameterDescriptor) -> String {
        let key = (descriptor.name + " " + descriptor.label).lowercased()
        func text(_ what: String, _ left: String, _ right: String, _ behavior: String = "") -> String {
            let extra = behavior.isEmpty ? "" : " " + behavior
            return "\(what) Move left to \(left) and right to \(right).\(extra)"
        }
        if key.contains("exposure") { return text("Changes overall brightness.", "darken the image", "brighten the image", "Exposure controls usually work early in the image pipeline, so they can change how the film response handles highlights and shadows.") }
        if key.contains("contrast") { return text("Changes the difference between dark and bright areas.", "make tones softer/flatter", "make tones more separated/punchy") }
        if key.contains("density") { return text("Changes how deep and rich the image feels.", "make it lighter/thinner", "make it denser/richer") }
        if key.contains("satur") || key.contains("chroma") { return text("Changes color intensity.", "mute colors", "make colors stronger") }
        if key.contains("grain") && key.contains("size") { return text("Changes the visible grain size.", "make grain finer", "make grain larger") }
        if key.contains("grain") { return text("Changes the amount or strength of film grain.", "reduce grain", "increase grain") }
        if key.contains("halation") { return text("Adds the warm glow that can form around very bright edges on film.", "reduce the glow", "increase the glow") }
        if key.contains("bloom") { return text("Adds a soft light spread around highlights.", "keep highlights tighter", "make highlight glow softer and wider") }
        if key.contains("sharp") || key.contains("texture") || key.contains("detail") { return text("Changes fine edge/detail definition.", "soften fine detail", "make fine detail more obvious") }
        if key.contains("highlight") || key.contains("shoulder") { return text("Changes the bright end of the image.", "hold/compress bright tones more", "open or strengthen bright tones") }
        if key.contains("shadow") || key.contains("toe") { return text("Changes the dark end of the image.", "deepen or compress dark tones", "lift/open dark tones") }
        if key.contains("black") { return text("Changes the darkest point of the image.", "lift blacks", "deepen blacks") }
        if key.contains("white") { return text("Changes the brightest point of the image.", "lower the white point", "raise the white point") }
        if key.contains("blur") || key.contains("mist") || key.contains("promist") { return text("Changes optical softness/glow.", "keep the image cleaner", "make the image softer and more diffused") }
        if key.contains("vignette") { return text("Changes darkening toward the edges of the frame.", "reduce edge darkening", "increase edge darkening") }
        if key.contains("hue") { return text("Rotates the selected color around the color wheel.", "shift it one direction", "shift it the other direction") }
        if key.contains("temperature") { return text("Changes color warmth.", "make the image cooler/bluer", "make it warmer/yellower") }
        if key.contains("tint") { return text("Corrects green versus magenta color cast.", "move toward green", "move toward magenta") }
        return text("Adjusts \(descriptor.label.lowercased()).", "reduce the effect", "increase the effect")
    }
}

private struct ToneCurveEditorView: View {
    @ObservedObject var model: AppModel
    @State private var draftPoints: [ToneCurvePoint] = ToneCurvePreset.linear.points
    @State private var draggingIndex: Int?

    private var committedPoints: [ToneCurvePoint] {
        ToneCurveMath.normalize(model.selectedLook.tone?.curvePoints ?? ToneCurvePreset.linear.points)
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.black.opacity(0.28))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(StudioPalette.subtleBorder, lineWidth: 0.5)
                    }

                Canvas { context, canvas in
                    drawGrid(context: &context, size: canvas)
                    drawIdentity(context: &context, size: canvas)
                    drawCurve(context: &context, size: canvas)
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .simultaneousGesture(
                    SpatialTapGesture(count: 2).onEnded { _ in
                        draftPoints = ToneCurvePreset.linear.points
                        model.resetToneCurve()
                    }
                )
                .simultaneousGesture(
                    SpatialTapGesture().onEnded { value in
                        guard draggingIndex == nil else { return }
                        addPoint(at: value.location, size: size)
                    }
                )

                ForEach(Array(draftPoints.indices), id: \.self) { index in
                    let point = screenPoint(draftPoints[index], size: size)
                    Circle()
                        .fill(index == draggingIndex ? Color.white : Color.white.opacity(0.88))
                        .overlay(Circle().stroke(Color.black.opacity(0.7), lineWidth: 1))
                        .frame(width: index == draggingIndex ? 11 : 9, height: index == draggingIndex ? 11 : 9)
                        .position(point)
                        .contentShape(Circle().inset(by: -7))
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                .onChanged { drag in
                                    if draggingIndex == nil {
                                        draggingIndex = index
                                        model.beginEditGesture()
                                    }
                                    movePoint(index: index, to: drag.location, size: size)
                                }
                                .onEnded { _ in
                                    guard draggingIndex != nil else { return }
                                    draggingIndex = nil
                                    model.endEditGesture()
                                }
                        )
                        .contextMenu {
                            if index > 0 && index < draftPoints.count - 1 {
                                Button("Remove Point") { removePoint(index) }
                            }
                        }
                }
            }
        }
        .onAppear { draftPoints = committedPoints }
        .onChange(of: committedPoints) { _, newValue in
            if draggingIndex == nil { draftPoints = newValue }
        }
    }

    private func drawGrid(context: inout GraphicsContext, size: CGSize) {
        for i in 1..<4 {
            let f = CGFloat(i) / 4
            var horizontal = Path()
            horizontal.move(to: CGPoint(x: 0, y: size.height * f))
            horizontal.addLine(to: CGPoint(x: size.width, y: size.height * f))
            context.stroke(horizontal, with: .color(.secondary.opacity(0.18)), lineWidth: 0.5)

            var vertical = Path()
            vertical.move(to: CGPoint(x: size.width * f, y: 0))
            vertical.addLine(to: CGPoint(x: size.width * f, y: size.height))
            context.stroke(vertical, with: .color(.secondary.opacity(0.18)), lineWidth: 0.5)
        }
    }

    private func drawIdentity(context: inout GraphicsContext, size: CGSize) {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height))
        path.addLine(to: CGPoint(x: size.width, y: 0))
        context.stroke(path, with: .color(.secondary.opacity(0.32)), style: StrokeStyle(lineWidth: 0.75, dash: [4, 4]))
    }

    private func drawCurve(context: inout GraphicsContext, size: CGSize) {
        let points = ToneCurveMath.normalize(draftPoints)
        let cache = ToneCurveMath.buildCache(points)
        var path = Path()
        let samples = max(96, Int(size.width.rounded()))
        for i in 0...samples {
            let x = Double(i) / Double(samples)
            let y = ToneCurveMath.evaluate(x, points: points, cache: cache)
            let p = CGPoint(x: CGFloat(x) * size.width, y: (1 - CGFloat(y)) * size.height)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        context.stroke(path, with: .color(.white.opacity(0.94)), lineWidth: 1.6)
    }

    private func screenPoint(_ point: ToneCurvePoint, size: CGSize) -> CGPoint {
        CGPoint(x: CGFloat(point.x) * size.width, y: (1 - CGFloat(point.y)) * size.height)
    }

    private func normalizedPoint(_ point: CGPoint, size: CGSize) -> ToneCurvePoint {
        ToneCurvePoint(
            x: min(1, max(0, Double(point.x / max(1, size.width)))),
            y: min(1, max(0, 1 - Double(point.y / max(1, size.height))))
        )
    }

    private func movePoint(index: Int, to location: CGPoint, size: CGSize) {
        guard draftPoints.indices.contains(index) else { return }
        var next = draftPoints
        var value = normalizedPoint(location, size: size)
        if index == 0 { value.x = 0 }
        if index == next.count - 1 { value.x = 1 }
        if index > 0 { value.x = max(value.x, next[index - 1].x + ToneCurveMath.minimumPointSpacing) }
        if index + 1 < next.count { value.x = min(value.x, next[index + 1].x - ToneCurveMath.minimumPointSpacing) }
        next[index] = value
        draftPoints = ToneCurveMath.normalize(next)
        model.setToneCurvePoints(draftPoints, interactive: true)
    }

    private func addPoint(at location: CGPoint, size: CGSize) {
        guard draftPoints.count < ToneCurveMath.maximumControlPoints else { return }
        let point = normalizedPoint(location, size: size)
        // Clicking an existing handle should not insert another point underneath it.
        let tooClose = draftPoints.contains { existing in
            let p = screenPoint(existing, size: size)
            return hypot(p.x - location.x, p.y - location.y) < 14
        }
        guard !tooClose else { return }
        var next = draftPoints
        next.append(point)
        next = ToneCurveMath.normalize(next)
        draftPoints = next
        model.setToneCurvePoints(next, interactive: false)
    }

    private func removePoint(_ index: Int) {
        guard index > 0, index < draftPoints.count - 1 else { return }
        var next = draftPoints
        next.remove(at: index)
        next = ToneCurveMath.normalize(next)
        draftPoints = next
        model.setToneCurvePoints(next, interactive: false)
    }
}
