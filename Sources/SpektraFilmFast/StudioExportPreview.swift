import SwiftUI
import AppKit

struct StudioExportPreview: View {
    @ObservedObject var model: AppModel
    let image: ProjectImageRecord
    @State private var rendered: CGImage?
    @State private var rendering = false
    @State private var failed = false

    private var settings: ExportSettings { model.project.exportSettings }
    private var sourceWidth: Int { max(1, rendered?.width ?? image.metadata?.pixelWidth ?? 1500) }
    private var sourceHeight: Int { max(1, rendered?.height ?? image.metadata?.pixelHeight ?? 1000) }
    private var outputGeometry: StudioOutputGeometry {
        .calculate(sourceWidth:sourceWidth,sourceHeight:sourceHeight,mode:settings.resizeMode,
                   width:settings.resizeWidth,height:settings.resizeHeight,longEdge:settings.resizeLongEdge,
                   dontEnlarge:settings.dontEnlarge)
    }
    private var targetRatio: CGFloat {
        switch settings.resizeMode {
        case .fitBox, .cropToFill:
            CGFloat(max(1,settings.resizeWidth))/CGFloat(max(1,settings.resizeHeight))
        default:
            CGFloat(outputGeometry.width)/CGFloat(max(1,outputGeometry.height))
        }
    }
    private var displayImage: CGImage? {
        guard let rendered else { return nil }
        guard settings.resizeMode == .cropToFill else { return rendered }
        let rect=StudioOutputGeometry.centerCropRect(sourceWidth:rendered.width,sourceHeight:rendered.height,
                                                     targetWidth:max(1,settings.resizeWidth),targetHeight:max(1,settings.resizeHeight))
        return rendered.cropping(to:rect) ?? rendered
    }
    private var token:String {
        "\(image.id)|\(image.look.hashValue)|\(settings.colorMode.rawValue)|\(settings.resizeMode.rawValue)|\(settings.resizeWidth)x\(settings.resizeHeight)|\(settings.resizeLongEdge)|\(settings.dontEnlarge)|\(model.rawDenoiseStatus)"
    }

    var body: some View {
        VStack(spacing:10) {
            HStack {
                VStack(alignment:.leading,spacing:2) {
                    Text("OUTPUT PREVIEW").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(modeTitle).font(.caption.weight(.semibold))
                }
                Spacer()
                VStack(alignment:.trailing,spacing:1) {
                    Text("\(outputGeometry.width) × \(outputGeometry.height) px").font(.caption.monospacedDigit())
                    if settings.resizeMode == .fitBox || settings.resizeMode == .cropToFill {
                        Text("TARGET \(settings.resizeWidth) × \(settings.resizeHeight)")
                            .font(.system(size:9,weight:.semibold,design:.monospaced)).foregroundStyle(.secondary)
                    }
                }
            }

            GeometryReader { proxy in
                ZStack {
                    Color(red:0.055,green:0.061,blue:0.073)
                    if let displayImage {
                        if settings.resizeMode == .fitBox || settings.resizeMode == .cropToFill {
                            ZStack {
                                RoundedRectangle(cornerRadius:4).fill(Color.white.opacity(0.018))
                                    .overlay {
                                        RoundedRectangle(cornerRadius:4)
                                            .stroke(Color.yellow.opacity(0.72),style:StrokeStyle(lineWidth:1,dash:[6,4]))
                                    }
                                    .aspectRatio(targetRatio,contentMode:.fit)
                                    .frame(maxWidth:proxy.size.width-34,maxHeight:proxy.size.height-34)

                                Image(decorative:displayImage,scale:1)
                                    .resizable()
                                    .aspectRatio(contentMode:settings.resizeMode == .cropToFill ? .fill : .fit)
                                    .aspectRatio(targetRatio,contentMode:.fit)
                                    .frame(maxWidth:proxy.size.width-34,maxHeight:proxy.size.height-34)
                                    .clipped()
                            }
                        } else {
                            Image(decorative:displayImage,scale:1).resizable().aspectRatio(contentMode:.fit)
                                .frame(maxWidth:proxy.size.width-34,maxHeight:proxy.size.height-34)
                        }
                    } else if failed {
                        ContentUnavailableView("Preview unavailable",systemImage:"photo.badge.exclamationmark")
                    } else { ProgressView() }

                    if rendering {
                        ProgressView().controlSize(.small).padding(8)
                            .background(.thinMaterial,in:Capsule())
                            .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topTrailing).padding(10)
                    }
                }.clipShape(RoundedRectangle(cornerRadius:12))
            }.frame(minHeight:280)

            Text(detailText).font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth:.infinity,alignment:.leading)
        }
        .task(id:token) {
            rendering=true; failed=false
            if let result=await model.renderStudioExportPreview(for:image,colorMode:settings.colorMode) {
                guard !Task.isCancelled else { return }
                rendered=result
            } else if !Task.isCancelled { failed=true }
            rendering=false
        }
    }

    private var modeTitle:String {
        switch settings.resizeMode {
        case .cropToFill:"FILL TARGET · CROP EDGES"
        case .fitBox:"FIT WHOLE PHOTO · NO CROP"
        case .none:"FULL SIZE · NO CROP"
        case .longEdge:"LONG EDGE · NO CROP"
        case .width:"WIDTH · NO CROP"
        case .height:"HEIGHT · NO CROP"
        }
    }
    private var detailText:String {
        switch settings.resizeMode {
        case .cropToFill:"Yellow frame is the exact target aspect. The image shown is the same center crop used by export. No stretching."
        case .fitBox:"Yellow frame is only the target constraint. The whole photo is exported; empty viewer area is not written to the file."
        case .none:"Full rendered dimensions and framing."
        case .longEdge:"Framing stays unchanged; only resolution changes."
        case .width:"Width changes resolution; height follows the photo aspect."
        case .height:"Height changes resolution; width follows the photo aspect."
        }
    }
}

@MainActor
extension AppModel {
    func renderStudioExportPreview(for image:ProjectImageRecord,colorMode:ExportColorMode) async -> CGImage? {
        guard !isExporting,let activeRenderer=exactRenderer else{return nil}
        do {
            var look=image.look
            if colorMode == .sRGB { look.values["outputColorSpace"] = .int(17); look.values["outputRole"] = .int(0) }
            let base=try await decoder.decode(url:effectiveSourceURL(for:image),longEdge:AppPreferences.editProxyLongEdge,
                raw:look.raw,bypassImportTransform:project.preferences.bypassImportTransform,cacheMode:cacheMemoryMode)
            let graded=await Task.detached(priority:.utility) {
                base.applyingHostGrade(tone:look.tone,density:look.colorDensity).applyingFilmExposureShape(look.filmTone)
            }.value
            let (film,_)=try await activeRenderer.render(graded,look:look)
            let prefs=project.preferences
            let output=await Task.detached(priority:.utility) {
                ExposureBoundaryEngine.apply(
                    GeometryEngine.transformed(
                        LensCharacterEngine.apply(MaskedLocalGradeEngine.apply(film,grades:look.localGrades),settings:look.lensEffects),
                        settings:look.geometry),look:look,preferences:prefs)
            }.value
            let space=OutputColorProfile.forLook(look).cgColorSpace
            return output.makeFloatImagePayload()?.makeCGImage(colorSpace:space) ?? output.makeCGImage8(colorSpace:space)
        } catch { return nil }
    }
}
