import Foundation
import AppKit

@MainActor
extension AppModel {
    var selectedProofGallery: ProofGallerySnapshot? {
        if let id = selectedProofGalleryID, let gallery = proofGalleries.first(where: { $0.id == id }) { return gallery }
        return proofGalleries.first
    }

    func refreshProofGalleries() async {
        do {
            try await ProofDockService.shared.ensureRunning()
            let values = await ProofDockService.shared.snapshots()
            proofGalleries = values
            if selectedProofGalleryID == nil || !values.contains(where: { $0.id == selectedProofGalleryID }) {
                selectedProofGalleryID = values.first?.id
            }
            if let gallery = selectedProofGallery {
                proofStatus = gallery.finished
                    ? "Client finished · \(gallery.selectedCount) selected"
                    : "\(gallery.photos.count) proofs · \(gallery.selectedCount) selected"
            } else {
                proofStatus = "ProofDock ready"
            }
        } catch {
            proofStatus = error.localizedDescription
        }
    }

    func createProofGallery(
        name: String,
        imageIDs: [UUID],
        maxSelections: Int?,
        password: String,
        longEdge: Int,
        jpegQuality: Double
    ) {
        guard !isGeneratingProofs, let exactRenderer else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = imageIDs.compactMap { id in project.images.first(where: { $0.id == id }) }
            .filter { FileManager.default.fileExists(atPath: $0.sourcePath) }
        guard !cleanName.isEmpty else { proofStatus = "Enter a gallery name"; return }
        guard !chosen.isEmpty else { proofStatus = "No photos match this proof source"; return }

        isGeneratingProofs = true
        proofGenerationProgress = 0
        proofStatus = "Preparing 0 / \(chosen.count) proofs…"
        let galleryID = UUID()
        let galleryDirectory = ProofDockPaths.galleryDirectory(galleryID)
        let prefs = project.preferences
        let edge = min(4096, max(900, longEdge))
        let quality = min(1, max(0.5, jpegQuality))
        let memoryMode = cacheMemoryMode

        Task { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(at: galleryDirectory, withIntermediateDirectories: true)
                var seeds: [ProofGalleryPhotoSeed] = []
                seeds.reserveCapacity(chosen.count)

                for (index, image) in chosen.enumerated() {
                    try Task.checkCancellation()
                    let input = try await decoder.decode(
                        url: image.url,
                        longEdge: edge,
                        raw: image.look.raw,
                        bypassImportTransform: prefs.bypassImportTransform,
                        cacheMode: memoryMode
                    )
                    let renderInput = input.applyingHostGrade(tone: image.look.tone, density: image.look.colorDensity)
                    let (filmOutput, _) = try await exactRenderer.render(renderInput, look: image.look)
                    var output = GeometryEngine.transformed(filmOutput, settings: image.look.geometry)
                    if max(output.width, output.height) > edge {
                        output = try output.resized(longEdge: edge)
                    }
                    let proofID = UUID()
                    let destination = galleryDirectory.appendingPathComponent("\(proofID.uuidString).jpg")
                    var settings = ExportSettings()
                    settings.format = .jpeg
                    settings.jpegQuality = quality
                    settings.tiff16Bit = false
                    settings.preserveMetadata = false
                    try await exportEngine.write(
                        output: output,
                        look: image.look,
                        sourceURL: image.url,
                        destination: destination,
                        settings: settings
                    )
                    seeds.append(ProofGalleryPhotoSeed(
                        id: proofID,
                        sourceImageID: image.id,
                        sourcePath: image.sourcePath,
                        proofPath: destination.path,
                        originalFilename: image.fileName
                    ))
                    proofGenerationProgress = Double(index + 1) / Double(chosen.count)
                    proofStatus = "Preparing \(index + 1) / \(chosen.count) proofs…"
                }

                _ = try await ProofDockService.shared.createGallery(
                    id: galleryID,
                    name: cleanName,
                    maxSelections: maxSelections,
                    password: password,
                    photos: seeds
                )
                isGeneratingProofs = false
                proofGenerationProgress = 1
                selectedProofGalleryID = galleryID
                await refreshProofGalleries()
                proofStatus = "Proof gallery ready · \(chosen.count) images"
            } catch {
                try? FileManager.default.removeItem(at: galleryDirectory)
                isGeneratingProofs = false
                proofGenerationProgress = 0
                proofStatus = "Proof generation failed · \(error.localizedDescription)"
            }
        }
    }

    func startProofSharing() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await ProofDockService.shared.startSharing()
                proofStatus = "Starting secure client link…"
                for _ in 0..<45 {
                    try? await Task.sleep(for: .milliseconds(700))
                    await refreshProofGalleries()
                    if selectedProofGallery?.publicLink != nil {
                        proofStatus = "Client link is live"
                        return
                    }
                    if let error = selectedProofGallery?.shareError, !error.isEmpty {
                        proofStatus = error
                        return
                    }
                }
                proofStatus = "Share link is still starting; Same Wi-Fi link is available now"
            } catch {
                proofStatus = error.localizedDescription
            }
        }
    }

    func stopProofSharing() {
        Task { [weak self] in
            await ProofDockService.shared.stopSharing()
            await self?.refreshProofGalleries()
            self?.proofStatus = "Internet sharing stopped"
        }
    }

    func regenerateProofClientLink() {
        guard let id = selectedProofGallery?.id else { return }
        Task { [weak self] in
            do {
                try await ProofDockService.shared.regenerateClientLink(galleryID: id)
                await self?.refreshProofGalleries()
                self?.proofStatus = "New client link created · existing picks preserved"
            } catch { self?.proofStatus = error.localizedDescription }
        }
    }

    func reopenProofClientLink() {
        guard let id = selectedProofGallery?.id else { return }
        Task { [weak self] in
            do {
                try await ProofDockService.shared.reopenSameLink(galleryID: id)
                await self?.refreshProofGalleries()
                self?.proofStatus = "Client selection reopened on the same link"
            } catch { self?.proofStatus = error.localizedDescription }
        }
    }

    func setProofCover(_ photoID: UUID) {
        guard let id = selectedProofGallery?.id else { return }
        Task { [weak self] in
            do {
                try await ProofDockService.shared.setCover(galleryID: id, photoID: photoID)
                await self?.refreshProofGalleries()
                self?.proofStatus = "Link-preview cover updated"
            } catch { self?.proofStatus = error.localizedDescription }
        }
    }

    func syncProofClientPicks() {
        guard let gallery = selectedProofGallery else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let picks = try await ProofDockService.shared.clientPicks(galleryID: gallery.id)
                let galleryImageIDs = Set(gallery.photos.map(\.sourceImageID))
                let selectedIDs = Set(picks.map(\.sourceImageID))
                for index in project.images.indices where galleryImageIDs.contains(project.images[index].id) {
                    project.images[index].clientPicked = selectedIDs.contains(project.images[index].id)
                }
                proofStatus = "Synced \(picks.count) client pick\(picks.count == 1 ? "" : "s") to Library"
                libraryFilter = .clientPicks
            } catch { proofStatus = error.localizedDescription }
        }
    }

    func openProofClientPicksInFinder() {
        guard let id = selectedProofGallery?.id else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let folder = try await ProofDockService.shared.createClientPickSymlinks(galleryID: id)
                NSWorkspace.shared.open(folder)
                proofStatus = "Opened client picks in Finder"
            } catch { proofStatus = error.localizedDescription }
        }
    }

    func copyProofClientPickFilenames() {
        guard let id = selectedProofGallery?.id else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let picks = try await ProofDockService.shared.clientPicks(galleryID: id)
                let text = picks.map(\.originalFilename).joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                proofStatus = "Copied \(picks.count) selected filename\(picks.count == 1 ? "" : "s")"
            } catch { proofStatus = error.localizedDescription }
        }
    }

    func deleteSelectedProofGallery() {
        guard let id = selectedProofGallery?.id else { return }
        Task { [weak self] in
            await ProofDockService.shared.deleteGallery(id)
            self?.selectedProofGalleryID = nil
            await self?.refreshProofGalleries()
        }
    }
}
