import SwiftUI

enum CullDisplayMode: String, CaseIterable, Identifiable {
    case loupe = "Loupe"
    case compare = "Compare"
    case survey = "Survey"
    var id: String { rawValue }
}

struct CullWorkspaceView: View {
    @ObservedObject var model: AppModel
    @State private var displayMode: CullDisplayMode = .loupe

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("View", selection: $displayMode) { ForEach(CullDisplayMode.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 260)
                Spacer()
                if model.isCullAnalyzing {
                    ProgressView(value: model.cullAnalysisProgress).frame(width: 120)
                    Button("Cancel") { model.cancelCullAnalysis() }
                } else {
                    Button("Analyze Selection", systemImage: "sparkles") { model.analyzeCullNeighborhood() }
                }
            }.padding(9)
            Divider()
            HSplitView {
                cullViewer.frame(minWidth: 680)
                cullInspector.frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
            }
            Divider()
            filmstrip.frame(height: 118)
        }
        .background(StudioPalette.canvas)
    }

    @ViewBuilder private var cullViewer: some View {
        switch displayMode {
        case .loupe:
            if let image = model.selectedImage { CullPreview(url: image.url).padding(16) }
            else { ContentUnavailableView("No Photo", systemImage: "photo") }
        case .compare:
            HStack(spacing: 8) { ForEach(model.cullComparisonImages.prefix(2)) { CullPreview(url: $0.url) } }.padding(12)
        case .survey:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 8)], spacing: 8) {
                ForEach(model.cullComparisonImages.prefix(8)) { image in
                    CullPreview(url: image.url).overlay(alignment: .bottomLeading) { Text(image.fileName).font(.caption2).padding(5).background(.ultraThinMaterial) }
                }
            }.padding(12)
        }
    }

    private var cullInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let image = model.selectedImage {
                    Text(image.fileName).font(.headline)
                    HStack {
                        Button { model.setFlag(.picked) } label: { Label("Pick", systemImage: image.flag == .picked ? "flag.fill" : "flag") }
                        Button { model.setFlag(.rejected) } label: { Label("Reject", systemImage: image.flag == .rejected ? "xmark.circle.fill" : "xmark.circle") }
                    }
                    HStack(spacing: 6) { ForEach(1...5, id: \.self) { n in Button { model.setRating(n) } label: { Image(systemName: n <= image.rating ? "star.fill" : "star") }.buttonStyle(.plain) } }
                    HStack(spacing: 8) { ForEach(PhotoColorLabel.allCases) { label in Button { model.setColorLabel(image.colorLabel == label ? nil : label) } label: { Circle().fill(color(label)).frame(width: 15, height: 15).overlay(Circle().stroke(.primary.opacity(image.colorLabel == label ? 0.9 : 0.15), lineWidth: 2)) }.buttonStyle(.plain).help(label.rawValue) } }
                    Divider()
                    if let cull = image.cullAnalysis {
                        HStack(alignment: .firstTextBaseline) { Text(String(format: "%.0f", cull.score)).font(.system(size: 38, weight: .bold, design: .rounded)); Text(cull.recommendation.rawValue).font(.title3.weight(.semibold)) }
                        meter("Focus", cull.sharpness)
                        if cull.faceCount > 0 { meter("Face focus", cull.faceSharpness) }
                        meter("Exposure", cull.exposureQuality)
                        info("Faces", "\(cull.faceCount)")
                        info("Highlights", String(format: "%.1f%%", cull.highlightClipPercent))
                        info("Shadows", String(format: "%.1f%%", cull.shadowClipPercent))
                        if let rank = cull.stackRank, let count = cull.stackCount { info("Stack", "#\(rank) of \(count)") }
                        if cull.possibleBlink { Label("Possible blink — verify at 100%", systemImage: "eye.slash").font(.caption).foregroundStyle(.orange) }
                        ForEach(cull.reasons, id: \.self) { Text("• \($0)").font(.caption).foregroundStyle(.secondary) }
                        Button("Reanalyze", systemImage: "arrow.clockwise") { model.analyzeSelectedForCull() }
                    } else {
                        Text("No smart-cull analysis yet.").font(.caption).foregroundStyle(.secondary)
                        Button("Analyze Photo", systemImage: "sparkles") { model.analyzeSelectedForCull() }
                    }
                    Divider()
                    Button("Open in Edit", systemImage: "slider.horizontal.3") { model.page = .edit; model.workspaceDidChange(.edit) }.buttonStyle(.borderedProminent)
                }
            }.padding(12)
        }.background(StudioPalette.panel)
    }

    private var filmstrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                ForEach(model.visibleImages) { image in
                    ZStack(alignment: .topTrailing) {
                        LocalThumbnail(url: image.url).frame(width: 126, height: 84)
                        if let score = image.cullAnalysis?.score { Text(String(format: "%.0f", score)).font(.caption2.monospacedDigit()).padding(3).background(.ultraThinMaterial) }
                    }
                    .padding(4)
                    .background(model.project.selectedImageID == image.id ? Color.primary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    .onTapGesture { model.selectImage(image.id, renderPreview: false) }
                }
            }.padding(8)
        }
    }

    private func meter(_ label: String, _ value: Double) -> some View { VStack(alignment: .leading, spacing: 4) { HStack { Text(label); Spacer(); Text(String(format: "%.0f%%", value * 100)).monospacedDigit() }.font(.caption); ProgressView(value: max(0,min(1,value))) } }
    private func info(_ label: String, _ value: String) -> some View { HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).monospacedDigit() }.font(.caption) }
    private func color(_ label: PhotoColorLabel) -> Color { switch label { case .red:.red; case .yellow:.yellow; case .green:.green; case .blue:.blue; case .purple:.purple } }
}

private struct CullPreview: View {
    let url: URL
    @State private var image: CGImage?
    var body: some View {
        ZStack {
            StudioPalette.recessed
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
            else { ProgressView().controlSize(.large) }
        }
        .task(id: url.path) {
            image = nil
            guard let payload = try? await ThumbnailPipeline.shared.thumbnail(url: url, maxPixel: 1280), !Task.isCancelled else { return }
            image = payload.makeCGImage()
        }
    }
}
