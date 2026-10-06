import SwiftUI
import AppKit

private enum ProofSourceMode: String, CaseIterable, Identifiable {
    case picks = "Cull Picks"
    case clientCandidates = "All Non-Rejected"
    case threeStar = "3+ Stars"
    case fourStar = "4+ Stars"
    case fiveStar = "5 Stars"
    case librarySelection = "Library Selection"
    var id: String { rawValue }
}

struct ProofsWorkspaceView: View {
    @ObservedObject var model: AppModel
    @State private var showingNewGallery = false
    @State private var name = ""
    @State private var sourceMode: ProofSourceMode = .picks
    @State private var selectionLimit = 0
    @State private var password = ""
    @State private var longEdge = 2048.0
    @State private var quality = 0.88

    var body: some View {
        HSplitView {
            gallerySidebar
                .frame(minWidth: 210, idealWidth: 230, maxWidth: 280)
            galleryBody
        }
        .background(StudioPalette.canvas)
        .task {
            while !Task.isCancelled {
                await model.refreshProofGalleries()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .sheet(isPresented: $showingNewGallery) { newGallerySheet }
    }

    private var gallerySidebar: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PROOFDOCK")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Client Proofing")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button { showingNewGallery = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain)
                    .help("Create a proof gallery from your cull or rating selection.")
            }
            .padding(11)

            Divider().opacity(0.55)

