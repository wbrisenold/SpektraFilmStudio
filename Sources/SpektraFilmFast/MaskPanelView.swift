import SwiftUI
import CoreGraphics

struct MaskPanelView: View {
    @ObservedObject var model: AppModel
    @AppStorage("SpektraFilmFast.maskOverlayEnabled") private var overlayEnabled = true

    private var grades: [LocalGradeRecord] { model.selectedLook.localGrades ?? [] }
    private var selectedGrade: LocalGradeRecord? {
        guard let id = model.activeLocalGradeID else { return nil }
        return grades.first(where: { $0.id == id })
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button {
                        model.selectLocalGrade(nil)
                    } label: {
                        Label("Main Image", systemImage: "photo")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer()
                    if selectedGrade != nil {
                        Toggle("Overlay", isOn: $overlayEnabled).toggleStyle(.checkbox)
                    }
                }

                Divider().opacity(0.45)

                HStack {
                    Text("CREATE MASK").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        model.refreshCanonicalSemanticMasks()
                    } label: {
                        Label("Analyze AI", systemImage: "sparkles")
                    }.controlSize(.small)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 6)], spacing: 6) {
                    semanticTile("Subject", "person.crop.rectangle", .subject)
                    semanticTile("Skin", "person.crop.circle", .skin)
                    semanticTile("Person", "figure.stand", .person)
                    semanticTile("Background", "photo.on.rectangle", .background)
                    semanticTile("Hair", "person.crop.circle.badge.checkmark", .hair)
                    Button {
                        let id = model.addLocalGrade()
                        model.selectLocalGrade(id)
                        overlayEnabled = true
                        model.beginObjectMaskPick(gradeID: id, blendMode: .add)
                    } label: { tile("Object", "scope") }.buttonStyle(.plain)
                    Button {
                        let id = model.addLocalGrade()
                        model.selectLocalGrade(id)
                        overlayEnabled = true
                        model.addMaskSource(gradeID: id, kind: .linearGradient)
                    } label: { tile("Linear", "square.split.diagonal.2x2") }.buttonStyle(.plain)
                    Button {
                        let id = model.addLocalGrade()
                        model.selectLocalGrade(id)
                        overlayEnabled = true
                        model.addMaskSource(gradeID: id, kind: .radial)
                    } label: { tile("Radial", "circle") }.buttonStyle(.plain)
                }

                Text(model.semanticMaskStatus)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)

                if !grades.isEmpty {
                    Divider().opacity(0.45)
                    Text("MASKS").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    ForEach(grades) { grade in
                        HStack(spacing: 7) {
                            Button {
                                model.selectLocalGrade(grade.id)
                                overlayEnabled = true
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: model.activeLocalGradeID == grade.id ? "circle.inset.filled" : "circle")
                                        .foregroundStyle(model.activeLocalGradeID == grade.id ? .cyan : .secondary)
                                    Text(grade.name).lineLimit(1)
                                    Spacer()
                                    Text("\(grade.masks.sources.count)")
                                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.plain)
                            Button(role: .destructive) {
                                model.removeLocalGrade(grade.id)
                            } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 7).frame(height: 30)
                        .background(model.activeLocalGradeID == grade.id ? StudioPalette.selected : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                    }
                }

                if let grade = selectedGrade {
                    Divider().opacity(0.45)
                    componentControls(grade)
                    Divider().opacity(0.45)
                    Text("RAW Develop is targeting this mask until you choose Main Image.")
                        .font(.caption2).foregroundStyle(.secondary)
                    HStack {
                        Text("Amount").font(.caption2)
                        Slider(value: Binding(
                            get: { grade.opacity },
                            set: { model.setLocalGradeOpacity(grade.id, $0) }
                        ), in: 0...1)
                        Text("\(Int((grade.opacity * 100).rounded()))%")
                            .font(.caption2.monospacedDigit()).frame(width: 38)
                    }
                }
            }.padding(.top, 8)
        } label: {
            HStack {
                Label("Masking", systemImage: "circle.lefthalf.filled")
                    .font(.caption.weight(.semibold))
                Spacer()
                if selectedGrade != nil {
                    Text("LOCAL").font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.cyan)
                }
            }
        }
    }

    @ViewBuilder
    private func semanticTile(_ label: String, _ icon: String, _ kind: SemanticMaskKind) -> some View {
        Button {
            let id = model.addLocalGrade()
            model.selectLocalGrade(id)
            overlayEnabled = true
            model.addSemanticMask(kind, to: id)
        } label: { tile(label, icon) }
        .buttonStyle(.plain)
        .disabled(model.semanticMasks?.alpha(kind) == nil)
    }

    private func tile(_ label: String, _ icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 15, weight: .medium))
            Text(label).font(.system(size: 9, weight: .medium)).lineLimit(1)
        }
        .frame(maxWidth: .infinity).frame(height: 48)
        .background(StudioPalette.recessed, in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).stroke(StudioPalette.subtleBorder, lineWidth: 0.5) }
    }

    private func componentControls(_ grade: LocalGradeRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("COMPONENTS").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                Spacer()
                Menu("Add") {
                    Button("Subject") { model.addSemanticMask(.subject, to: grade.id, blendMode: .add) }
                    Button("Skin") { model.addSemanticMask(.skin, to: grade.id, blendMode: .add) }
                    Button("Background") { model.addSemanticMask(.background, to: grade.id, blendMode: .add) }
                    Divider()
                    Button("Linear Gradient") { model.addMaskSource(gradeID: grade.id, kind: .linearGradient) }
                    Button("Radial Gradient") { model.addMaskSource(gradeID: grade.id, kind: .radial) }
                }.controlSize(.small)
                Menu("Subtract") {
                    Button("Subject") { model.addSemanticMask(.subject, to: grade.id, blendMode: .subtract) }
                    Button("Skin") { model.addSemanticMask(.skin, to: grade.id, blendMode: .subtract) }
                    Button("Background") { model.addSemanticMask(.background, to: grade.id, blendMode: .subtract) }
                    Button("Pick Object") { model.beginObjectMaskPick(gradeID: grade.id, blendMode: .subtract) }
                }.controlSize(.small)
            }

            ForEach(grade.masks.sources) { source in
                HStack(spacing: 6) {
                    Toggle("", isOn: Binding(
                        get: { source.enabled },
                        set: { model.setMaskEnabled(gradeID: grade.id, maskID: source.id, $0) }
                    )).labelsHidden().toggleStyle(.checkbox)
                    Text(source.name).font(.caption).lineLimit(1)
                    Spacer()
                    Text(source.blendMode.rawValue).font(.caption2).foregroundStyle(.secondary)
                    if source.kind == .linearGradient {
                        Button {
                            model.selectedGradientMaskID = source.id
                            model.isGradientMaskEditing = true
                            overlayEnabled = true
                        } label: { Image(systemName: "move.3d") }.buttonStyle(.borderless)
                    }
                    Button(role: .destructive) {
                        model.removeMaskSource(gradeID: grade.id, maskID: source.id)
                    } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                .padding(.horizontal, 6).frame(height: 27)
            }
        }
    }
}

