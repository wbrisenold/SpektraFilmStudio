import SwiftUI

struct MaskPanelView: View {
    @ObservedObject var model: AppModel
    @AppStorage("SpektraFilmFast.maskOverlayEnabled") private var overlayEnabled = true
    @AppStorage("SpektraFilmFast.selectedLocalGradeID") private var selectedGradeID = ""
    @AppStorage("SpektraFilmFast.selectedGradientMaskID") private var selectedGradientMaskID = ""

    private var grades: [LocalGradeRecord] { model.selectedLook.localGrades ?? [] }
    private var selectedGrade: LocalGradeRecord? {
        if let id = UUID(uuidString: selectedGradeID), let value = grades.first(where: { $0.id == id }) { return value }
        return grades.first
    }

    var body: some View {
        DisclosureGroup("LOCAL GRADES / MASKS") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Grade", selection: Binding(get: { selectedGrade?.id.uuidString ?? "" }, set: { selectedGradeID = $0 })) {
                        ForEach(grades) { grade in Text(grade.name).tag(grade.id.uuidString) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    Button { let id = model.addLocalGrade(); selectedGradeID = id.uuidString } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    if let grade = selectedGrade {
                        Button(role: .destructive) { model.removeLocalGrade(grade.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                }

                if let grade = selectedGrade {
                    Toggle("Show mask overlay", isOn: $overlayEnabled).toggleStyle(.checkbox)
                    Toggle("Grade enabled", isOn: Binding(get: { grade.enabled }, set: { model.setLocalGradeEnabled(grade.id, $0) })).toggleStyle(.checkbox)
                    HStack {
                        Text("Opacity").font(.caption2).frame(width: 54, alignment: .leading)
                        Slider(value: Binding(get: { grade.opacity }, set: { model.setLocalGradeOpacity(grade.id, $0) }), in: 0...1)
                        Text(String(format: "%.0f%%", grade.opacity * 100)).font(.caption2.monospacedDigit()).frame(width: 38)
                    }

                    Text("LOCAL ADJUSTMENTS · masked to this grade")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    localSlider("Exposure", grade: grade, key: "exposure", value: grade.tone?.exposureEV ?? 0, range: -5...5)
                    localSlider("Brightness", grade: grade, key: "brightness", value: grade.tone?.brightness ?? 0, range: -100...100)
                    localSlider("Contrast", grade: grade, key: "contrast", value: grade.tone?.contrast ?? 0, range: -100...100)
                    localSlider("Highlights", grade: grade, key: "highlights", value: grade.tone?.highlights ?? 0, range: -100...100)
                    localSlider("Shadows", grade: grade, key: "shadows", value: grade.tone?.shadows ?? 0, range: -100...100)
                    HStack(spacing: 6) {
                        Text("Density").font(.caption2).frame(width: 66, alignment: .leading)
                        Slider(value: Binding(get: { grade.colorDensity?.master ?? 0 }, set: { model.setLocalDensity(grade.id, $0) }), in: -1...1)
                        Text(String(format: "%+.2f", grade.colorDensity?.master ?? 0)).font(.caption2.monospacedDigit()).frame(width: 45)
                    }
                    Text("Global adjustments elsewhere still affect the full image. These local controls affect only this mask.")
                        .font(.caption2).foregroundStyle(.secondary)

                    HStack {
                        Text("Masks").font(.caption.weight(.semibold)); Spacer()
                        Menu {
                            Button("Radial") { model.addMaskSource(gradeID: grade.id, kind: .radial) }
                            Button("Linear Gradient") { model.addMaskSource(gradeID: grade.id, kind: .linearGradient) }
                            Button("Raster / Paint") { model.addMaskSource(gradeID: grade.id, kind: .raster) }
                        } label: { Image(systemName: "plus.circle") }
                        .menuStyle(.borderlessButton)
                    }

                    ForEach(grade.masks.sources) { source in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Toggle("", isOn: Binding(get: { source.enabled }, set: { model.setMaskEnabled(gradeID: grade.id, maskID: source.id, $0) })).labelsHidden().toggleStyle(.checkbox)
                                Text(source.name).font(.caption)
                                Spacer()
                                Button(role: .destructive) { model.removeMaskSource(gradeID: grade.id, maskID: source.id) } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                            }
                            HStack {
                                Picker("Mode", selection: Binding(get: { source.blendMode }, set: { model.setMaskBlendMode(gradeID: grade.id, maskID: source.id, $0) })) {
                                    ForEach(MaskBlendMode.allCases) { Text($0.rawValue).tag($0) }
                                }.labelsHidden().frame(width: 92)
                                Toggle("Invert", isOn: Binding(get: { source.inverted }, set: { model.setMaskInverted(gradeID: grade.id, maskID: source.id, $0) })).toggleStyle(.checkbox)
                            }
                            if source.kind == .linearGradient {
                                let gradient = source.linearGradient ?? LinearGradientMaskGeometry()
                                HStack(spacing: 6) {
                                    Button {
                                        selectedGradeID = grade.id.uuidString
                                        selectedGradientMaskID = source.id.uuidString
                                        model.isGradientMaskEditing = true
                                    } label: {
                                        Label("Edit Gradient on Image", systemImage: "arrow.up.left.and.arrow.down.right")
                                    }
                                    .controlSize(.small)
                                    Spacer()
                                    if model.isGradientMaskEditing && selectedGradientMaskID == source.id.uuidString {
                                        Button("Done") { model.isGradientMaskEditing = false }
                                            .controlSize(.small)
                                    }
                                }
                                gradientSlider("Start X", grade: grade, source: source, axis: "startX", value: gradient.start.x)
                                gradientSlider("Start Y", grade: grade, source: source, axis: "startY", value: gradient.start.y)
                                gradientSlider("End X", grade: grade, source: source, axis: "endX", value: gradient.end.x)
                                gradientSlider("End Y", grade: grade, source: source, axis: "endY", value: gradient.end.y)
                                HStack(spacing: 6) {
                                    Button("Horizontal") {
                                        model.setGradientEndpoints(gradeID: grade.id, maskID: source.id,
                                            start: NormalizedPoint(x: 0.2, y: 0.5), end: NormalizedPoint(x: 0.8, y: 0.5))
                                    }
                                    Button("Vertical") {
                                        model.setGradientEndpoints(gradeID: grade.id, maskID: source.id,
                                            start: NormalizedPoint(x: 0.5, y: 0.2), end: NormalizedPoint(x: 0.5, y: 0.8))
                                    }
                                    Button("Diagonal") {
                                        model.setGradientEndpoints(gradeID: grade.id, maskID: source.id,
                                            start: NormalizedPoint(x: 0.2, y: 0.2), end: NormalizedPoint(x: 0.8, y: 0.8))
                                    }
                                }
                                .buttonStyle(.borderless).controlSize(.small)
                                Text("Feather below sets transition softness. Drag either endpoint directly on the photo to position and rotate the gradient.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            HStack {
                                Text("Feather").font(.caption2).frame(width: 48, alignment: .leading)
                                Slider(value: Binding(get: { source.feather }, set: { model.setMaskFeather(gradeID: grade.id, maskID: source.id, $0) }), in: 0...1)
                            }
                            HStack {
                                Text("Opacity").font(.caption2).frame(width: 48, alignment: .leading)
                                Slider(value: Binding(get: { source.opacity }, set: { model.setMaskOpacity(gradeID: grade.id, maskID: source.id, $0) }), in: 0...1)
                            }
                        }
                        .padding(7)
                        .background(StudioPalette.recessed, in: RoundedRectangle(cornerRadius: 6))
                    }
                } else {
                    Text("Add a local grade to start masking.").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func gradientSlider(_ label: String, grade: LocalGradeRecord, source: MaskSourceRecord, axis: String, value: Double) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2).frame(width: 48, alignment: .leading)
            Slider(value: Binding(
                get: { value },
                set: { model.setGradientCoordinate(gradeID: grade.id, maskID: source.id, axis: axis, value: $0) }
            ), in: 0...1)
            Text(value, format: .number.precision(.fractionLength(2)))
                .font(.caption2.monospacedDigit()).frame(width: 42)
        }
    }

    private func localSlider(_ label: String, grade: LocalGradeRecord, key: String, value: Double, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2).frame(width: 66, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { model.setLocalTone(grade.id, key, $0) }), in: range)
            Text(String(format: "%+.1f", value)).font(.caption2.monospacedDigit()).frame(width: 45)
        }
    }
}

