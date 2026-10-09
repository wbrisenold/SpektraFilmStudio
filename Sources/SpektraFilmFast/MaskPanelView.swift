import SwiftUI
import AppKit
import CoreGraphics


struct MaskPanelView: View {
    @ObservedObject var model: AppModel
    @State private var namingPreset = false
    @State private var presetName = ""
    @State private var presetRevision = 0
    @State private var detectedPeople: [PersonFound] = []
    @AppStorage("SpektraFilmFast.maskOverlayEnabled") private var overlayEnabled = true
    @AppStorage("SpektraFilmFast.redlampOverlayStyle") private var overlayStyle = RedlampMaskDisplayStyle.color.rawValue

    private var grades: [LocalGradeRecord] { model.selectedLook.localGrades ?? [] }
    private var selectedGrade: LocalGradeRecord? {
        guard let id = model.activeLocalGradeID else { return nil }
        return grades.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Text("MASKS").font(.caption.weight(.semibold))
                Spacer()
                Toggle("Overlay", isOn: $overlayEnabled)
                    .toggleStyle(.checkbox).font(.caption2)
            }

            HStack(spacing: 8) {
                Menu {
                    Section("AI Selections") {
                        Button("Subject") { model.createAIMask(AIMaskRecipe(kind: .subject)) }
                        Button("Background") { model.createAIMask(AIMaskRecipe(kind: .background)) }
                        Button("Sky") { model.createAIMask(AIMaskRecipe(kind: .sky)) }
                        Menu("People") {
                            ForEach(PersonPart.allCases, id: \.self) { part in
                                Menu(part.name) {
                                    Button("Everyone") { model.createAIMask(AIMaskRecipe(kind: .people, part: part)) }
                                    ForEach(Array(detectedPeople.enumerated()), id: \.offset) { index, person in
                                        Button("Person \(index + 1)") {
                                            let facePart = [.faceSkin, .eyebrows, .eyeSclera, .iris, .lips, .teeth].contains(part)
                                            var recipe = AIMaskRecipe(kind: .people, part: part)
                                            recipe.instance = facePart ? person.faceInstance : person.instance
                                            model.createAIMask(recipe)
                                        }.disabled([PersonPart.faceSkin, .eyebrows, .eyeSclera, .iris, .lips, .teeth].contains(part) && person.faceInstance == nil)
                                    }
                                }
                            }
                        }
                        Menu("Landscape") {
                            ForEach(LandscapeClass.allCases, id: \.self) { landscape in
                                Button(landscape.name) { model.createAIMask(AIMaskRecipe(kind: .landscape, landscape: landscape)) }
                            }
                        }
                        Button("Depth Range") { model.createAIMask(AIMaskRecipe(kind: .depthRange)) }
                    }
                    Section("Draw on Image") {
                        Button("Brush") { model.beginMaskBrush(newGrade: true) }
                        Button("Linear Gradient") { makeGeometric(.linearGradient) }
                        Button("Radial Gradient") { makeGeometric(.radial) }
                        Button("Pick Object") {
                            let id = model.addLocalGrade()
                            model.selectLocalGrade(id)
                            overlayEnabled = true
                            model.beginObjectMaskPick(gradeID: id, blendMode: .add)
                        }
                    }
                } label: {
                    Label("New Mask", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .fixedSize()

                Menu("Presets") {
                    ForEach(StudioMaskPreset.builtIn) { preset in
                        Button(preset.name) { model.applyMaskPreset(preset) }
                    }
                    Divider()
                    ForEach(StudioMaskPreset.custom) { preset in
                        Button(preset.name) { model.applyMaskPreset(preset) }
                    }
                    Button("Save Current Mask…") { namingPreset = true }
                        .disabled(selectedGrade == nil)
                }.id(presetRevision).controlSize(.small).fixedSize()
                Spacer()
            }
            HStack(spacing: 10) {
                Button { model.beginMaskBrush() } label: { Label("Brush", systemImage: "paintbrush.pointed") }
                    .controlSize(.small).fixedSize()
                Button {
                    model.updateAIMasks()
                } label: { Label("Update AI Masks", systemImage: "sparkles") }
                .controlSize(.small).fixedSize()
                Spacer(minLength: 1)
                Menu {
                    ForEach(RedlampMaskDisplayStyle.allCases) { style in
                        Button {
                            overlayStyle = style.rawValue
                            overlayEnabled = true
                        } label: {
                            if overlayStyle == style.rawValue { Label(style.rawValue, systemImage: "checkmark") }
                            else { Text(style.rawValue) }
                        }
                    }
                } label: { Image(systemName: "circle.lefthalf.filled") }
                    .controlSize(.small)
                    .help("Mask overlay appearance — adapted from Redlamp")
            }

            Text(model.semanticMaskStatus)
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if grades.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Make your first mask")
                        .font(.subheadline.weight(.semibold))
                    Text("Choose Subject, Skin, Object, or a gradient. Adjust this selection below without leaving Masks.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(StudioPalette.recessed, in: RoundedRectangle(cornerRadius: 8))
            } else {
                ForEach(grades) { grade in
                    HStack(spacing: 7) {
                        Button {
                            model.selectLocalGrade(grade.id)
                            overlayEnabled = true
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: model.activeLocalGradeID == grade.id
                                      ? "circle.dotted.circle.fill" : "circle.dotted")
                                    .foregroundStyle(model.activeLocalGradeID == grade.id ? .red : .secondary)
                                Text(grade.name).font(.subheadline).lineLimit(1)
                                Spacer()
                                Text("\(grade.masks.sources.filter(\.enabled).count)")
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        Button(role: .destructive) { model.removeLocalGrade(grade.id) } label: {
                            Image(systemName: "trash").font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(8)
                    .background(model.activeLocalGradeID == grade.id ? StudioPalette.selected : StudioPalette.recessed,
                                in: RoundedRectangle(cornerRadius: 7))
                }
            }

            if let grade = selectedGrade {
                Divider()
                HStack {
                    Text("COMPONENTS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Menu("Add") {
                        Button("Brush") { model.beginMaskBrush(gradeID: grade.id) }
                        Button("Subject") { addSemantic(.subject, gradeID: grade.id, blend: .add) }
                        Button("Skin") { addSemantic(.skin, gradeID: grade.id, blend: .add) }
                        Button("Background") { addSemantic(.background, gradeID: grade.id, blend: .add) }
                        Button("Linear Gradient") { model.addMaskSource(gradeID: grade.id, kind: .linearGradient) }
                        Button("Radial Gradient") { model.addMaskSource(gradeID: grade.id, kind: .radial) }
                    }.controlSize(.small)
                    Menu("Subtract") {
                        Button("Brush") { model.beginMaskBrush(gradeID: grade.id, blend: .subtract) }
                        Button("Subject") { addSemantic(.subject, gradeID: grade.id, blend: .subtract) }
                        Button("Background") { addSemantic(.background, gradeID: grade.id, blend: .subtract) }
                        Button("Pick Object") {
                            model.beginObjectMaskPick(gradeID: grade.id, blendMode: .subtract)
                        }
                    }.controlSize(.small)
                }
                ForEach(grade.masks.sources) { source in
                    HStack(spacing: 5) {
                        Toggle("", isOn: Binding(
                            get: { source.enabled },
                            set: { model.setMaskEnabled(gradeID: grade.id, maskID: source.id, $0) }
                        )).labelsHidden().toggleStyle(.checkbox)
                        Text(source.name).font(.caption).lineLimit(1)
                        Spacer()
                        Text(source.blendMode.rawValue).font(.caption2).foregroundStyle(.secondary)
                        if source.kind == .linearGradient {
                            Button { model.selectedGradientMaskID = source.id; model.isGradientMaskEditing = true }
                                label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                                .buttonStyle(.borderless)
                        }
                        if let recipe = source.aiRecipe, recipe.kind != .depthRange {
                            Button("Refine Edges") { model.refineAIMask(gradeID: grade.id, sourceID: source.id) }
                                .controlSize(.mini)
                        }
                        Button(role: .destructive) {
                            model.removeMaskSource(gradeID: grade.id, maskID: source.id)
                        } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                    }
                    if let recipe = source.aiRecipe {
                        if recipe.kind == .depthRange {
                            LabeledContent("Far limit") {
                                Slider(value: Binding(get: { recipe.depthLower }, set: { model.setDepthMaskRange(gradeID: grade.id, sourceID: source.id, lower: $0) }), in: 0...1)
                            }
                            LabeledContent("Near limit") {
                                Slider(value: Binding(get: { recipe.depthUpper }, set: { model.setDepthMaskRange(gradeID: grade.id, sourceID: source.id, upper: $0) }), in: 0...1)
                            }
                        } else {
                        HStack {
                            Text("Feather").font(.caption).frame(width: 50, alignment: .leading)
                            Slider(value: Binding(get: { recipe.feather }, set: { model.setAIMaskShape(gradeID: grade.id, sourceID: source.id, feather: $0) }), in: 0...100)
                            Text("\(Int(recipe.feather))").font(.caption.monospacedDigit()).frame(width: 30)
                        }
                        HStack {
                            Text("Edge").font(.caption).frame(width: 50, alignment: .leading)
                            Slider(value: Binding(get: { recipe.edge }, set: { model.setAIMaskShape(gradeID: grade.id, sourceID: source.id, edge: $0) }), in: -100...100)
                            Text("\(Int(recipe.edge))").font(.caption.monospacedDigit()).frame(width: 30)
                        }
                        }
                    }
                }

                Divider()
                Text("LOCAL ADJUSTMENTS").font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Changes below affect only the selected red area. Switching to RAW edits the complete photo automatically.")
                    .font(.caption2).foregroundStyle(.secondary)
                let tone = grade.tone ?? ToneSettings()
                localSlider("Exposure", value: tone.exposureEV, range: -5...5,
                            key: "exposure", gradeID: grade.id)
                localSlider("Contrast", value: tone.contrast, range: -100...100,
                            key: "contrast", gradeID: grade.id)
                localSlider("Highlights", value: tone.highlights, range: -100...100,
                            key: "highlights", gradeID: grade.id)
                localSlider("Shadows", value: tone.shadows, range: -100...100,
                            key: "shadows", gradeID: grade.id)
                localSlider("Whites", value: tone.whites, range: -100...100,
                            key: "whites", gradeID: grade.id)
                localSlider("Blacks", value: tone.blacks, range: -100...100,
                            key: "blacks", gradeID: grade.id)
                let colour = grade.localColor ?? LocalMaskColorSettings()
                ForEach(["Saturation", "Temperature", "Texture", "Clarity"], id: \.self) { key in
                    let value = key == "Saturation" ? colour.saturation : (key == "Temperature" ? colour.temperature : (key == "Texture" ? colour.texture : colour.clarity))
                    HStack {
                        Text(key).font(.caption).frame(width: 80, alignment: .leading)
                        Slider(value: Binding(get: { value }, set: { model.setLocalMaskColor(grade.id, key: key, value: $0) }), in: -100...100)
                        Text("\(Int(value))").font(.caption.monospacedDigit()).frame(width: 30)
                    }
                }
                HStack {
                    Text("Mask Amount").font(.caption)
                    Slider(value: Binding(
                        get: { model.activeLocalGrade?.opacity ?? 1 },
                        set: { model.setLocalGradeOpacity(grade.id, $0) }
                    ), in: 0...1)
                    Text("\(Int(grade.opacity * 100))%").font(.caption.monospacedDigit()).frame(width: 40)
                }
            }
        }
        .padding(10)
        .task(id: model.project.selectedImageID) {
            detectedPeople = []
            guard let image = model.selectedImage else { return }
            let people = (try? await RedlampMaskService.shared.people(in: image.url)) ?? []
            guard !Task.isCancelled, model.project.selectedImageID == image.id else { return }
            detectedPeople = people
        }
        .alert("Save Mask Preset", isPresented: $namingPreset) {
            TextField("Preset name", text: $presetName)
            Button("Save") {
                let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty, let grade = selectedGrade {
                    StudioMaskPreset.save(name: name, grade: grade)
                    presetRevision += 1; presetName = ""
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear {
            if model.activeLocalGradeID == nil {
                if let existing = grades.first { model.selectLocalGrade(existing.id) }
            }
            if selectedGrade != nil { overlayEnabled = true }

        }
        .onChange(of: model.project.selectedImageID) { _, _ in
            if model.activeLocalGradeID == nil {
                if let existing = grades.first { model.selectLocalGrade(existing.id) }
            }
        }
    }

    private func makeSemantic(_ kind: SemanticMaskKind) {
        overlayEnabled = true
        model.createSemanticLocalGrade(kind)
    }
    private func addSemantic(_ kind: SemanticMaskKind, gradeID: UUID, blend: MaskBlendMode) {
        overlayEnabled = true
        let recipe: AIMaskRecipe
        switch kind {
        case .subject: recipe = AIMaskRecipe(kind: .subject)
        case .background: recipe = AIMaskRecipe(kind: .background)
        case .skin: recipe = AIMaskRecipe(kind: .people, part: .faceSkin)
        case .hair: recipe = AIMaskRecipe(kind: .people, part: .hair)
        default: recipe = AIMaskRecipe(kind: .people)
        }
        model.createAIMask(recipe, gradeID: gradeID, blend: blend)
    }
    private func makeGeometric(_ kind: MaskSourceKind) {
        let id = model.addLocalGrade()
        model.selectLocalGrade(id)
        overlayEnabled = true
        model.addMaskSource(gradeID: id, kind: kind)
    }

    private func localSlider(_ label: String, value: Double, range: ClosedRange<Double>,
                             key: String, gradeID: UUID) -> some View {
        DraftScalarSlider(label: label, committedValue: value, range: range,
                          precision: key == "exposure" ? 2 : 0, resetValue: 0,
                          onReset: { model.setLocalTone(gradeID, key, 0, interactive: false) },
                          onBegin: { model.beginEditGesture() },
                          onChange: { model.setLocalTone(gradeID, key, $0, interactive: true) },
                          onEnd: { model.endEditGesture() })
    }
}
// Draw only interaction handles here. RedlampMaskDisplay composites the actual coverage
// into the photographic pixels before SwiftUI lays out the image.
struct MaskOverlayView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if model.isGradientMaskEditing,
           let grade = model.activeLocalGrade,
           let sourceID = model.selectedGradientMaskID,
           let source = grade.masks.sources.first(where: { $0.id == sourceID && $0.kind == .linearGradient }),
           let gradient = source.linearGradient {
            GeometryReader { proxy in
                let image = model.frameState.renderedPreview
                let imageW = CGFloat(max(1, image?.width ?? 1))
                let imageH = CGFloat(max(1, image?.height ?? 1))
                let scale = min(proxy.size.width / imageW, proxy.size.height / imageH)
                let w = imageW * scale, h = imageH * scale
                let ox = (proxy.size.width - w) / 2, oy = (proxy.size.height - h) / 2
                let start = CGPoint(x: ox + w * CGFloat(gradient.start.x), y: oy + h * CGFloat(gradient.start.y))
                let end = CGPoint(x: ox + w * CGFloat(gradient.end.x), y: oy + h * CGFloat(gradient.end.y))
                Path { path in path.move(to: start); path.addLine(to: end) }
                    .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .allowsHitTesting(false)
                pin(point: start, start: true, grade: grade, source: source, geometry: gradient,
                    rect: CGRect(x: ox, y: oy, width: w, height: h))
                pin(point: end, start: false, grade: grade, source: source, geometry: gradient,
                    rect: CGRect(x: ox, y: oy, width: w, height: h))
            }
        }
    }
    private func pin(point: CGPoint, start: Bool, grade: LocalGradeRecord,
                     source: MaskSourceRecord, geometry: LinearGradientMaskGeometry, rect: CGRect) -> some View {
        Circle()
            .fill(start ? Color.red : Color.white)
            .overlay(Circle().stroke(.black, lineWidth: 1.5))
            .frame(width: 16, height: 16)
            .position(point)
            .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                guard rect.width > 0, rect.height > 0 else { return }
                let u = max(0, min(1, Double((point.x + v.translation.width - rect.minX) / rect.width)))
                let q = max(0, min(1, Double((point.y + v.translation.height - rect.minY) / rect.height)))
                let p = NormalizedPoint(x: u, y: q)
                model.setGradientEndpoints(gradeID: grade.id, maskID: source.id,
                                           start: start ? p : geometry.start,
                                           end: start ? geometry.end : p)
            })
    }
}

struct ObjectMaskPickOverlay: View {
    @ObservedObject var model: AppModel
    let imageWidth: Int
    let imageHeight: Int
    @State private var stroke: [CGPoint] = []
    @State private var hoverImage: CGImage?
    @State private var subtract = false
    @State private var cursor: CGPoint?