struct MaskOverlayView: View {
    @ObservedObject var model: AppModel
    @AppStorage("SpektraFilmFast.maskOverlayEnabled") private var overlayEnabled = true

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
                       let maskID = model.selectedGradientMaskID,
                       let source = grade.masks.sources.first(where: { $0.id == maskID && $0.kind == .linearGradient && $0.enabled }),
                       let gradient = source.linearGradient {
                        gradientHandles(grade: grade, source: source, geometry: gradient, rect: rect)
                    }
                }
            }
        }
    }

    private var selectedGrade: LocalGradeRecord? {
        guard let id = model.activeLocalGradeID else { return nil }
        return (model.selectedLook.localGrades ?? []).first(where: { $0.id == id })
    }

    private func fittedImageRect(in size: CGSize, imageWidth: Int, imageHeight: Int) -> CGRect {
        let f = min(size.width / CGFloat(max(1,imageWidth)), size.height / CGFloat(max(1,imageHeight)))
        let w = CGFloat(imageWidth) * f, h = CGFloat(imageHeight) * f
        return CGRect(x: (size.width-w)/2, y: (size.height-h)/2, width:w, height:h)
    }

    private func gradientHandles(grade: LocalGradeRecord, source: MaskSourceRecord, geometry: LinearGradientMaskGeometry, rect: CGRect) -> some View {
        let start = CGPoint(x:rect.minX+rect.width*CGFloat(geometry.start.x), y:rect.minY+rect.height*CGFloat(geometry.start.y))
        let end = CGPoint(x:rect.minX+rect.width*CGFloat(geometry.end.x), y:rect.minY+rect.height*CGFloat(geometry.end.y))
        return ZStack {
            Path { $0.move(to:start); $0.addLine(to:end) }
                .stroke(.white.opacity(0.95), style:StrokeStyle(lineWidth:1.5,dash:[5,4]))
            handle(start,true,grade.id,source.id,geometry,rect)
            handle(end,false,grade.id,source.id,geometry,rect)
        }
    }

    private func handle(_ point:CGPoint,_ start:Bool,_ gradeID:UUID,_ maskID:UUID,_ g:LinearGradientMaskGeometry,_ rect:CGRect)->some View {
        Circle().fill(start ? Color.cyan : Color.white)
            .overlay(Circle().stroke(.black.opacity(0.85),lineWidth:2))
            .frame(width:18,height:18).position(point)
            .gesture(DragGesture(minimumDistance:0).onEnded { drag in
                let x=max(0,min(1,Double((point.x+drag.translation.width-rect.minX)/rect.width)))
                let y=max(0,min(1,Double((point.y+drag.translation.height-rect.minY)/rect.height)))
                let p=NormalizedPoint(x:x,y:y)
                model.setGradientEndpoints(gradeID:gradeID,maskID:maskID,start:start ? p:g.start,end:start ? g.end:p)
            })
    }
}

