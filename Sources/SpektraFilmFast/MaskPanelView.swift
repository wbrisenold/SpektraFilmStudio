import SwiftUI
import CoreGraphics


struct MaskPanelView: View {
    @ObservedObject var model: AppModel
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
                        Button("Subject") { makeSemantic(.subject) }
                        Button("Skin") { makeSemantic(.skin) }
                        Button("Person") { makeSemantic(.person) }
                        Button("Hair") { makeSemantic(.hair) }
                        Button("Background") { makeSemantic(.background) }
                    }
                    Section("Draw on Image") {
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

                Button {
                    model.refreshCanonicalSemanticMasks()
                } label: { Label("Analyze", systemImage: "sparkles") }
                .controlSize(.small)
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
                        Button("Subject") { addSemantic(.subject, gradeID: grade.id, blend: .add) }
                        Button("Skin") { addSemantic(.skin, gradeID: grade.id, blend: .add) }
                        Button("Background") { addSemantic(.background, gradeID: grade.id, blend: .add) }
                        Button("Linear Gradient") { model.addMaskSource(gradeID: grade.id, kind: .linearGradient) }
                        Button("Radial Gradient") { model.addMaskSource(gradeID: grade.id, kind: .radial) }
                    }.controlSize(.small)
                    Menu("Subtract") {
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
                        Button(role: .destructive) {
                            model.removeMaskSource(gradeID: grade.id, maskID: source.id)
                        } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                    }
                }

                Divider()
                Text("LOCAL ADJUSTMENTS").font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Changes below affect only the selected red area. Switching to Adjust edits the complete photo automatically.")
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
        .onAppear {
            if model.activeLocalGradeID == nil {
                if let existing = grades.first { model.selectLocalGrade(existing.id) }
            }
            if selectedGrade != nil { overlayEnabled = true }
            if model.semanticMasks == nil && model.selectedImage != nil { model.refreshCanonicalSemanticMasks() }
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
        model.requestSemanticMask(kind, gradeID: gradeID, blend: blend)
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

    var body: some View {
        GeometryReader { proxy in
            let imageRect = fittedImageRect(in: proxy.size)
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture().onEnded { value in
                            guard imageRect.contains(value.location), imageRect.width > 0, imageRect.height > 0 else { return }
                            let point = CGPoint(
                                x: (value.location.x - imageRect.minX) / imageRect.width,
                                y: (value.location.y - imageRect.minY) / imageRect.height
                            )
                            model.completeObjectMaskPick(normalizedPoint: point)
                        }
                    )

                Text("Click the foreground object · Esc/cancel from AI Masks")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(.regularMaterial, in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 12)
                    .allowsHitTesting(false)
            }
        }
    }

    private func fittedImageRect(in size: CGSize) -> CGRect {
        guard imageWidth > 0, imageHeight > 0, size.width > 0, size.height > 0 else { return .zero }
        let scale = min(size.width / CGFloat(imageWidth), size.height / CGFloat(imageHeight))
        let width = CGFloat(imageWidth) * scale
        let height = CGFloat(imageHeight) * scale
        return CGRect(x: (size.width - width) * 0.5, y: (size.height - height) * 0.5, width: width, height: height)
    }
}