struct MaskOverlayView: View {
    @ObservedObject var model: AppModel
    @AppStorage("SpektraFilmFast.maskOverlayEnabled") private var overlayEnabled = true
    @AppStorage("SpektraFilmFast.selectedLocalGradeID") private var selectedGradeID = ""
    @AppStorage("SpektraFilmFast.selectedGradientMaskID") private var selectedGradientMaskID = ""

    var body: some View {
        if overlayEnabled, let grade = selectedGrade, !grade.masks.sources.isEmpty {
            GeometryReader { proxy in
                let image = model.frameState.renderedPreview
                let imageRect = gradientImageRect(in: proxy.size, imageWidth: image?.width ?? 1, imageHeight: image?.height ?? 1)
                ZStack {
            Canvas { context, size in
                context.opacity = 0.34
                for source in grade.masks.sources where source.enabled {
                    let shade = source.blendMode == .subtract ? Color.red : (source.blendMode == .intersect ? Color.yellow : Color.cyan)
                    switch source.kind {
                    case .radial:
                        let g = source.radial ?? RadialMaskGeometry()
                        let rect = CGRect(x: (g.center.x - g.radiusX) * size.width, y: (g.center.y - g.radiusY) * size.height, width: g.radiusX * 2 * size.width, height: g.radiusY * 2 * size.height)
                        context.fill(Path(ellipseIn: rect), with: .color(shade.opacity(source.opacity)))
                    case .linearGradient:
                        let g = source.linearGradient ?? LinearGradientMaskGeometry()
                        let start = CGPoint(x: g.start.x * size.width, y: g.start.y * size.height)
                        let end = CGPoint(x: g.end.x * size.width, y: g.end.y * size.height)
                        context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(Gradient(colors: [.clear, shade.opacity(source.opacity)]), startPoint: start, endPoint: end))
                    case .raster:
                        // Raster paint storage is implemented in Stage 2. The geometry overlay intentionally
                        // avoids decoding a full painted bitmap on every SwiftUI frame; the Metal path consumes it.
                        break
                    }
                }
            }
            .allowsHitTesting(false)

            if model.isGradientMaskEditing,
               let maskID = UUID(uuidString: selectedGradientMaskID),
               let source = grade.masks.sources.first(where: { $0.id == maskID && $0.kind == .linearGradient && $0.enabled }),
               let gradient = source.linearGradient,
               imageRect.width > 0, imageRect.height > 0 {
                gradientHandles(grade: grade, source: source, geometry: gradient, rect: imageRect)
            }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }

    private func gradientImageRect(in available: CGSize, imageWidth: Int, imageHeight: Int) -> CGRect {
        guard available.width > 0, available.height > 0, imageWidth > 0, imageHeight > 0 else { return .zero }
        let factor = min(available.width / CGFloat(imageWidth), available.height / CGFloat(imageHeight))
        let width = CGFloat(imageWidth) * factor
        let height = CGFloat(imageHeight) * factor
        return CGRect(x: (available.width - width) / 2, y: (available.height - height) / 2, width: width, height: height)
    }

    private func gradientHandles(grade: LocalGradeRecord, source: MaskSourceRecord, geometry: LinearGradientMaskGeometry, rect: CGRect) -> some View {
        let start = CGPoint(x: rect.minX + rect.width * CGFloat(geometry.start.x), y: rect.minY + rect.height * CGFloat(geometry.start.y))
        let end = CGPoint(x: rect.minX + rect.width * CGFloat(geometry.end.x), y: rect.minY + rect.height * CGFloat(geometry.end.y))
        return ZStack {
            Path { path in path.move(to: start); path.addLine(to: end) }
                .stroke(.white.opacity(0.92), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .allowsHitTesting(false)
            gradientHandle(point: start, isStart: true, gradeID: grade.id, maskID: source.id, geometry: geometry, rect: rect)
            gradientHandle(point: end, isStart: false, gradeID: grade.id, maskID: source.id, geometry: geometry, rect: rect)
        }
    }

    private func gradientHandle(point: CGPoint, isStart: Bool, gradeID: UUID, maskID: UUID, geometry: LinearGradientMaskGeometry, rect: CGRect) -> some View {
        Circle()
            .fill(isStart ? Color.cyan : Color.white)
            .overlay(Circle().stroke(Color.black.opacity(0.85), lineWidth: 2))
            .frame(width: 18, height: 18)
            .contentShape(Circle())
            .position(point)
            .gesture(DragGesture(minimumDistance: 0).onEnded { gesture in
                guard rect.width > 0, rect.height > 0 else { return }
                let x = max(0, min(1, Double((point.x + gesture.translation.width - rect.minX) / rect.width)))
                let y = max(0, min(1, Double((point.y + gesture.translation.height - rect.minY) / rect.height)))
                let location = NormalizedPoint(x: x, y: y)
                model.setGradientEndpoints(gradeID: gradeID, maskID: maskID,
                    start: isStart ? location : geometry.start,
                    end: isStart ? geometry.end : location)
            })
            .help(isStart ? "Drag the gradient start" : "Drag the gradient end")
    }

    private var selectedGrade: LocalGradeRecord? {
        let grades = model.selectedLook.localGrades ?? []
        if let id = UUID(uuidString: selectedGradeID), let grade = grades.first(where: { $0.id == id }) { return grade }
        return grades.first
    }
}