private struct MaskOverlayKey: Hashable { let grade: LocalGradeRecord; let width:Int; let height:Int }
private struct MaskCoveragePayload: Sendable { let width:Int; let height:Int; let rgba:[UInt8] }

private struct MaskCoverageOverlay: View {
    let grade:LocalGradeRecord
    let imageWidth:Int
    let imageHeight:Int
    @State private var overlayImage:CGImage?

    var body: some View {
        Group {
            if let overlayImage {
                Image(decorative:overlayImage,scale:1).resizable().interpolation(.high)
                    .aspectRatio(CGFloat(max(1,imageWidth))/CGFloat(max(1,imageHeight)),contentMode:.fit)
            }
        }
        .task(id:MaskOverlayKey(grade:grade,width:imageWidth,height:imageHeight)) {
            let g=grade
            let scale=min(1.0,1080.0/Double(max(max(1,imageWidth),max(1,imageHeight))))
            let w=max(1,Int((Double(imageWidth)*scale).rounded()))
            let h=max(1,Int((Double(imageHeight)*scale).rounded()))
            let payload=await Task.detached(priority:.userInitiated) { () -> MaskCoveragePayload in
                let c=MaskedLocalGradeEngine.coverageForGrade(g,width:w,height:h)
                let a=c.prefix(w*h).map{UInt8(clamping:Int((max(0,min(1,$0))*255).rounded()))}
                let canonical=CanonicalMaskBuffer(width:w,height:h,coverage:a)
                return MaskCoveragePayload(width:w,height:h,rgba:canonical.overlayRGBA(maximumAlpha:230))
            }.value
            guard !Task.isCancelled else { return }
            overlayImage=CGImage.fromRGBA8(width:payload.width,height:payload.height,bytes:payload.rgba)
        }
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
