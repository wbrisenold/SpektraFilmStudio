import SwiftUI

enum CullDisplayMode: String, CaseIterable, Identifiable {
    case loupe = "Single Photo"
    case compare = "Compare"
    case survey = "Overview"
    var id: String { rawValue }
}

private enum CullNavigationScope: String, CaseIterable, Identifiable {
    case visible = "All Visible Photos"
    case highlighted = "Selected Photos"
    var id: String { rawValue }
}

struct CullWorkspaceView: View {
    @ObservedObject var model: AppModel
    @State private var displayMode: CullDisplayMode = .loupe
    @State private var navigationScope: CullNavigationScope = .visible
    @State private var reviewFilter: CullReviewFilter = .all
    @State private var bestPickFolder: String = ""
    @State private var bestPickFraction: Double = 0.25
    @State private var compareCount = 2
    @State private var zoom: CGFloat = 1
    @AppStorage("cullFilmstripHeight") private var filmstripHeight = 138.0
    @State private var resizeStart: Double?
    @AppStorage("SpektraFilmStudio.designA.showCullInspector") private var showCullInspector = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()

            HSplitView {
                viewer.frame(minWidth: 500)
                if showCullInspector {
                    inspector.frame(minWidth: 270, idealWidth: 310, maxWidth: 380)
                }
            }