    var body: some View {
        GeometryReader { proxy in
            let imageRect = fittedImageRect(in: proxy.size)
            ZStack(alignment: .top) {
                if let hoverImage {
                    Color.red.opacity(0.45)
                        .frame(width: imageRect.width, height: imageRect.height)
                        .mask(Image(decorative: hoverImage, scale: 1).resizable())
                        .position(x: imageRect.midX, y: imageRect.midY)
                        .allowsHitTesting(false)
                }
                Color.clear.contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            cursor = imageRect.contains(location) ? location : nil
                            if stroke.isEmpty, model.objectSelectionTool == "Click", imageRect.contains(location) {
                                model.previewObjectMask(at: normalized(location, in: imageRect))
                            }
                        case .ended: cursor = nil; model.previewObjectMask(at: nil)
                        }
                    }
                    .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                        guard imageRect.contains(drag.startLocation), imageRect.width > 0, imageRect.height > 0 else { return }
                        if stroke.isEmpty {
                            subtract = NSEvent.modifierFlags.contains(.option)
                            stroke = [normalized(drag.startLocation, in: imageRect)]
                        }
                        let point = normalized(drag.location, in: imageRect)
                        if model.objectSelectionTool == "Box" {
                            stroke = [stroke[0], point]
                        } else if stroke.count < 256, let previous = stroke.last,
                                  hypot(point.x - previous.x, point.y - previous.y) > 0.006 {
                            stroke.append(point)
                        }
                    }.onEnded { _ in
                        guard !stroke.isEmpty else { return }
                        model.completeObjectMaskGesture(points: stroke, box: model.objectSelectionTool == "Box", subtract: subtract)
                        stroke = []
                    })
                if model.objectSelectionTool == "Box", let first = stroke.first, let last = stroke.last, stroke.count > 1 {
                    Rectangle().stroke(.white, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .frame(width: abs(last.x - first.x) * imageRect.width, height: abs(last.y - first.y) * imageRect.height)
                        .position(x: imageRect.minX + (first.x + last.x) / 2 * imageRect.width,
                                  y: imageRect.minY + (first.y + last.y) / 2 * imageRect.height)
                        .allowsHitTesting(false)
                }
                if model.objectSelectionTool == "Paint" {
                    if let cursor {
                        Circle().stroke(.white, lineWidth: 1)
                            .frame(width: model.maskBrushSize * max(imageRect.width, imageRect.height) * 2,
                                   height: model.maskBrushSize * max(imageRect.width, imageRect.height) * 2)
                            .position(cursor).allowsHitTesting(false)
                    }
                    if !stroke.isEmpty {
                        Path { path in
                            for (i, point) in stroke.enumerated() {
                                let position = CGPoint(x: imageRect.minX + point.x * imageRect.width, y: imageRect.minY + point.y * imageRect.height)
                                if i == 0 { path.move(to: position) } else { path.addLine(to: position) }
                            }
                        }.stroke(subtract ? Color.blue.opacity(0.45) : Color.red.opacity(0.45),
                                 style: StrokeStyle(lineWidth: model.maskBrushSize * max(imageRect.width, imageRect.height) * 2, lineCap: .round, lineJoin: .round))
                         .allowsHitTesting(false)
                    }
                }
                HStack(spacing: 10) {
                    Picker("Selection tool", selection: $model.objectSelectionTool) {
                        ForEach(["Click", "Box", "Brush", "Paint", "Refine Edge"], id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 340)
                    if model.objectSelectionTool == "Paint" {
                        Slider(value: $model.maskBrushSize, in: 0.005...0.15).frame(width: 80).help("Brush size")
                    }
                    Text("⌥ Remove").font(.caption2).foregroundStyle(.secondary)
                    Button("Done") { model.cancelObjectMaskPick() }
                }
                .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, 12)
            }
            .onChange(of: model.objectHoverMask) { _, payload in
                hoverImage = payload.flatMap { makeHoverImage($0) }
            }
        }
        .onExitCommand { model.cancelObjectMaskPick() }
        .onDisappear { model.previewObjectMask(at: nil) }
    }

    private func normalized(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: min(1, max(0, (point.x - rect.minX) / max(1, rect.width))),
                y: min(1, max(0, (point.y - rect.minY) / max(1, rect.height))))
    }

    private func makeHoverImage(_ payload: RasterMaskPayload) -> CGImage? {
        let size = PixelSize(width: imageWidth, height: imageHeight).fitted(within: PixelSize(width: 320, height: 320))
        guard size.width > 0, size.height > 0 else { return nil }
        let alpha = payload.decodedAlpha()
        var pixels = [UInt8](repeating: 0, count: size.width * size.height)
        for y in 0..<size.height { for x in 0..<size.width {
            let point = CGPoint(x: (Double(x) + 0.5) / Double(size.width), y: (Double(y) + 0.5) / Double(size.height))
            guard let source = GeometryEngine.sourceNormalizedPoint(fromDisplay: point,
                    sourceWidth: payload.width, sourceHeight: payload.height, settings: model.selectedLook.geometry) else { continue }
            let sx = min(payload.width - 1, max(0, Int(source.x * Double(payload.width))))
            let sy = min(payload.height - 1, max(0, Int(source.y * Double(payload.height))))
            pixels[y * size.width + x] = alpha[sy * payload.width + sx]
        } }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: size.width, height: size.height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: size.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private func fittedImageRect(in size: CGSize) -> CGRect {
        guard imageWidth > 0, imageHeight > 0, size.width > 0, size.height > 0 else { return .zero }
        let scale = min(size.width / CGFloat(imageWidth), size.height / CGFloat(imageHeight))
        let width = CGFloat(imageWidth) * scale, height = CGFloat(imageHeight) * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }
}
