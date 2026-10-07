import SwiftUI
import CoreGraphics

struct MaskPanelView: View {
    @ObservedObject var model: AppModel
    @AppStorage("SpektraFilmFast.maskOverlayEnabled") private var overlayEnabled = true
    @AppStorage("SpektraFilmFast.selectedLocalGradeID") private var selectedGradeID = ""
    @AppStorage("SpektraFilmFast.selectedGradientMaskID") private var selectedGradientMaskID = ""

    private var grades: [LocalGradeRecord] { model.selectedLook.localGrades ?? [] }
    private var selectedGrade: LocalGradeRecord? {
        if let id = UUID(uuidString: selectedGradeID), let grade = grades.first(where: { $0.id == id }) { return grade }
        return grades.first
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                gradeHeader
                if let grade = selectedGrade {
                    selectArea(grade)
                    Divider().opacity(0.45)
                    refineMasks(grade)
                    Divider().opacity(0.45)
                    localAdjustments(grade)
                } else {
                    VStack(spacing: 8) {
                        Text("Create a local adjustment first.").font(.caption)
                        Button("New Local Adjustment") { createGrade() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }.frame(maxWidth: .infinity).padding(.vertical, 14)
                }
            }.padding(.top, 8)
        } label: {
            HStack {
                Label("Masks & Local Adjustments", systemImage: "circle.lefthalf.filled")
                    .font(.caption.weight(.semibold))
                Spacer()
                if selectedGrade != nil {
                    Button { overlayEnabled.toggle() } label: {
                        Image(systemName: overlayEnabled ? "eye.fill" : "eye.slash")
                    }.buttonStyle(.plain)
                }
            }
        }
        .onAppear { normalizeSelection() }
        .onChange(of: grades.map(\.id)) { _, _ in normalizeSelection() }
    }

    private var gradeHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Picker("Local adjustment", selection: Binding(
                    get: { selectedGrade?.id.uuidString ?? "" },
                    set: { selectedGradeID = $0; overlayEnabled = true }
                )) {
                    ForEach(grades) { Text($0.name).tag($0.id.uuidString) }
                }.labelsHidden().frame(maxWidth: .infinity)
                Button { createGrade() } label: { Image(systemName: "plus") }
                    .buttonStyle(.bordered).controlSize(.small)
                if let grade = selectedGrade {
                    Button(role: .destructive) { model.removeLocalGrade(grade.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            if let grade = selectedGrade {
                HStack {
                    Toggle("Enabled", isOn: Binding(get: { grade.enabled }, set: { model.setLocalGradeEnabled(grade.id, $0) }))
                        .toggleStyle(.checkbox)
                    Toggle("Show Overlay", isOn: $overlayEnabled).toggleStyle(.checkbox)
                    Spacer()
                    Text(overlayEnabled ? "CYAN = SELECTED" : "OVERLAY OFF")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(overlayEnabled ? .cyan : .secondary)
                }
            }
        }
    }

    private func selectArea(_ grade: LocalGradeRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("1 · SELECT AREA").font(.caption2.weight(.bold))
                Spacer()
                Button { model.refreshCanonicalSemanticMasks(); overlayEnabled = true } label: {
                    Label("Analyze AI", systemImage: "sparkles")
                }.buttonStyle(.bordered).controlSize(.small)
            }
            Text(model.semanticMaskStatus).font(.caption2).foregroundStyle(.secondary).lineLimit(2)

            let primary: [SemanticMaskKind] = [.subject, .skin, .person, .background, .hair]
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: 5)], spacing: 5) {
                ForEach(primary) { kind in
                    Button { overlayEnabled = true; model.addSemanticMask(kind, to: grade.id) } label: {
                        Text(kind.rawValue).frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered).controlSize(.small)
                     .disabled(model.semanticMasks?.alpha(kind) == nil)
                }
            }

            DisclosureGroup("More AI selections") {
                let secondary: [SemanticMaskKind] = [.eyes, .lips, .body, .upperClothes, .lowerClothes, .arms, .legs, .shoes]
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 5)], spacing: 5) {
                    ForEach(secondary) { kind in
                        Button { overlayEnabled = true; model.addSemanticMask(kind, to: grade.id) } label: {
                            Text(kind.rawValue).frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered).controlSize(.small)
                         .disabled(model.semanticMasks?.alpha(kind) == nil)
                    }
                }.padding(.top, 5)
            }.font(.caption2)

            HStack(spacing: 6) {
                Button { overlayEnabled = true; model.beginObjectMaskPick(gradeID: grade.id, blendMode: .add) } label: {
                    Label("Pick Object", systemImage: "scope")
                }
                Button { overlayEnabled = true; model.beginObjectMaskPick(gradeID: grade.id, blendMode: .subtract) } label: {
                    Label("Subtract", systemImage: "minus.circle")
                }
                Menu {
                    Button("Radial Mask") { overlayEnabled = true; model.addMaskSource(gradeID: grade.id, kind: .radial) }
                    Button("Linear Gradient") { overlayEnabled = true; model.addMaskSource(gradeID: grade.id, kind: .linearGradient) }
                    Button("Raster / Paint") { overlayEnabled = true; model.addMaskSource(gradeID: grade.id, kind: .raster) }
                } label: { Label("Manual", systemImage: "plus.circle") }
            }.buttonStyle(.bordered).controlSize(.small)

            if model.isObjectMaskPicking {
                HStack {
                    ProgressView().controlSize(.mini)
                    Text("Click the object directly on the photo.").font(.caption2)
                    Spacer()
                    Button("Cancel") { model.cancelObjectMaskPick() }.buttonStyle(.borderless)
                }
            }
        }
    }

    private func refineMasks(_ grade: LocalGradeRecord) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("2 · REFINE MASK").font(.caption2.weight(.bold))
                Spacer()
                Text("\(grade.masks.sources.count) mask\(grade.masks.sources.count == 1 ? "" : "s")")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            if grade.masks.sources.isEmpty {
                Text("Add an AI, object, gradient or radial selection above. With no mask, the local adjustment affects the whole image.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(grade.masks.sources) { source in maskCard(grade: grade, source: source) }
        }
    }

    private func maskCard(grade: LocalGradeRecord, source: MaskSourceRecord) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: source.kind == .radial ? "circle" : (source.kind == .linearGradient ? "square.split.diagonal.2x2" : "wand.and.stars"))
                    .foregroundStyle(source.enabled ? .cyan : .secondary)
                Toggle("", isOn: Binding(get: { source.enabled }, set: { model.setMaskEnabled(gradeID: grade.id, maskID: source.id, $0) }))
                    .labelsHidden().toggleStyle(.checkbox)
                Text(source.name).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer()
                Button(role: .destructive) { model.removeMaskSource(gradeID: grade.id, maskID: source.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain)
            }
            Picker("Combine", selection: Binding(get: { source.blendMode }, set: { model.setMaskBlendMode(gradeID: grade.id, maskID: source.id, $0) })) {
                ForEach(MaskBlendMode.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).controlSize(.small)
            HStack {
                Toggle("Invert", isOn: Binding(get: { source.inverted }, set: { model.setMaskInverted(gradeID: grade.id, maskID: source.id, $0) }))
                    .toggleStyle(.checkbox)
                Spacer()
                if source.kind == .linearGradient {
                    Button { selectedGradientMaskID = source.id.uuidString; model.isGradientMaskEditing = true; overlayEnabled = true } label: {
                        Label("Edit on Photo", systemImage: "arrow.up.left.and.arrow.down.right")
                    }.buttonStyle(.borderless).controlSize(.small)
                }
            }
            sliderRow("Feather", value: Binding(get: { source.feather }, set: { model.setMaskFeather(gradeID: grade.id, maskID: source.id, $0) }))
            sliderRow("Mask Opacity", value: Binding(get: { source.opacity }, set: { model.setMaskOpacity(gradeID: grade.id, maskID: source.id, $0) }))
        }
        .padding(8)
        .background(StudioPalette.recessed.opacity(0.9), in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).stroke(source.enabled ? Color.cyan.opacity(0.22) : StudioPalette.subtleBorder, lineWidth: 0.7) }
    }

    private func localAdjustments(_ grade: LocalGradeRecord) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("3 · ADJUST SELECTED AREA").font(.caption2.weight(.bold))
            HStack {
                Text("Adjustment Opacity").font(.caption2)
                Slider(value: Binding(get: { grade.opacity }, set: { model.setLocalGradeOpacity(grade.id, $0) }), in: 0...1)
                Text(String(format: "%.0f%%", grade.opacity * 100)).font(.caption2.monospacedDigit()).frame(width: 36)
            }
            localSlider("Exposure", grade: grade, key: "exposure", value: grade.tone?.exposureEV ?? 0, range: -5...5)
            localSlider("Brightness", grade: grade, key: "brightness", value: grade.tone?.brightness ?? 0, range: -100...100)
            localSlider("Contrast", grade: grade, key: "contrast", value: grade.tone?.contrast ?? 0, range: -100...100)
            localSlider("Highlights", grade: grade, key: "highlights", value: grade.tone?.highlights ?? 0, range: -100...100)
            localSlider("Shadows", grade: grade, key: "shadows", value: grade.tone?.shadows ?? 0, range: -100...100)
        }
    }

    private func localSlider(_ label: String, grade: LocalGradeRecord, key: String, value: Double, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2).frame(width: 66, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { model.setLocalTone(grade.id, key, $0) }), in: range)
            Text(String(format: "%+.1f", value)).font(.caption2.monospacedDigit()).frame(width: 45)
        }
    }

    private func sliderRow(_ label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2).frame(width: 76, alignment: .leading)
            Slider(value: value, in: 0...1)
            Text(String(format: "%.0f%%", value.wrappedValue * 100)).font(.caption2.monospacedDigit()).frame(width: 38)
        }
    }

    private func createGrade() {
        let id = model.addLocalGrade(); selectedGradeID = id.uuidString; overlayEnabled = true
    }
    private func normalizeSelection() {
        if let id = UUID(uuidString: selectedGradeID), grades.contains(where: { $0.id == id }) { return }
        selectedGradeID = grades.first?.id.uuidString ?? ""
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
                let rect = fittedImageRect(in: proxy.size, imageWidth: image?.width ?? 1, imageHeight: image?.height ?? 1)
                ZStack {
                    MaskCoverageOverlay(grade: grade, imageWidth: image?.width ?? 1, imageHeight: image?.height ?? 1)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                    if model.isGradientMaskEditing,
                       let maskID = UUID(uuidString: selectedGradientMaskID),
                       let source = grade.masks.sources.first(where: { $0.id == maskID && $0.kind == .linearGradient && $0.enabled }),
                       let gradient = source.linearGradient {
                        gradientHandles(grade: grade, source: source, geometry: gradient, rect: rect)
                    }
                }.frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }

    private func fittedImageRect(in available: CGSize, imageWidth: Int, imageHeight: Int) -> CGRect {
        guard available.width > 0, available.height > 0, imageWidth > 0, imageHeight > 0 else { return .zero }
        let f = min(available.width / CGFloat(imageWidth), available.height / CGFloat(imageHeight))
        let w = CGFloat(imageWidth) * f, h = CGFloat(imageHeight) * f
        return CGRect(x: (available.width-w)/2, y: (available.height-h)/2, width: w, height: h)
    }

    private func gradientHandles(grade: LocalGradeRecord, source: MaskSourceRecord, geometry: LinearGradientMaskGeometry, rect: CGRect) -> some View {
        let start = CGPoint(x: rect.minX + rect.width * CGFloat(geometry.start.x), y: rect.minY + rect.height * CGFloat(geometry.start.y))
        let end = CGPoint(x: rect.minX + rect.width * CGFloat(geometry.end.x), y: rect.minY + rect.height * CGFloat(geometry.end.y))
        return ZStack {
            Path { $0.move(to: start); $0.addLine(to: end) }
                .stroke(.white.opacity(0.95), style: StrokeStyle(lineWidth: 1.5, dash: [5,4]))
                .allowsHitTesting(false)
            handle(start, true, grade.id, source.id, geometry, rect)
            handle(end, false, grade.id, source.id, geometry, rect)
        }
    }

    private func handle(_ point: CGPoint, _ isStart: Bool, _ gradeID: UUID, _ maskID: UUID, _ geometry: LinearGradientMaskGeometry, _ rect: CGRect) -> some View {
        Circle().fill(isStart ? Color.cyan : Color.white)
            .overlay(Circle().stroke(Color.black.opacity(0.85), lineWidth: 2))
            .frame(width: 18, height: 18).position(point)
            .gesture(DragGesture(minimumDistance: 0).onEnded { gesture in
                guard rect.width > 0, rect.height > 0 else { return }
                let x = max(0, min(1, Double((point.x + gesture.translation.width - rect.minX) / rect.width)))
                let y = max(0, min(1, Double((point.y + gesture.translation.height - rect.minY) / rect.height)))
                let p = NormalizedPoint(x: x, y: y)
                model.setGradientEndpoints(gradeID: gradeID, maskID: maskID, start: isStart ? p : geometry.start, end: isStart ? geometry.end : p)
            })
    }

    private var selectedGrade: LocalGradeRecord? {
        let grades = model.selectedLook.localGrades ?? []
        if let id = UUID(uuidString: selectedGradeID), let grade = grades.first(where: { $0.id == id }) { return grade }
        return grades.first
    }
}

