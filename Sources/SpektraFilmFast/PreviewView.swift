import SwiftUI
import AppKit

struct PreviewView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var frameState: PreviewFrameState
    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero
    @State private var redlampCompositedFrame: CGImage?
    @State private var maskOverlayError: String?
    @AppStorage("SpektraFilmFast.redlampOverlayStyle") private var redlampStyle = RedlampMaskDisplayStyle.color.rawValue
    @AppStorage("SpektraFilmFast.maskOverlayEnabled") private var maskOverlayEnabled = true

    init(model: AppModel) {
        self.model = model
        _frameState = ObservedObject(wrappedValue: model.frameState)
    }

    var body: some View {
        GeometryReader { _ in
            ZStack {
                viewerBackground

                if let image = model.showingBefore ? frameState.sourcePreview :
                    (frameState.renderedPreview ??
                     (StudioImportedCubeLUTSettings.isSelected ? frameState.sourcePreview : nil)) {
                    ZStack {
                        // Redlamp-derived mask is composited in the image itself, not an
                        // independent translucent view whose size can drift after crop.
                        MetalPreviewCanvas(image: model.showingBefore ? image : (redlampCompositedFrame ?? image),
                            liveFrame: model.showingBefore ? nil : model.liveGPUFrame)
                            .aspectRatio(CGFloat(image.width) / CGFloat(max(1, image.height)), contentMode: .fit)
                            // Overlay follows exactly the displayed image's layout, not
                            // the size proposed by the outer viewer ZStack.
                            .overlay {
                                if !model.showingBefore {
                                    MaskOverlayView(model: model)
                                }
                            }
                            // Reflect the actually completed frame, not a setting.
                            // No extra CGImage renders or scope computations.
                            .overlay(alignment: .topLeading) {
                                if !model.showingBefore {
                                    Text(model.rendererPathStatus)
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(.regularMaterial, in: Capsule())
                                        .padding(10)
                                        .allowsHitTesting(false)
                                        .help(model.lutPreparationStatus)
                                }
                            }

                        if !model.showingBefore,
                           let overlay = model.analysisOverlay,
                           model.project.preferences.clippingEnabled || model.project.preferences.skinCheckEnabled {
                            Image(decorative: overlay, scale: 1)
                                .resizable()
                                .scaledToFit()
                                .allowsHitTesting(false)
                        }

                        if !model.showingBefore {
                            LensCharacterOverlay(model: model, imageWidth: image.width, imageHeight: image.height)
                        }

                        if !model.showingBefore, model.isObjectMaskPicking {
                            ObjectMaskPickOverlay(model: model, imageWidth: image.width, imageHeight: image.height)
                        }

                        if !model.showingBefore, model.isCropToolActive {
                            CropEditorOverlay(
                                model: model,
                                imageWidth: image.width,
                                imageHeight: image.height
                            )
                        }
                    }
                    .task(id: maskFrameKey(image)) {
                        redlampCompositedFrame = nil
                        maskOverlayError = nil
                        guard !model.showingBefore, maskOverlayEnabled,
                              let grade = model.activeLocalGrade,
                              !grade.masks.sources.isEmpty else { return }
                        // Never invent pre-geometry dimensions from a transformed CGImage.
                        guard let dims = model.maskSourceDimensions else {
                            maskOverlayError = "Waiting for untransformed mask source"
                            return
                        }
                        guard let bytes = RedlampMaskDisplay.rgbaBytes(image) else {
                            maskOverlayError = "Cannot read image pixels for mask overlay"
                            return
                        }
                        let expectedPhotoID = model.project.selectedImageID
                        let expectedGeometry = model.selectedLook.geometry
                        let geometry = expectedGeometry
                        let chosenStyle = RedlampMaskDisplayStyle(rawValue: redlampStyle) ?? .color
                        let width = image.width, height = image.height
                        let task = Task.detached(priority: .userInitiated) {
                            RedlampMaskDisplay.compose(
                                rgba: bytes, displayWidth: width, displayHeight: height,
                                grade: grade, preGeometryWidth: dims.width,
                                preGeometryHeight: dims.height, geometry: geometry,
                                style: chosenStyle
                            )
                        }
                        let output = await withTaskCancellationHandler {
                            await task.value
                        } onCancel: {
                            task.cancel()
                        }
                        guard !Task.isCancelled, model.activeLocalGradeID == grade.id,
                              model.project.selectedImageID == expectedPhotoID,
                              model.selectedLook.geometry == expectedGeometry else { return }
                        guard let output else {
                            maskOverlayError = "Mask overlay Metal/geometry evaluation failed"
                            return
                        }
                        guard let composed = RedlampMaskDisplay.image(
                            width: width, height: height, rgba: output,
                            colorSpace: image.colorSpace
                        ) else {
                            maskOverlayError = "Mask overlay display image could not be created"
                            return
                        }
                        redlampCompositedFrame = composed
                    }
                    .scaleEffect(zoom)
                    .offset(offset)
                    .gesture(
                        MagnifyGesture()
                            .onChanged { value in
                                zoom = max(0.1, min(16, committedZoom * value.magnification))
                            }
                            .onEnded { _ in committedZoom = zoom }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                guard !model.isCropToolActive && !model.isObjectMaskPicking && !model.isGradientMaskEditing && !model.isLensCenterEditing else { return }
                                offset = CGSize(
                                    width: committedOffset.width + value.translation.width,
                                    height: committedOffset.height + value.translation.height
                                )
                            }
                            .onEnded { _ in
                                guard !model.isCropToolActive && !model.isObjectMaskPicking && !model.isGradientMaskEditing && !model.isLensCenterEditing else { return }
                                committedOffset = offset
                            }
                    )
                    .onTapGesture(count: 2) { fit() }
                    .padding(22)
                } else {
                    ContentUnavailableView(
                        "No Preview",
                        systemImage: "photo",
                        description: Text("Select a photo in Library or the Photos tab.")
                    )
                }

                if !model.showingBefore && model.project.preferences.skinCheckEnabled {
                    skinOverlayLegend
                }

                if !model.showingBefore, let failure = maskOverlayError {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.top, 56)
                        .padding(.leading, 12)
                        .allowsHitTesting(false)
                }

                if frameState.isRendering {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.mini)
                        Text("Rendering")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(12)
                }

                viewerStatus
            }
            .clipped()
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomToolbar }
        }
    }

    private func maskFrameKey(_ image: CGImage) -> RedlampFrameToken {
        RedlampFrameToken(
            photoID: model.project.selectedImageID,
            frameID: ObjectIdentifier(image as AnyObject),
            maskID: model.activeLocalGradeID,
            revision: model.maskOverlayRevision,
            geometry: model.selectedLook.geometry,
            enabled: maskOverlayEnabled && !model.showingBefore,
            style: redlampStyle
        )
    }

    private var viewerBackground: some View {
        Group {
            if model.project.preferences.paperBackground {
                StudioPalette.recessed
            } else {
                Color.black
            }
        }
        .ignoresSafeArea()
    }


    private var skinOverlayLegend: some View {
        HStack(spacing: 10) {
            legendSwatch(Color(red: 44.0 / 255.0, green: 214.0 / 255.0, blue: 174.0 / 255.0), "TOO GREEN")
            legendSwatch(Color(red: 238.0 / 255.0, green: 184.0 / 255.0, blue: 72.0 / 255.0), "ON TARGET")
            legendSwatch(Color(red: 229.0 / 255.0, green: 65.0 / 255.0, blue: 177.0 / 255.0), "TOO MAGENTA")
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .allowsHitTesting(false)
    }

    private func legendSwatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(label)
        }
    }

    private var viewerStatus: some View {
        HStack(spacing: 6) {
            if model.showingBefore {
                Text("BEFORE")
                    .fontWeight(.semibold)
            } else if let image = frameState.renderedPreview {
                Text("Preview")
                Text("\(max(image.width, image.height)) px")
                    .monospacedDigit()
            }

            if model.project.preferences.clippingEnabled {
                Text("Exposure warning")
            }
            if model.project.preferences.skinCheckEnabled {
                Text(skinViewerStatusLabel)
                    .foregroundStyle(skinViewerStatusColor)
                    .fontWeight(.semibold)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(10)
        .padding(.bottom, 36)
    }

    private var skinViewerStatusLabel: String {
        let metrics = model.analysisMetrics
        guard metrics.skinCandidatePercent > 0.01, metrics.skinMeasurementConfidencePercent > 2 else {
            return "Skin · no reliable sample"
        }
        let tolerance = model.project.preferences.skinToleranceDegrees
        if metrics.skinMeanDeviationDegrees < -tolerance {
            return String(format: "Skin · TOO MAGENTA · push GREEN · %.0f%%", metrics.skinMagentaPercent)
        }
        if metrics.skinMeanDeviationDegrees > tolerance {
            return String(format: "Skin · TOO GREEN · push MAGENTA · %.0f%%", metrics.skinGreenPercent)
        }
        return String(format: "Skin · ON TARGET · %.0f%%", metrics.skinWithinTolerancePercent)
    }

    private var skinViewerStatusColor: Color {
        let metrics = model.analysisMetrics
        guard metrics.skinCandidatePercent > 0.01, metrics.skinMeasurementConfidencePercent > 2 else { return .secondary }
        let tolerance = model.project.preferences.skinToleranceDegrees
        if metrics.skinMeanDeviationDegrees < -tolerance { return Color(red: 0.86, green: 0.36, blue: 0.54) }
        if metrics.skinMeanDeviationDegrees > tolerance { return Color(red: 0.28, green: 0.72, blue: 0.50) }
        return Color(red: 0.90, green: 0.69, blue: 0.35)
    }

    private var bottomToolbar: some View {
        HStack(spacing: 6) {
            StudioIconButton(
                systemImage: "sidebar.left",
                help: model.isPresetSidebarVisible ? "Hide Presets" : "Show Presets",
                isSelected: model.isPresetSidebarVisible
            ) {
                model.isPresetSidebarVisible.toggle()
            }

            StudioIconButton(systemImage: "arrow.up.left.and.arrow.down.right", help: "Fit") {
                fit()
            }

            Button {
                model.showingBefore.toggle()
            } label: {
                Text(model.showingBefore ? "After" : "Before")
                    .frame(minWidth: 48)
            }
            .buttonStyle(.borderless)

            Divider().frame(height: 18)

            if model.activeLocalGradeID != nil {
                Button {
                    maskOverlayEnabled.toggle()
                } label: {
                    Label(maskOverlayEnabled ? "Overlay On" : "Overlay Off",
                          systemImage: maskOverlayEnabled ? "eye.fill" : "eye.slash")
                }
                .buttonStyle(.borderless)
                .help("Show or hide the active mask overlay on the photo")
                .keyboardShortcut("o", modifiers: [])
            }

            Button {
                if model.project.preferences.fullResolutionPreview {
                    model.project.preferences.fullResolutionPreview = false
                    model.requestPreviewRefresh()
                } else {
                    model.project.preferences.fullResolutionPreview = true
                    model.requestFullResolutionPreview()
                }
            } label: {
                Text(model.project.preferences.fullResolutionPreview ? "Exit 100% Check" : "100% Check")
            }
            .buttonStyle(.borderless)
            .help("Full-resolution inspection is explicit. Exit 100% Check to return to the configured exact preview resolution.")

            Spacer()

            if model.project.preferences.clippingEnabled {
                HStack(spacing: 5) {
                    Circle().fill(.red).frame(width: 6, height: 6)
                    Text(String(format: "Over %.1f%%", model.analysisMetrics.highlightPercent))
                    if model.analysisMetrics.hardHighlightPercent > 0 {
                        Text(String(format: "(%.1f%% hot)", model.analysisMetrics.hardHighlightPercent))
                    }
                    Circle().fill(.blue).frame(width: 6, height: 6)
                    Text(String(format: "Under %.1f%%", model.analysisMetrics.shadowPercent))
                    if model.analysisMetrics.hardShadowPercent > 0 {
                        Text(String(format: "(%.1f%% crushed)", model.analysisMetrics.hardShadowPercent))
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("Over/Under use the same final display-referred signal as False Color. Parentheses show the hottest / deepest subset.")
            }

            Text("\(Int(zoom * 100))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(StudioPalette.panel)
        .overlay(alignment: .top) { Divider().opacity(0.55) }
    }

    private func fit() {
        zoom = 1
        committedZoom = 1
        offset = .zero
        committedOffset = .zero
    }
}

private struct CropEditorOverlay: View {
    @ObservedObject var model: AppModel
    let imageWidth: Int
    let imageHeight: Int
    @State private var moveStart: NormalizedCropRect?
    @State private var resizeStart: NormalizedCropRect?

    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private var geometry: GeometrySettings { model.selectedLook.geometry ?? GeometrySettings() }

    var body: some View {
        GeometryReader { proxy in
            let fitted = fittedImageRect(in: proxy.size)
            let crop = geometry.crop
            let cropRect = CGRect(
                x: fitted.minX + CGFloat(crop.x) * fitted.width,
                y: fitted.minY + CGFloat(crop.y) * fitted.height,
                width: CGFloat(crop.width) * fitted.width,
                height: CGFloat(crop.height) * fitted.height
            )

            ZStack {
                Canvas { context, size in
                    drawShade(context: &context, imageRect: fitted, cropRect: cropRect)
                    drawGuides(context: &context, cropRect: cropRect, guide: geometry.overlayGuide)
                }
                .allowsHitTesting(false)

                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .frame(width: cropRect.width, height: cropRect.height)
                    .position(x: cropRect.midX, y: cropRect.midY)
                    .gesture(moveGesture(imageRect: fitted))
                    .help("Drag inside the crop to reframe the photo.")

                ForEach(Array(Handle.allCases.enumerated()), id: \.offset) { _, handle in
                    cropHandle(handle, cropRect: cropRect, imageRect: fitted)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .allowsHitTesting(true)
    }

    private func fittedImageRect(in size: CGSize) -> CGRect {
        guard imageWidth > 0, imageHeight > 0, size.width > 0, size.height > 0 else { return .zero }
        let scale = min(size.width / CGFloat(imageWidth), size.height / CGFloat(imageHeight))
        let width = CGFloat(imageWidth) * scale
        let height = CGFloat(imageHeight) * scale
        return CGRect(x: (size.width - width) * 0.5, y: (size.height - height) * 0.5, width: width, height: height)
    }

    private func moveGesture(imageRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if moveStart == nil {
                    moveStart = geometry.crop
                    model.beginEditGesture()
                }
                guard var start = moveStart, imageRect.width > 0, imageRect.height > 0 else { return }
                start.x += Double(value.translation.width / imageRect.width)
                start.y += Double(value.translation.height / imageRect.height)
                start.x = min(1 - start.width, max(0, start.x))
                start.y = min(1 - start.height, max(0, start.y))
                model.setGeometrySettings(interactive: true, changedParameter: "crop") { $0.crop = start }
            }
            .onEnded { _ in
                moveStart = nil
                model.endEditGesture()
            }
    }

    @ViewBuilder
    private func cropHandle(_ handle: Handle, cropRect: CGRect, imageRect: CGRect) -> some View {
        let point = handlePoint(handle, rect: cropRect)
        Circle()
            .fill(.white)
            .overlay { Circle().stroke(.black.opacity(0.72), lineWidth: 1) }
            .frame(width: handleIsCorner(handle) ? 11 : 9, height: handleIsCorner(handle) ? 11 : 9)
            .contentShape(Rectangle().inset(by: -8))
            .position(point)
            .gesture(resizeGesture(handle: handle, imageRect: imageRect))
            .help("Drag to resize the crop.")
    }

    private func resizeGesture(handle: Handle, imageRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if resizeStart == nil {
                    resizeStart = geometry.crop
                    model.beginEditGesture()
                }
                guard let start = resizeStart, imageRect.width > 0, imageRect.height > 0 else { return }
                let dx = Double(value.translation.width / imageRect.width)
                let dy = Double(value.translation.height / imageRect.height)
                var left = start.x, top = start.y
                var right = start.x + start.width, bottom = start.y + start.height
                switch handle {
                case .topLeft: left += dx; top += dy
                case .top: top += dy
                case .topRight: right += dx; top += dy
                case .right: right += dx
                case .bottomRight: right += dx; bottom += dy
                case .bottom: bottom += dy
                case .bottomLeft: left += dx; bottom += dy
                case .left: left += dx
                }
                let minSize = 0.02
                left = max(0, min(left, right - minSize))
                right = min(1, max(right, left + minSize))
                top = max(0, min(top, bottom - minSize))
                bottom = min(1, max(bottom, top + minSize))
                var updated = NormalizedCropRect(x: left, y: top, width: right - left, height: bottom - top)
                updated.clamp()
                model.setGeometrySettings(interactive: true, changedParameter: "crop") { $0.crop = updated }
            }
            .onEnded { _ in
                resizeStart = nil
                model.endEditGesture()
            }
    }

    private func handlePoint(_ handle: Handle, rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .top: CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    private func handleIsCorner(_ handle: Handle) -> Bool {
        switch handle {
        case .topLeft, .topRight, .bottomRight, .bottomLeft: true
        default: false
        }
    }

    private func drawShade(context: inout GraphicsContext, imageRect: CGRect, cropRect: CGRect) {
        let shade = Color.black.opacity(0.58)
        context.fill(Path(CGRect(x: imageRect.minX, y: imageRect.minY, width: imageRect.width, height: max(0, cropRect.minY - imageRect.minY))), with: .color(shade))
        context.fill(Path(CGRect(x: imageRect.minX, y: cropRect.maxY, width: imageRect.width, height: max(0, imageRect.maxY - cropRect.maxY))), with: .color(shade))
        context.fill(Path(CGRect(x: imageRect.minX, y: cropRect.minY, width: max(0, cropRect.minX - imageRect.minX), height: cropRect.height)), with: .color(shade))
        context.fill(Path(CGRect(x: cropRect.maxX, y: cropRect.minY, width: max(0, imageRect.maxX - cropRect.maxX), height: cropRect.height)), with: .color(shade))
        context.stroke(Path(cropRect), with: .color(.white.opacity(0.92)), lineWidth: 1.1)
    }

    private func drawGuides(context: inout GraphicsContext, cropRect: CGRect, guide: CropOverlayGuide) {
        guard cropRect.width > 0, cropRect.height > 0, guide != .none else { return }
        var lines = Path()
        func vertical(_ fraction: CGFloat) {
            let x = cropRect.minX + cropRect.width * fraction
            lines.move(to: CGPoint(x: x, y: cropRect.minY)); lines.addLine(to: CGPoint(x: x, y: cropRect.maxY))
        }
        func horizontal(_ fraction: CGFloat) {
            let y = cropRect.minY + cropRect.height * fraction
            lines.move(to: CGPoint(x: cropRect.minX, y: y)); lines.addLine(to: CGPoint(x: cropRect.maxX, y: y))
        }
        switch guide {
        case .thirds:
            vertical(1/3); vertical(2/3); horizontal(1/3); horizontal(2/3)
        case .golden:
            vertical(0.382); vertical(0.618); horizontal(0.382); horizontal(0.618)
        case .center:
            vertical(0.5); horizontal(0.5)
        case .safeAreas:
            let outer = cropRect.insetBy(dx: cropRect.width * 0.05, dy: cropRect.height * 0.05)
            let inner = cropRect.insetBy(dx: cropRect.width * 0.10, dy: cropRect.height * 0.10)
            lines.addRect(outer); lines.addRect(inner)
        case .diagonal:
            lines.move(to: CGPoint(x: cropRect.minX, y: cropRect.minY)); lines.addLine(to: CGPoint(x: cropRect.maxX, y: cropRect.maxY))
            lines.move(to: CGPoint(x: cropRect.maxX, y: cropRect.minY)); lines.addLine(to: CGPoint(x: cropRect.minX, y: cropRect.maxY))
        case .none:
            break
        }
        context.stroke(lines, with: .color(.white.opacity(0.48)), lineWidth: 0.7)
    }
}

private struct RedlampFrameToken: Hashable {
    let photoID: UUID?
    let frameID: ObjectIdentifier
    let maskID: UUID?
    let revision: Int
    let geometry: GeometrySettings?
    let enabled: Bool
    let style: String
}
