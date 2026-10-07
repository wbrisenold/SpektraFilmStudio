import SwiftUI
import AppKit

// Native, dependency-free studio mockups. Inspired by MIT CSS-Device-Mockups (callmenick)
// and MIT FrameUp; no external assets or third-party renderer are redistributed.
private enum StudioMockup: String, CaseIterable, Identifiable {
    case output = "Actual File"
    case phone = "Phone"
    case feed = "Social Feed"
    case browser = "Browser"
    case print = "Fine Art Print"
    case gallery = "Gallery Wall"
    var id: String { rawValue }
}

struct StudioExportPreview: View {
    @ObservedObject var model: AppModel
    let image: ProjectImageRecord
    @State private var mockup: StudioMockup = .output
    @State private var rendered: CGImage?
    @State private var rendering = false
    @State private var failed = false

    private var settings: ExportSettings { model.project.exportSettings }
    private var sourceRatio: CGFloat {
        if let rendered { return CGFloat(rendered.width) / CGFloat(max(1, rendered.height)) }
        return 3.0 / 2.0
    }
    private var targetRatio: CGFloat {
        guard settings.resizeMode == .cropToFill || settings.resizeMode == .fitBox else { return sourceRatio }
        return CGFloat(max(1, settings.resizeWidth)) / CGFloat(max(1, settings.resizeHeight))
    }
    private var crop: Bool { settings.resizeMode == .cropToFill }
    private var token: String {
        // Explicitly tie asynchronous render to the photo/look and output color mode.
        "\(image.id)|\(image.look.hashValue)|\(settings.colorMode.rawValue)|\(model.rawDenoiseStatus)"
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Picker("View", selection: $mockup) {
                    ForEach(StudioMockup.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Spacer(minLength: 2)
            }
            .controlSize(.small)

            GeometryReader { proxy in
                ZStack {
                    Color(red: 0.055, green: 0.061, blue: 0.073)
                    switch mockup {
                    case .output:
                        picture
                            .frame(maxWidth: proxy.size.width - 48, maxHeight: proxy.size.height - 40)
                    case .phone:
                        phoneMockup
                            .frame(maxWidth: min(215, proxy.size.width * 0.55), maxHeight: proxy.size.height - 26)
                    case .feed:
                        socialMockup
                            .frame(maxWidth: min(335, proxy.size.width - 40), maxHeight: proxy.size.height - 28)
                    case .browser:
                        browserMockup
                            .frame(maxWidth: proxy.size.width - 40, maxHeight: proxy.size.height - 40)
                    case .print:
                        printMockup
                            .frame(maxWidth: proxy.size.width - 54, maxHeight: proxy.size.height - 32)
                    case .gallery:
                        galleryMockup
                            .frame(maxWidth: proxy.size.width - 42, maxHeight: proxy.size.height - 36)
                    }
                    if rendering {
                        ProgressView().controlSize(.small)
                            .padding(8)
                            .background(.thinMaterial, in: Capsule())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(10)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .frame(minHeight: 280)

            VStack(alignment: .leading, spacing: 3) {
                Text(crop ? "CENTER CROP TO EXACT ASPECT" : "ASPECT PRESERVED · NO HIDDEN CROP")
                    .font(.caption2.weight(.semibold))
                Text(settings.resizeMode == .cropToFill
                     ? "Export crops to \(settings.resizeWidth) × \(settings.resizeHeight) shape. Mockup uses this exact framing."
                     : "Mockups are simulated viewing environments; the file preserves its own aspect ratio.")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(rendered == nil ? (failed ? "Rendered preview unavailable · showing source thumbnail" : "Preparing color-managed preview") : "Live output look and crop · mockup chrome is not exported · print views are layout simulations, not paper/ICC soft proofs")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { chooseMockupForOutput() }
        .onChange(of: settings.resizeMode) { _, _ in chooseMockupForOutput() }
        .onChange(of: settings.resizeWidth) { _, _ in chooseMockupForOutput() }
        .onChange(of: settings.resizeHeight) { _, _ in chooseMockupForOutput() }
        .task(id: token) {
            rendering = true
            rendered = nil
            failed = false
            if let result = await model.renderStudioExportPreview(for: image, colorMode: settings.colorMode) {
                guard !Task.isCancelled else { return }
                rendered = result
            } else if !Task.isCancelled { failed = true }
            rendering = false
        }
    }

    private func chooseMockupForOutput() {
        guard settings.resizeMode == .cropToFill else { mockup = .output; return }
        let ratio = CGFloat(max(1, settings.resizeWidth)) / CGFloat(max(1, settings.resizeHeight))
        if ratio < 0.68 { mockup = .phone }
        else if ratio > 1.48 { mockup = .browser }
        else { mockup = .feed }
    }

    @ViewBuilder private var content: some View {
        if let rendered {
            Image(decorative: rendered, scale: 1).resizable()
        } else {
            LocalThumbnail(url: image.url, contentMode: .fill)
        }
    }

    private var picture: some View {
        GeometryReader { geo in
            let frameRatio = crop ? targetRatio : sourceRatio
            let maxW = max(1, geo.size.width)
            let maxH = max(1, geo.size.height)
            let width = min(maxW, maxH * frameRatio)
            let height = width / max(0.01, frameRatio)
            content
                .aspectRatio(frameRatio, contentMode: crop ? .fill : .fit)
                .frame(width: width, height: height)
                .clipped()
                .background(Color.black)
                .overlay { Rectangle().stroke(.white.opacity(0.13), lineWidth: 1) }
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }

    private var phoneMockup: some View {
        VStack(spacing: 0) {
            Capsule().fill(.white.opacity(0.18)).frame(width: 62, height: 6).padding(.top, 12).padding(.bottom, 14)
            picture.padding(.horizontal, 8)
            Spacer(minLength: 10)
            Capsule().fill(.white.opacity(0.4)).frame(width: 60, height: 4).padding(.bottom, 9)
        }
        .background(Color(red: 0.12, green: 0.13, blue: 0.15), in: RoundedRectangle(cornerRadius: 29))
        .overlay { RoundedRectangle(cornerRadius: 29).stroke(.white.opacity(0.25), lineWidth: 2) }
        .shadow(color: .black.opacity(0.55), radius: 18, y: 10)
        .aspectRatio(9.0 / 18.8, contentMode: .fit)
    }

    private var socialMockup: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle().fill(.gray.opacity(0.45)).frame(width: 22, height: 22)
                Text("studio.preview").font(.caption2.weight(.semibold))
                Spacer()
                Image(systemName: "ellipsis")
            }.padding(.horizontal, 10).padding(.top, 10)
            picture.frame(maxHeight: .infinity)
            HStack(spacing: 12) {
                Image(systemName: "heart")
                Image(systemName: "bubble")
                Image(systemName: "paperplane")
                Spacer()
                Image(systemName: "bookmark")
            }.font(.caption).padding(.horizontal, 12).padding(.bottom, 10)
        }
        .foregroundStyle(.white.opacity(0.85))
        .background(Color(red: 0.085, green: 0.09, blue: 0.10), in: RoundedRectangle(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(0.12), lineWidth: 1) }
        .aspectRatio(0.86, contentMode: .fit)
    }

    // Paper-white mat surrounds the actual crop/fit output. No false image stretching.
    private var printMockup: some View {
        picture
            .padding(.horizontal, 23).padding(.vertical, 30)
            .background(Color(red:0.94, green:0.93, blue:0.90))
            .overlay { Rectangle().stroke(.black.opacity(0.2), lineWidth: 1) }
            .padding(6)
            .background(Color(red:0.12,green:0.12,blue:0.13))
            .overlay { Rectangle().stroke(.white.opacity(0.27), lineWidth: 1) }
            .shadow(color:.black.opacity(0.55), radius:19, y:10)
            .padding(12)
    }

    private var galleryMockup: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors:[Color(red:0.71,green:0.68,blue:0.63),
                                       Color(red:0.83,green:0.81,blue:0.77)],
                               startPoint:.topLeading,endPoint:.bottomTrailing)
                VStack(spacing:0) {
                    Spacer(minLength:12)
                    printMockup
                        .frame(width:geo.size.width*0.70, height:geo.size.height*0.71)
                    Spacer(minLength:12)
                    Rectangle().fill(.black.opacity(0.12)).frame(height:4)
                    Rectangle().fill(Color(red:0.48,green:0.42,blue:0.36)).frame(height:17)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius:9))
        }
        .aspectRatio(1.45, contentMode:.fit)
    }

    private var browserMockup: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(.red.opacity(0.7)).frame(width: 8, height: 8)
                Circle().fill(.yellow.opacity(0.7)).frame(width: 8, height: 8)
                Circle().fill(.green.opacity(0.7)).frame(width: 8, height: 8)
                Spacer()
                Text("Studio web preview").font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(11)
            .background(.white.opacity(0.08))
            picture.padding(14)
        }
        .background(Color(red: 0.10, green: 0.11, blue: 0.13), in: RoundedRectangle(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(0.16), lineWidth: 1) }
        .aspectRatio(1.55, contentMode: .fit)
    }
}

