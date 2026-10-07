import Foundation
import Accelerate

extension PixelBufferF32 {
    func resizedForExport(settings: ExportSettings) throws -> PixelBufferF32 {
        let sourceW = max(1, width)
        let sourceH = max(1, height)

        let target: (Int, Int)?
        switch settings.resizeMode {
        case .none:
            target = nil
        case .longEdge:
            let edge = max(1, settings.resizeLongEdge)
            let scale = Double(edge) / Double(max(sourceW, sourceH))
            target = (max(1, Int((Double(sourceW) * scale).rounded())),
                      max(1, Int((Double(sourceH) * scale).rounded())))
        case .width:
            let w = max(1, settings.resizeWidth)
            let scale = Double(w) / Double(sourceW)
            target = (w, max(1, Int((Double(sourceH) * scale).rounded())))
        case .height:
            let h = max(1, settings.resizeHeight)
            let scale = Double(h) / Double(sourceH)
            target = (max(1, Int((Double(sourceW) * scale).rounded())), h)
        case .cropToFill:
            // Crop before resize. Image-space center crop matches the Studio Export Viewer.
            // Aspect and output pixel size follow the user's chosen preset exactly.
            let wantedW = max(1, settings.resizeWidth)
            let wantedH = max(1, settings.resizeHeight)
            let ratio = Double(wantedW) / Double(wantedH)
            let cropW: Int
            let cropH: Int
            if Double(sourceW)/Double(sourceH) > ratio {
                cropW = max(1, min(sourceW, Int((Double(sourceH)*ratio).rounded())))
                cropH = sourceH
            } else {
                cropW = sourceW
                cropH = max(1, min(sourceH, Int((Double(sourceW)/ratio).rounded())))
            }
            let startX = (sourceW-cropW)/2, startY = (sourceH-cropH)/2
            let scale = settings.dontEnlarge ? min(1.0, min(Double(wantedW)/Double(cropW), Double(wantedH)/Double(cropH))) : 1.0
            let outputW = max(1, Int((Double(wantedW)*scale).rounded()))
            let outputH = max(1, Int((Double(wantedH)*scale).rounded()))
            // Pass an ROI into vImage directly: no second full-resolution crop allocation.
            // The output dimensions are EXACT for default social presets (no upscale limit).
            var result=[Float](repeating:0,count:outputW*outputH*4)
            let err:vImage_Error = pixels.withUnsafeBytes { sourceBytes in
                result.withUnsafeMutableBytes { targetBytes in
                    guard let start=sourceBytes.baseAddress, let dst=targetBytes.baseAddress else {
                        return vImage_Error(kvImageNullPointerArgument)
                    }
                    let byteOffset = ((startY*sourceW)+startX)*4*MemoryLayout<Float>.size
                    var roi=vImage_Buffer(
                        data:UnsafeMutableRawPointer(mutating:start.advanced(by:byteOffset)),
                        height:vImagePixelCount(cropH),width:vImagePixelCount(cropW),
                        rowBytes:sourceW*4*MemoryLayout<Float>.size)
                    var target=vImage_Buffer(
                        data:dst,height:vImagePixelCount(outputH),width:vImagePixelCount(outputW),
                        rowBytes:outputW*4*MemoryLayout<Float>.size)
                    return vImageScale_ARGBFFFF(&roi,&target,nil,vImage_Flags(kvImageHighQualityResampling))
                }
            }
            guard err == kvImageNoError else {
                throw NSError(domain:"SpektraFilmStudio.CropExport", code:Int(err),
                    userInfo:[NSLocalizedDescriptionKey:"Crop-to-fill vImage resize failed (\(err))"])
            }
            return PixelBufferF32(width:outputW,height:outputH,pixels:result)
        case .fitBox:
            let maxW = max(1, settings.resizeWidth)
            let maxH = max(1, settings.resizeHeight)
            let scale = min(Double(maxW) / Double(sourceW), Double(maxH) / Double(sourceH))
            target = (max(1, Int((Double(sourceW) * scale).rounded())),
                      max(1, Int((Double(sourceH) * scale).rounded())))
        }

        guard var (targetW, targetH) = target else { return self }
        if settings.dontEnlarge && targetW >= sourceW && targetH >= sourceH { return self }
        if settings.dontEnlarge {
            let scale = min(1.0, min(Double(targetW) / Double(sourceW), Double(targetH) / Double(sourceH)))
            targetW = max(1, Int((Double(sourceW) * scale).rounded()))
            targetH = max(1, Int((Double(sourceH) * scale).rounded()))
        }
        guard targetW != sourceW || targetH != sourceH else { return self }

        var destination = [Float](repeating: 0, count: targetW * targetH * 4)
        let error: vImage_Error = pixels.withUnsafeBytes { sourceBytes in
            destination.withUnsafeMutableBytes { destinationBytes in
                guard let sourceBase = sourceBytes.baseAddress,
                      let destinationBase = destinationBytes.baseAddress else {
                    return vImage_Error(kvImageNullPointerArgument)
                }
                var source = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: sourceBase),
                    height: vImagePixelCount(sourceH),
                    width: vImagePixelCount(sourceW),
                    rowBytes: sourceW * 4 * MemoryLayout<Float>.size
                )
                var output = vImage_Buffer(
                    data: destinationBase,
                    height: vImagePixelCount(targetH),
                    width: vImagePixelCount(targetW),
                    rowBytes: targetW * 4 * MemoryLayout<Float>.size
                )
                return vImageScale_ARGBFFFF(&source, &output, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        guard error == kvImageNoError else {
            throw NSError(
                domain: "SpektraFilmFast.ExportResize",
                code: Int(error),
                userInfo: [NSLocalizedDescriptionKey: "Export resize failed (vImage \(error))."]
            )
        }
        return PixelBufferF32(width: targetW, height: targetH, pixels: destination)
    }
}
