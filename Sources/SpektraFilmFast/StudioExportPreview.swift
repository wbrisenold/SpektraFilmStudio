import SwiftUI
import AppKit

/// Export preview that mirrors export framing without device/mockup distortion.
/// It intentionally shows the file geometry only: no phone/feed/print chrome and no
/// independent aspect-ratio simulation capable of disagreeing with ExportResize.swift.
struct StudioExportPreview: View {
    @ObservedObject var model: AppModel
    let image: ProjectImageRecord

    @State private var rendered: CGImage?
    @State private var rendering = false
    @State private var failed = false

    private var settings: ExportSettings { model.project.exportSettings }

    private var sourceWidth: Int {
        max(1, rendered?.width ?? image.metadata?.pixelWidth ?? 1500)
    }

    private var sourceHeight: Int {
        max(1, rendered?.height ?? image.metadata?.pixelHeight ?? 1000)
    }

    private var outputGeometry: StudioOutputGeometry {
        StudioOutputGeometry.calculate(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            mode: settings.resizeMode,
            width: settings.resizeWidth,
            height: settings.resizeHeight,
            longEdge: settings.resizeLongEdge,
            dontEnlarge: settings.dontEnlarge
        )
    }

    private var displayImage: CGImage? {
        guard let rendered else { return nil }
        guard settings.resizeMode == .cropToFill else { return rendered }
        let rect = StudioOutputGeometry.centerCropRect(
            sourceWidth: rendered.width,
            sourceHeight: rendered.height,
            targetWidth: max(1, settings.resizeWidth),
            targetHeight: max(1, settings.resizeHeight)
        )
        return rendered.cropping(to: rect) ?? rendered
    }

    private var framingTitle: String {
        switch settings.resizeMode {
        case .cropToFill: "FILL TARGET · CROP EDGES"
        case .fitBox: "FIT WHOLE PHOTO · NO CROP"
        case .none: "FULL SIZE · NO CROP"
        case .longEdge: "LONG EDGE · NO CROP"
        case .width: "WIDTH · NO CROP"
        case .height: "HEIGHT · NO CROP"
        }
    }

    private var framingDetail: String {
        switch settings.resizeMode {
        case .cropToFill:
            "The preview is center-cropped with the same aspect calculation used by export. It is never stretched or squeezed."
        case .fitBox:
            "The entire photo is kept. The target is a maximum box; SpektraFilm does not add blank padding to the exported file."
        case .none:
            "The full rendered image is exported at source resolution."
        case .longEdge:
            "The longest side is resized and the photo's aspect ratio is preserved."
        case .width:
            "Width drives the resize and height follows the photo's aspect ratio."
        case .height:
            "Height drives the resize and width follows the photo's aspect ratio."
        }
    }

    private var token: String {
        "\(image.id)|\(image.look.hashValue)|\(settings.colorMode.rawValue)|\(model.rawDenoiseStatus)"
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ACTUAL EXPORT FRAMING")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(framingTitle)
                        .font(.caption.weight(.semibold))
                }
                Spacer()
                Text("\(outputGeometry.width) × \(outputGeometry.height)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                ZStack {
                    Color(red: 0.055, green: 0.061, blue: 0.073)

                    if let displayImage {
                        Image(decorative: displayImage, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(
                                maxWidth: proxy.size.width - 30,
                                maxHeight: proxy.size.height - 30
                            )
                            .overlay {
                                Rectangle().stroke(.white.opacity(0.14), lineWidth: 1)
                            }
                    } else if failed {
                        ContentUnavailableView(
                            "Preview unavailable",
                            systemImage: "photo.badge.exclamationmark",
                            description: Text("Export still uses the full-resolution renderer.")
                        )
                    } else {
                        ProgressView()
                    }

                    if rendering {
                        ProgressView()
                            .controlSize(.small)
                            .padding(8)
                            .background(.thinMaterial, in: Capsule())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(10)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .frame(minHeight: 280)

            VStack(alignment: .leading, spacing: 4) {
                Text(framingDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Preview uses the rendered 1080px working image for speed; crop geometry is resolution-independent and full export is rendered from the original source.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: token) {
            rendering = true
            rendered = nil
            failed = false
            if let result = await model.renderStudioExportPreview(for: image, colorMode: settings.colorMode) {
                guard !Task.isCancelled else { return }
                rendered = result
            } else if !Task.isCancelled {
                failed = true
            }
            rendering = false
        }
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
                url: effectiveSourceURL(for: image),
                longEdge: AppPreferences.editProxyLongEdge,
                raw: image.look.raw,
                bypassImportTransform: project.preferences.bypassImportTransform,
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
                ExposureBoundaryEngine.apply(
                    GeometryEngine.transformed(
                        LensCharacterEngine.apply(
                            MaskedLocalGradeEngine.apply(film, grades: renderLook.localGrades),
                            settings: renderLook.lensEffects
                        ),
                        settings: renderLook.geometry
                    ),
                    look: renderLook,
                    preferences: clipPrefs
                )
            }.value
            try Task.checkCancellation()
            let space = OutputColorProfile.forLook(look).cgColorSpace
            return output.makeFloatImagePayload()?.makeCGImage(colorSpace: space)
                ?? output.makeCGImage8(colorSpace: space)
        } catch {
            return nil
        }
    }
}