            Divider()
            filmstrip
        }
        .background(StudioPalette.canvas)
    }

    private var topBar: some View {
        VStack(spacing: 8) {
          HStack(spacing: 10) {
            Picker("View", selection: $displayMode) {
                ForEach(CullDisplayMode.allCases) {
                    Text($0.rawValue).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)

            if model.librarySelection.count >= 2 {
                Picker("Navigate", selection: $navigationScope) {
                    ForEach(CullNavigationScope.allCases) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 165)
            }

            Button { move(-1) } label: {
                Image(systemName: "chevron.left")
            }
            .keyboardShortcut(.leftArrow, modifiers: []).help("Previous photo · Left Arrow").accessibilityLabel("Previous photo")

            Button { move(1) } label: {
                Image(systemName: "chevron.right")
            }
            .keyboardShortcut(.rightArrow, modifiers: []).help("Next photo · Right Arrow").accessibilityLabel("Next photo")

            if displayMode == .compare {
                Picker("Frames", selection: $compareCount) {
                    Text("2-up").tag(2)
                    Text("4-up").tag(4)
                }
                .frame(width: 90)
            }

            Menu {
                Button("Fit") { zoom = 1 }
                Button("2×") { zoom = 2 }
                Button("4×") { zoom = 4 }
                Divider()
                Slider(value: $zoom, in: 1...4)
            } label: {
                Label(String(format: "%.1f×", zoom), systemImage: "magnifyingglass")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 75)

            Spacer(minLength: 6)
          }
          HStack(spacing: 10) {
            Menu {
                Picker("Review", selection: $reviewFilter) {
                    ForEach(CullReviewFilter.allCases) { f in Text(f.rawValue).tag(f) }
                }
            } label: {
                Label(reviewFilter == .all ? "Filter" : reviewFilter.rawValue,
                      systemImage: "line.3.horizontal.decrease.circle")
            }
            .help("Filter culling by face focus, blink likelihood, exposure, noise or burst membership.")

            Menu {
                Picker("Folder", selection: $bestPickFolder) {
                    Text("Current Photo Folder").tag("")
                    Text("All Folders").tag("__all__")
                    ForEach(cullFolderPaths, id: \.self) { folder in
                        Text(URL(fileURLWithPath: folder).lastPathComponent).tag(folder)
                    }
                }
                Divider()
                Picker("Keep", selection: $bestPickFraction) {
                    Text("Best 10%").tag(0.10)
                    Text("Best 25%").tag(0.25)
                    Text("Best 40%").tag(0.40)
                    Text("Best 60%").tag(0.60)
                }
                Divider()
                Button("Pick Best in Folder") {
                    let current = model.selectedImage.map(Self.folderPath)
                    let folder = bestPickFolder.isEmpty ? (current ?? "__all__") : bestPickFolder
                    model.pickBestInFolder(folder, fraction: bestPickFraction)
                }
                .disabled(model.isCullAnalyzing || model.project.images.isEmpty)
                Text("Suggested picks only; existing rejects and files are preserved.")
            } label: {
                Label("Best Picks", systemImage: "wand.and.stars")
            }
            .help("Analyze and select strongest distinct frames per folder, without deleting anything.")

            Button { showCullInspector.toggle() } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.borderless)
            .help(showCullInspector ? "Hide cull details" : "Show cull details")

            if model.isCullAnalyzing {
                ProgressView(value: model.cullAnalysisProgress)
                    .frame(width: 110)
                Text("\(Int(model.cullAnalysisProgress * 100))%")
                    .font(.caption.monospacedDigit())
                Button("Cancel") { model.cancelCullAnalysis() }
            } else {
                Button("Analyze", systemImage: "sparkles") {
                    if model.librarySelection.count > 1 {
                        model.analyzeForCull(ids: Array(model.librarySelection))
                    } else {
                        model.analyzeVisibleForCull()
                    }
                }
                .help(model.librarySelection.count > 1
                    ? "Analyze highlighted photos."
                    : "Analyze the visible cull set.")

            }
        }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(StudioPalette.panel)
    }

    @ViewBuilder
    private var viewer: some View {
        switch displayMode {
        case .loupe:
            if let image = model.selectedImage {
                CullPreview(url: model.thumbnailURL(for: image), zoom: zoom)
                    .overlay(alignment: .topLeading) {
                        viewerBadge(image)
                    }
                    .padding(12)
            } else {
                VStack(spacing: 12) {
                    ContentUnavailableView("Choose photos to review", systemImage: "photo.stack",
                                           description: Text("Import photos, or select a photo in Library. Use P to pick, X to reject, and 1–5 to rate."))
                    Button("Import Photos…") { model.importImages() }.buttonStyle(.borderedProminent)
                    Button("Show Library") { model.resetLibraryFilters(); model.showProjectHome = false; model.page = .library }
                }
            }

        case .compare:
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 300), spacing: 8)],
                spacing: 8
            ) {
                ForEach(Array(comparisonImages.prefix(compareCount))) { image in
                    CullPreview(url: model.thumbnailURL(for: image), zoom: zoom)
                        .frame(minHeight: 280)
                        .overlay(alignment: .topLeading) {
                            viewerBadge(image)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(
                                    model.project.selectedImageID == image.id
                                        ? Color.accentColor
                                        : Color.secondary.opacity(0.18),
                                    lineWidth:
                                        model.project.selectedImageID == image.id
                                        ? 2 : 0.5
                                )
                        }
                        .onTapGesture {
                            model.selectLibraryImage(image.id)
                        }
                }
            }
            .padding(10)

        case .survey:
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 245), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(Array(cullPool.prefix(24))) { image in
                        CullPreview(url: model.thumbnailURL(for: image), zoom: 1)
                            .frame(minHeight: 190)
                            .overlay(alignment: .topLeading) {
                                viewerBadge(image)
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(
                                        model.project.selectedImageID == image.id
                                            ? Color.accentColor
                                            : Color.secondary.opacity(0.18),
                                        lineWidth:
                                            model.project.selectedImageID == image.id
                                            ? 2 : 0.5
                                    )
                            }
                            .onTapGesture {
                                model.selectLibraryImage(image.id)
                            }
                    }
                }
                .padding(10)
            }
        }
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let image = model.selectedImage {
                    Text("DECISION")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(image.fileName)
                        .font(.headline)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        Button {
                            model.setFlag(.picked)
                        } label: {
                            Label(
                                "Pick",
                                systemImage:
                                    image.flag == .picked ? "flag.fill" : "flag"
                            )
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            model.setFlag(.rejected)
                        } label: {
                            Label(
                                "Reject",
                                systemImage:
                                    image.flag == .rejected
                                    ? "xmark.circle.fill" : "xmark.circle"
                            )
                        }
                        .buttonStyle(.bordered)

                        Button("Clear") { model.setFlag(.unflagged) }
                            .controlSize(.small)
                    }

                    HStack(spacing: 6) {
                        ForEach(1...5, id: \.self) { n in
                            Button { model.setRating(n) } label: {
                                Image(
                                    systemName:
                                        n <= image.rating ? "star.fill" : "star"
                                )
                            }
                            .buttonStyle(.plain)
                        }
                        if image.rating > 0 {
                            Button("0") { model.setRating(0) }
                                .controlSize(.mini)
                        }
                    }

                    HStack(spacing: 8) {
                        ForEach(PhotoColorLabel.allCases) { label in
                            Button {
                                model.setColorLabel(
                                    image.colorLabel == label ? nil : label
                                )
                            } label: {
                                Circle()
                                    .fill(color(label))
                                    .frame(width: 16, height: 16)
                                    .overlay {
                                        Circle().stroke(
                                            .primary.opacity(
                                                image.colorLabel == label
                                                ? 0.9 : 0.15
                                            ),
                                            lineWidth: 2
                                        )
                                    }
                            }
                            .buttonStyle(.plain)
                            .help(label.rawValue)
                        }
                    }

                    Divider()

                    if let cull = image.cullAnalysis {
                        HStack(alignment: .firstTextBaseline) {
                            Text(String(format: "%.0f", cull.score))
                                .font(
                                    .system(
                                        size: 42,
                                        weight: .bold,
                                        design: .rounded
                                    )
                                )
                            Text(cull.recommendation.rawValue)
                                .font(.title3.weight(.semibold))
                        }

                        if let rank = cull.stackRank,
                           let count = cull.stackCount {
                            Label(
                                rank == 1
                                    ? "Best technical frame · \(count)-photo stack"
                                    : "Rank #\(rank) of \(count)",
                                systemImage:
                                    rank == 1
                                    ? "crown.fill" : "square.stack.3d.up"
                            )
                            .font(.caption)
                            .foregroundStyle(
                                rank == 1 ? Color.yellow : Color.secondary
                            )
                        }

                        meter("Focus", cull.sharpness)
                        if cull.faceCount > 0 {
                            meter("Face focus", cull.faceSharpness)
                        }
                        meter("Exposure", cull.exposureQuality)

                        info("Faces", "\(cull.faceCount)")
                        info(
                            "Highlights",
                            String(format: "%.1f%%", cull.highlightClipPercent)
                        )
                        info(
                            "Shadows",
                            String(format: "%.1f%%", cull.shadowClipPercent)
                        )

                        if cull.possibleBlink {
                            Label(
                                "Possible blink — inspect eyes before picking",
                                systemImage: "eye.slash"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }

                        ForEach(cull.reasons, id: \.self) { reason in
                            Text("• \(reason)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Button(
                            "Reanalyze Photo",
                            systemImage: "arrow.clockwise"
                        ) {
                            model.analyzeSelectedForCull()
                        }
                    } else {
                        Text("No Smart Cull analysis yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Analyze Photo", systemImage: "sparkles") {
                            model.analyzeSelectedForCull()
                        }
                    }

                    Divider()

                    HStack {
                        Button("Library") {
                            model.page = .library
                            model.workspaceDidChange(.library)
                        }
                        Spacer()
                        Button(
                            "Open in Edit",
                            systemImage: "slider.horizontal.3"
                        ) {
                            if let id = model.selectedImage?.id {
                                model.focusPhoto(id, destination: .edit)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    ContentUnavailableView("No Selection", systemImage: "photo")
                }
            }
            .padding(12)
        }
        .background(StudioPalette.panel)
    }

    private var filmstrip: some View {
        VStack(spacing: 0) {
            ZStack {
                StudioPalette.panel
                Capsule()
                    .fill(Color.secondary.opacity(0.42))
                    .frame(width: 38, height: 3)
            }
            .frame(height: 8)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if resizeStart == nil {
                            resizeStart = filmstripHeight
                        }
                        let start = resizeStart ?? filmstripHeight
                        filmstripHeight = min(
                            280,
                            max(112, start - Double(value.translation.height))
                        )
                    }
                    .onEnded { _ in resizeStart = nil }
            )
            .help("Drag vertically to resize the Cull filmstrip.")

            HStack {
                Text("\(cullPool.count) photos")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if navigationScope == .highlighted {
                    Text("· highlighted Library set")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Slider(value: $filmstripHeight, in: 112...280)
                    .frame(width: 100)
                Button {
                    filmstripHeight = 138
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(StudioPalette.panel)

            ScrollView(.horizontal) {
                LazyHStack(spacing: 7) {
                    ForEach(cullPool) { image in
                        VStack(spacing: 3) {
                            ZStack(alignment: .topTrailing) {
                                LocalThumbnail(
                                    url: model.thumbnailURL(for: image),
                                    contentMode: .fit
                                )
                                .frame(
                                    width: max(
                                        112,
                                        CGFloat(filmstripHeight) * 1.20
                                    ),
                                    height: max(
                                        58,
                                        CGFloat(filmstripHeight) - 58
                                    )
                                )
                                .background(Color.black.opacity(0.22))

                                if let score = image.cullAnalysis?.score {
                                    Text(String(format: "%.0f", score))
                                        .font(
                                            .caption2
                                            .monospacedDigit()
                                            .weight(.semibold)
                                        )
                                        .padding(4)
                                        .background(
                                            .regularMaterial,
                                            in: Capsule()
                                        )
                                        .padding(4)
                                }
                            }

                            HStack(spacing: 4) {
                                if image.flag == .picked {
                                    Image(systemName: "flag.fill")
                                        .foregroundStyle(.green)
                                } else if image.flag == .rejected {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.red)
                                }
                                Text(
                                    image.rating == 0
                                        ? "" : "\(image.rating)★"
                                )
                                Spacer()
                            }
                            .font(.caption2)
                        }
                        .padding(4)
                        .background(
                            model.project.selectedImageID == image.id
                                ? Color.accentColor.opacity(0.15)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(
                                    model.project.selectedImageID == image.id
                                        ? Color.accentColor
                                        : Color.secondary.opacity(0.12),
                                    lineWidth:
                                        model.project.selectedImageID == image.id
                                        ? 2 : 0.5
                                )
                        }
                        .onTapGesture {
                            model.selectLibraryImage(image.id)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
            .background(StudioPalette.recessed)
        }
        .frame(height: CGFloat(filmstripHeight))
    }

    private static func folderPath(_ photo: ProjectImageRecord) -> String {
        photo.logicalFolderPath ?? photo.url.deletingLastPathComponent().standardizedFileURL.path
    }

    private var cullFolderPaths: [String] {
        Array(Set(model.project.images.map(Self.folderPath))).sorted()
    }

    private var cullPool: [ProjectImageRecord] {
        if navigationScope == .highlighted,
           model.librarySelection.count > 1 {
            let ids = model.librarySelection
            return model.visibleImages.filter { ids.contains($0.id) && reviewFilter.includes($0) }
        }
        return model.visibleImages.filter { reviewFilter.includes($0) }
    }

    private var comparisonImages: [ProjectImageRecord] {
        guard let selected = model.selectedImage else { return [] }
        let pool = cullPool
        guard let index = pool.firstIndex(where: { $0.id == selected.id })
        else { return [selected] }

        let desired = max(2, compareCount)
        let half = desired / 2
        var start = max(0, index - half)
        if start + desired > pool.count {
            start = max(0, pool.count - desired)
        }
        return Array(pool[start..<min(pool.count, start + desired)])
    }

    private func move(_ delta: Int) {
        let pool = cullPool
        guard !pool.isEmpty else { return }
        let current = model.project.selectedImageID
        let index = pool.firstIndex(where: { $0.id == current }) ?? 0
        let next = min(pool.count - 1, max(0, index + delta))
        model.selectLibraryImage(pool[next].id)
    }

    private func viewerBadge(_ image: ProjectImageRecord) -> some View {
        HStack(spacing: 6) {
            if image.flag == .picked {
                Image(systemName: "flag.fill").foregroundStyle(.green)
            } else if image.flag == .rejected {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
            if image.rating > 0 {
                Text("\(image.rating)★")
            }
            Text(image.fileName).lineLimit(1)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(.regularMaterial, in: Capsule())
        .padding(7)
    }

    private func meter(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: "%.0f%%", value * 100))
                    .monospacedDigit()
            }
            .font(.caption)
            ProgressView(value: max(0, min(1, value)))
        }
    }

    private func info(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.caption)
    }

    private func color(_ label: PhotoColorLabel) -> Color {
        switch label {
        case .red: .red
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        }
    }
}

private struct CullPreview: View {
    let url: URL
    let zoom: CGFloat
    @State private var image: CGImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                StudioPalette.recessed
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(zoom)
                        .frame(
                            width: proxy.size.width,
                            height: proxy.size.height
                        )
                        .clipped()
                } else {
                    ProgressView().controlSize(.large)
                }
            }
        }
        .task(id: url.path) {
            image = nil
            guard let payload = try? await ThumbnailPipeline.shared.thumbnail(
                url: url,
                maxPixel: 1800
            ), !Task.isCancelled else { return }
            image = payload.makeCGImage()
        }
    }
}
