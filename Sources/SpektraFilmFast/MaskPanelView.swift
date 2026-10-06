import SwiftUI

struct MaskPanelView: View {
    @ObservedObject var model: AppModel
    @AppStorage("SpektraFilmFast.maskOverlayEnabled") private var overlayEnabled = true
    @AppStorage("SpektraFilmFast.selectedLocalGradeID") private var selectedGradeID = ""

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
}

struct MaskOverlayView: View {
    @ObservedObject var model: AppModel
    @AppStorage("SpektraFilmFast.maskOverlayEnabled") private var overlayEnabled = true
    @AppStorage("SpektraFilmFast.selectedLocalGradeID") private var selectedGradeID = ""

    var body: some View {
        if overlayEnabled, let grade = selectedGrade, !grade.masks.sources.isEmpty {
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
        }
    }

    private var selectedGrade: LocalGradeRecord? {
        let grades = model.selectedLook.localGrades ?? []
        if let id = UUID(uuidString: selectedGradeID), let grade = grades.first(where: { $0.id == id }) { return grade }
        return grades.first
    }
}