            if model.proofGalleries.isEmpty {
                ContentUnavailableView(
                    "No Proof Galleries",
                    systemImage: "heart.text.square",
                    description: Text("Create a client gallery directly from your cull picks.")
                )
                .padding(.horizontal, 10)
            } else {
                List(selection: Binding(
                    get: { model.selectedProofGalleryID },
                    set: { model.selectedProofGalleryID = $0 }
                )) {
                    ForEach(model.proofGalleries) { gallery in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 7) {
                                Text(gallery.name).font(.caption.weight(.semibold)).lineLimit(1)
                                Spacer()
                                if gallery.finished {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                } else if gallery.shareRunning {
                                    Circle().fill(.green).frame(width: 6, height: 6)
                                }
                            }
                            HStack(spacing: 6) {
                                Text("\(gallery.photos.count) proofs")
                                Text("·")
                                Text("\(gallery.selectedCount) picks")
                            }
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .tag(gallery.id)
                    }
                }
                .listStyle(.sidebar)
            }

            Divider().opacity(0.55)
            Button {
                showingNewGallery = true
            } label: {
                Label("New Proof Gallery", systemImage: "plus.rectangle.on.rectangle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)
            .padding(10)
        }
        .background(StudioPalette.panel)
    }

    @ViewBuilder
    private var galleryBody: some View {
        if let gallery = model.selectedProofGallery {
            VStack(spacing: 0) {
                galleryHeader(gallery)
                Divider().opacity(0.55)
                shareBar(gallery)
                Divider().opacity(0.55)
                galleryGrid(gallery)
                Divider().opacity(0.55)
                footer(gallery)
            }
        } else {
            ContentUnavailableView(
                "Client Proofing Stays Here",
                systemImage: "person.2.crop.square.stack",
                description: Text("Cull, create a client gallery, send the short link, sync their picks, then keep editing without leaving SpektraFilm Studio.")
            )
        }
    }

    private func galleryHeader(_ gallery: ProofGallerySnapshot) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(gallery.name)
                    .font(.title3.weight(.semibold))
                HStack(spacing: 8) {
                    Label("\(gallery.photos.count) proofs", systemImage: "photo.stack")
                    Label("\(gallery.selectedCount) selected", systemImage: "heart.fill")
                    if gallery.finished { Label("Client finished", systemImage: "checkmark.seal.fill") }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if gallery.finished {
                Button("Reopen Same Link") { model.reopenProofClientLink() }
                    .help("Lets the client edit the existing picks again without changing the URL.")
            }
            Button("New Client Link") { model.regenerateProofClientLink() }
                .help("Creates a new short URL, preserves the current picks, and reopens the gallery.")
            Menu {
                Button("Copy Pick Filenames") { model.copyProofClientPickFilenames() }
                Button("Open Picked Originals in Finder") { model.openProofClientPicksInFinder() }
                Divider()
                Button("Delete Gallery", role: .destructive) { model.deleteSelectedProofGallery() }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 14)
        .frame(height: 66)
        .background(StudioPalette.panel)
    }

    private func shareBar(_ gallery: ProofGallerySnapshot) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 9) {
                Label(gallery.shareRunning && gallery.publicLink != nil ? "ONLINE" : "LOCAL", systemImage: gallery.shareRunning && gallery.publicLink != nil ? "network.badge.shield.half.filled" : "wifi")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(gallery.shareRunning && gallery.publicLink != nil ? .green : .secondary)

                Text(gallery.publicLink ?? gallery.lanLink)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .textSelection(.enabled)

                Spacer()
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(gallery.publicLink ?? gallery.lanLink, forType: .string)
                    model.proofStatus = "Client link copied"
                }
                if gallery.shareRunning {
                    Button("Stop Internet Link") { model.stopProofSharing() }
                } else {
                    Button("Start Internet Link") { model.startProofSharing() }
                        .buttonStyle(.borderedProminent)
                }
            }
            HStack {
                Text("Short link: /g/\(gallery.shortCode)")
                Spacer()
                if let limit = gallery.maxSelections { Text("Selection limit: \(limit)") }
                else { Text("No selection limit") }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(StudioPalette.recessed)
    }

    private func galleryGrid(_ gallery: ProofGallerySnapshot) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 10)], spacing: 10) {
                ForEach(gallery.photos) { photo in
                    proofCard(photo)
                }
            }
            .padding(12)
        }
    }

    private func proofCard(_ photo: ProofPhotoRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                ProofLocalImage(path: photo.proofPath)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(Color.black.opacity(0.45))
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                HStack(spacing: 5) {
                    if photo.selected {
                        Label("PICK", systemImage: "heart.fill")
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .background(.black.opacity(0.72), in: Capsule())
                    }
                    if photo.isCover {
                        Text("COVER")
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .background(.black.opacity(0.72), in: Capsule())
                    }
                }
                .font(.system(size: 8, weight: .bold))
                .padding(7)
            }

            HStack(spacing: 6) {
                Text(photo.originalFilename)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if !photo.isCover {
                    Button("Set Cover") { model.setProofCover(photo.id) }
                        .font(.caption2)
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(6)
        .background(photo.selected ? StudioPalette.selected : StudioPalette.recessed, in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).stroke(photo.selected ? StudioPalette.selectedBorder : StudioPalette.subtleBorder, lineWidth: photo.selected ? 1 : 0.5) }
    }

    private func footer(_ gallery: ProofGallerySnapshot) -> some View {
        HStack(spacing: 10) {
            Text(model.proofStatus)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if model.isGeneratingProofs {
                ProgressView(value: model.proofGenerationProgress).frame(width: 130)
            }
            Spacer()
            Button("Copy Pick Filenames") { model.copyProofClientPickFilenames() }
                .disabled(gallery.selectedCount == 0)
            Button("Open Originals") { model.openProofClientPicksInFinder() }
                .disabled(gallery.selectedCount == 0)
            Button("Sync Client Picks to Library") { model.syncProofClientPicks() }
                .buttonStyle(.borderedProminent)
                .disabled(gallery.selectedCount == 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(StudioPalette.panel)
    }

    private var newGallerySheet: some View {
        let candidates = candidateImages
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Client Proof Gallery").font(.title3.weight(.semibold))
                    Text("Generate edited JPEG proofs directly from the current project.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Form {
                TextField("Gallery name", text: $name)
                Picker("Source", selection: $sourceMode) {
                    ForEach(ProofSourceMode.allCases) { Text($0.rawValue).tag($0) }
                }
                LabeledContent("Photos") { Text("\(candidates.count)").monospacedDigit() }
                Stepper("Selection limit: \(selectionLimit == 0 ? "None" : String(selectionLimit))", value: $selectionLimit, in: 0...999)
                SecureField("Optional client password", text: $password)

                Section("Proof JPEG") {
                    LabeledContent("Long edge") {
                        HStack {
                            Slider(value: $longEdge, in: 1200...3200, step: 100)
                                .help("Sets the maximum proof size. Larger proofs show more detail but upload more slowly through the client link.")
                            Button { longEdge = 2048 } label: { Image(systemName: "arrow.counterclockwise") }
                                .buttonStyle(.plain)
                                .help("Reset proof size to 2048 px.")
                            Text("\(Int(longEdge)) px").monospacedDigit().frame(width: 64)
                        }
                    }
                    LabeledContent("JPEG quality") {
                        HStack {
                            Slider(value: $quality, in: 0.65...0.98, step: 0.01)
                                .help("Controls proof JPEG compression. Around 85–90% is usually a good balance between detail and fast client loading.")
                            Button { quality = 0.88 } label: { Image(systemName: "arrow.counterclockwise") }
                                .buttonStyle(.plain)
                                .help("Reset proof JPEG quality to 88%.")
                            Text(quality, format: .percent.precision(.fractionLength(0))).frame(width: 48)
                        }
                    }
                    Text("Proofs use the current WB, Exposure/Curve, SpektraFilm look, and Crop/Geometry. GPS/private metadata is not copied. Full-resolution originals are never served to the client.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { showingNewGallery = false }
                Spacer()
                Button("Create \(candidates.count) Proofs") {
                    let fallbackName = model.project.name == "Untitled Project" ? "Client Proofs" : model.project.name
                    model.createProofGallery(
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackName : name,
                        imageIDs: candidates.map(\.id),
                        maxSelections: selectionLimit == 0 ? nil : selectionLimit,
                        password: password,
                        longEdge: Int(longEdge),
                        jpegQuality: quality
                    )
                    showingNewGallery = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(candidates.isEmpty || model.isGeneratingProofs)
            }
        }
        .padding(18)
        .frame(width: 560, height: 590)
    }

    private var candidateImages: [ProjectImageRecord] {
        switch sourceMode {
        case .picks:
            return model.project.images.filter { $0.flag == .picked }
        case .clientCandidates:
            return model.project.images.filter { $0.flag != .rejected }
        case .threeStar:
            return model.project.images.filter { $0.rating >= 3 && $0.flag != .rejected }
        case .fourStar:
            return model.project.images.filter { $0.rating >= 4 && $0.flag != .rejected }
        case .fiveStar:
            return model.project.images.filter { $0.rating == 5 && $0.flag != .rejected }
        case .librarySelection:
            let ids = model.librarySelection
            return model.project.images.filter { ids.contains($0.id) }
        }
    }
}

private struct ProofLocalImage: View {
    let path: String
    var body: some View {
        if let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            ZStack { Color.black.opacity(0.35); Image(systemName: "photo").foregroundStyle(.secondary) }
        }
    }
}