@MainActor
extension AppModel {
    func renderStudioExportPreview(for image: ProjectImageRecord, colorMode: ExportColorMode) async -> CGImage? {
        guard !isExporting, let activeRenderer = exactRenderer else { return nil }
        do {
            try Task.checkCancellation()
            var look = image.look
            if colorMode == .sRGB {
                look.values["outputColorSpace"] = .int(17)
                look.values["outputRole"] = .int(0)
            }
            let base = try await decoder.decode(
                url: effectiveSourceURL(for: image), longEdge: AppPreferences.editProxyLongEdge,
                raw: image.look.raw, bypassImportTransform: project.preferences.bypassImportTransform,
                cacheMode: cacheMemoryMode
            )
            try Task.checkCancellation()
            let renderLook = look
            let graded = await Task.detached(priority: .utility) {
                base.applyingHostGrade(tone: renderLook.tone, density: renderLook.colorDensity)
                    .applyingHostGrade(tone: renderLook.filmTone, density: nil)
            }.value
            let (film, _) = try await activeRenderer.render(graded, look: renderLook)
            try Task.checkCancellation()
            let clipPrefs = project.preferences
            let output = await Task.detached(priority: .utility) {
                ExposureBoundaryEngine.apply(GeometryEngine.transformed(
                    LensCharacterEngine.apply(MaskedLocalGradeEngine.apply(film, grades: renderLook.localGrades), settings: renderLook.lensEffects),
                    settings: renderLook.geometry
                ), look: renderLook, preferences: clipPrefs)
            }.value
            try Task.checkCancellation()
            let space = OutputColorProfile.forLook(look).cgColorSpace
            return output.makeFloatImagePayload()?.makeCGImage(colorSpace: space) ?? output.makeCGImage8(colorSpace: space)
        } catch { return nil }
    }
}