private struct MaskOverlayKey: Hashable { let grade: LocalGradeRecord; let width: Int; let height: Int }
private struct MaskCoveragePayload: Sendable { let width: Int; let height: Int; let rgba: [UInt8] }

private struct MaskCoverageOverlay: View {
    let grade: LocalGradeRecord
    let imageWidth: Int
    let imageHeight: Int
    @State private var overlayImage: CGImage?

    var body: some View {
        Group {
            if let overlayImage {
                Image(decorative: overlayImage, scale: 1).resizable().interpolation(.high)
                    .aspectRatio(CGFloat(max(1,imageWidth)) / CGFloat(max(1,imageHeight)), contentMode: .fit)
            }
        }
        .task(id: MaskOverlayKey(grade: grade, width: imageWidth, height: imageHeight)) {
            let g = grade
            let sw = max(1,imageWidth), sh = max(1,imageHeight)
            let scale = min(1.0, 960.0 / Double(max(sw,sh)))
            let w = max(1,Int((Double(sw)*scale).rounded())), h = max(1,Int((Double(sh)*scale).rounded()))
            let payload = await Task.detached(priority: .utility) { () -> MaskCoveragePayload in
                let coverage = MaskedLocalGradeEngine.coverageForGrade(g, width: w, height: h)
                let alpha = coverage.prefix(w*h).map { value in
                    UInt8(clamping: Int((max(0, min(1, value)) * 255.0).rounded()))
                }
                let canonical = CanonicalMaskBuffer(width: w, height: h, coverage: alpha)
                return MaskCoveragePayload(width:w,height:h,rgba:canonical.overlayRGBA(maximumAlpha:218))
            }.value
            guard !Task.isCancelled else { return }
            overlayImage = CGImage.fromRGBA8(width: payload.width, height: payload.height, bytes: payload.rgba)
        }
    }
}
