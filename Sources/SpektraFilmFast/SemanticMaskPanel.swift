import SwiftUI

struct SemanticMaskPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("AI MASKS").font(.caption2.weight(.semibold))
                Spacer()
                Button("Analyze Masks") { model.refreshCanonicalSemanticMasks() }
                    .buttonStyle(.borderless)
            }
            Text(model.semanticMaskStatus)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if let grade = model.selectedLook.localGrades?.first {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84))], spacing: 5) {
                    ForEach(SemanticMaskKind.allCases.filter { $0 != .object }) { kind in
                        Button(kind.rawValue) { model.addSemanticMask(kind, to: grade.id) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }

                HStack(spacing: 6) {
                    Button("Select Object") { model.beginObjectMaskPick(gradeID: grade.id, blendMode: .add) }
                    Button("Add Object") { model.beginObjectMaskPick(gradeID: grade.id, blendMode: .add) }
                    Button("Subtract Object") { model.beginObjectMaskPick(gradeID: grade.id, blendMode: .subtract) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if model.isObjectMaskPicking {
                    Button("Cancel Object Pick") { model.cancelObjectMaskPick() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }

                Text("Semantic and object masks enter the same Stage 2 raster-mask stack, so Add/Subtract/Intersect, invert, opacity and feather behave the same for AI and manual masks.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Add a Local Grade first, then add AI masks to it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
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
