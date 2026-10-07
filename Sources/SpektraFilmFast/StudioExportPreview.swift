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
    case story = "Story / Reel"
    case video = "Video Thumbnail"
    case portfolio = "Portfolio Grid"
    case contact = "Contact Sheet"
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
        if let w = image.metadata?.pixelWidth, let h = image.metadata?.pixelHeight, w > 0, h > 0 {
            return CGFloat(w) / CGFloat(h)
        }
        return 3.0 / 2.0
    }
    private var crop: Bool { settings.resizeMode == .cropToFill }
    private var outputGeometry: StudioOutputGeometry {
        // Use the actual post-geometry preview ratio. Metadata dimensions are used
        // for a pixel-size estimate only when no geometry crop is active.
        StudioOutputGeometry.calculate(
            sourceWidth: max(1, rendered?.width ?? image.metadata?.pixelWidth ?? 1500),
            sourceHeight: max(1, rendered?.height ?? image.metadata?.pixelHeight ?? 1000),
            mode: settings.resizeMode,
            width: settings.resizeWidth,
            height: settings.resizeHeight,
            longEdge: settings.resizeLongEdge,
            dontEnlarge: settings.dontEnlarge
        )
    }
    private var targetRatio: CGFloat { CGFloat(outputGeometry.width) / CGFloat(max(1, outputGeometry.height)) }
    private var constraintRatio: CGFloat {
        CGFloat(max(1, settings.resizeWidth)) / CGFloat(max(1, settings.resizeHeight))
    }
    private var dimensionsText: String {
        let dimensions = outputGeometry
        return "\(dimensions.width) × \(dimensions.height) px · \(dimensions.width > dimensions.height ? "Landscape" : (dimensions.width < dimensions.height ? "Portrait" : "Square"))"
    }
    private var cropDescription: String {
        switch settings.resizeMode {
        case .none: return "Full Size · original framing"
        case .longEdge: return "Long Edge · scale longest side to target · preserve framing"
        case .width: return "Width · output width drives scale · height follows aspect"
        case .height: return "Height · output height drives scale · width follows aspect"
        case .fitBox: return "Fit Inside · image fits within box · no cropping or padding exported"
        case .cropToFill: return "Crop to Fill · centered crop matches selected aspect"
        }
    }
    private var token: String {
        // Explicitly tie asynchronous render to the photo/look and output color mode.
        "\(image.id)|\(image.look.hashValue)|\(settings.colorMode.rawValue)|\(model.rawDenoiseStatus)"
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("PRESENTATION").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Picker("Mockup", selection: $mockup) {
                    ForEach(StudioMockup.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 190)
            }
            .controlSize(.small)

            GeometryReader { proxy in
                ZStack {
                    Color(red: 0.055, green: 0.061, blue: 0.073)
                    switch mockup {
                    case .output:
                        actualFileMockup
                            .frame(maxWidth: proxy.size.width - 40, maxHeight: proxy.size.height - 34)
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
                    case .story:
                        storyMockup
                            .frame(maxWidth: min(235, proxy.size.width * 0.58), maxHeight: proxy.size.height - 30)
                    case .video:
                        videoMockup
                            .frame(maxWidth: proxy.size.width - 45, maxHeight: proxy.size.height - 38)
                    case .portfolio:
                        portfolioMockup
                            .frame(maxWidth: proxy.size.width - 45, maxHeight: proxy.size.height - 38)
                    case .contact:
                        contactSheetMockup
                            .frame(maxWidth: proxy.size.width - 50, maxHeight: proxy.size.height - 40)
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
                HStack {
                    Text(cropDescription.uppercased())
                        .font(.caption2.weight(.semibold))
                    Spacer()
                    if settings.dontEnlarge { Label("No upscale", systemImage: "arrow.down.right.and.arrow.up.left").font(.caption2) }
                }
                Text(dimensionsText + " · based on the 1080px rendered preview; original-size export may have larger dimensions")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                if settings.resizeMode == .fitBox {
                    Text("Constraint box \(settings.resizeWidth) × \(settings.resizeHeight) px. Blank space shown in the viewer is NOT included in the exported file.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if settings.resizeMode == .cropToFill {
                    Text("The visible center crop is what the exported image keeps; outside edges are discarded.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("No crop. Width / Height / Long Edge can look identical in framing because they only change pixel resolution.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text(rendered == nil ? (failed ? "Rendered preview unavailable · showing source thumbnail" : "Preparing color-managed preview") : "Live output look and crop · mockup chrome is not exported · print views are layout simulations, not paper/ICC soft proofs")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { chooseMockupForOutput() }
        .onChange(of: settings.resizeMode) { _, _ in chooseMockupForOutput() }
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
        let ratio = Double(max(1, settings.resizeWidth)) / Double(max(1, settings.resizeHeight))
        if ratio < 0.67 { mockup = .story }
        else if ratio > 1.72 { mockup = .video }
        else if ratio > 1.45 { mockup = .browser }
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
            let width = max(1, min(maxW, maxH * frameRatio))
            let height = max(1, width / max(0.01, frameRatio))
            content
                .aspectRatio(frameRatio, contentMode: crop ? .fill : .fit)
                .frame(width: width, height: height)
                .clipped()
                .background(Color.black)
                .overlay { Rectangle().stroke(.white.opacity(0.13), lineWidth: 1) }
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }


    // Layout proof: controls share the same output dimensions; no mockup invents a crop.
    private var actualFileMockup: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.025))
                // Display target constraint only. Fit Inside exports no matte/padding.
                if settings.resizeMode == .fitBox || settings.resizeMode == .cropToFill {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(.yellow.opacity(0.65), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                        .aspectRatio(constraintRatio, contentMode: .fit)
                        .frame(maxWidth: geo.size.width * 0.86, maxHeight: geo.size.height * 0.78)
                }
                picture
                    .frame(maxWidth: geo.size.width * 0.83, maxHeight: geo.size.height * 0.74)
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: crop ? "crop.rotate" : "photo")
                        Text(settings.resizeMode.rawValue)
                        Spacer()
                        Text("\(outputGeometry.width) × \(outputGeometry.height)")
                    }
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.black.opacity(0.64), in: Capsule())
                    .padding(9)
                }
            }
        }
    }

    private var storyMockup: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 26).fill(Color(red: 0.06, green: 0.065, blue: 0.075))
                picture
                    .frame(width: max(1, geo.size.width - 12), height: max(1, geo.size.height - 18))
                    .clipped()
                VStack(spacing: 8) {
                    HStack(spacing: 4) {
                        ForEach(0..<4, id: \.self) { _ in Capsule().fill(.white.opacity(0.7)).frame(height: 3) }
                    }
                    HStack(spacing: 7) {
                        Circle().fill(.white.opacity(0.75)).frame(width: 24, height: 24)
                        Text("studio.story").font(.caption2.weight(.medium))
                        Spacer()
                        Image(systemName: "xmark")
                    }
                    Spacer()
                    HStack {
                        Text("Reply…").padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(Capsule().stroke(.white.opacity(0.7)))
                        Image(systemName: "heart")
                    }.font(.caption2)
                }
                .foregroundStyle(.white)
                .padding(17)
            }
            .clipShape(RoundedRectangle(cornerRadius: 26))
            .overlay(RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.32), lineWidth: 2))
        }
        .aspectRatio(9.0 / 19.5, contentMode: .fit)
    }

    private var videoMockup: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "play.rectangle.fill").foregroundStyle(.red)
                Text("Video / Thumbnail · 16:9 viewport").font(.caption2)
                Spacer()
            }.padding(10)
            picture
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay(alignment: .bottomLeading) {
                    Text("PREVIEW").font(.caption2.weight(.heavy)).padding(6)
                        .background(.black.opacity(0.65)).padding(12)
                }
        }
        .foregroundStyle(.white)
        .background(Color(red: 0.10, green: 0.11, blue: 0.13), in: RoundedRectangle(cornerRadius: 12))
        .aspectRatio(1.55, contentMode: .fit)
    }

    private var portfolioMockup: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("PORTFOLIO").font(.system(.caption, design: .serif).weight(.semibold))
                    Spacer()
                    Text("WORK     ABOUT     CONTACT").font(.system(size: 9, weight: .medium))
                }
                HStack(spacing: 8) {
                    picture
                    VStack(spacing: 8) {
                        picture.opacity(0.7)
                        picture.opacity(0.6)
                    }
                    .frame(width: geo.size.width * 0.27)
                }
                Text("SELECTED WORK  /  01").font(.caption2.monospaced())
            }.padding(14).foregroundStyle(.white.opacity(0.85))
        }
        .background(Color(red: 0.08, green: 0.09, blue: 0.10), in: RoundedRectangle(cornerRadius: 12))
        .aspectRatio(1.5, contentMode: .fit)
    }

    private var contactSheetMockup: some View {
        VStack(spacing: 8) {
            HStack {
                Text("PROOF CONTACT SHEET").font(.caption2.weight(.semibold))
                Spacer()
                Text("01 / 09").font(.caption2.monospaced())
            }.foregroundStyle(.black.opacity(0.7))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 3), spacing: 7) {
                ForEach(0..<9, id: \.self) { index in
                    VStack(spacing: 3) {
                        picture.frame(height: 62)
                        Text(String(format: "%02d", index + 1)).font(.system(size: 8, design: .monospaced))
                    }
                }
            }
        }
        .padding(16)
        .background(Color(red: 0.95, green: 0.94, blue: 0.91))
        .aspectRatio(1.25, contentMode: .fit)
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
                    .applyingFilmExposureShape(renderLook.filmTone)
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
