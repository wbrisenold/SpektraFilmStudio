import Foundation

extension PixelBufferF32 {
    func resizedForExport(settings: ExportSettings) throws -> PixelBufferF32 {
        guard width > 0, height > 0, width <= 16384, height <= 16384 else {
            throw MetalExportResizer.ScaleError.oversized
        }
        if settings.resizeMode != .none {
            guard (1...16384).contains(settings.resizeWidth),
                  (1...16384).contains(settings.resizeHeight),
                  (1...16384).contains(settings.resizeLongEdge) else {
                throw MetalExportResizer.ScaleError.oversized
            }
        }
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
            let scale = settings.dontEnlarge ? min(1.0, min(Double(cropW)/Double(wantedW), Double(cropH)/Double(wantedH))) : 1.0
            let outputW = max(1, Int((Double(wantedW)*scale).rounded()))
            let outputH = max(1, Int((Double(wantedH)*scale).rounded()))
            return try MetalExportResizer.shared.resized(
                self, cropX: startX, cropY: startY,
                cropWidth: cropW, cropHeight: cropH,
                width: outputW, height: outputH
            )
        case .fitBox:
            let maxW = max(1, settings.resizeWidth)
            let maxH = max(1, settings.resizeHeight)
            let scale = min(Double(maxW) / Double(sourceW), Double(maxH) / Double(sourceH))
            target = (max(1, Int((Double(sourceW) * scale).rounded())),
                      max(1, Int((Double(sourceH) * scale).rounded())))
        }

        guard let (targetW, targetH) = target else { return self }
        if settings.dontEnlarge && targetW >= sourceW && targetH >= sourceH { return self }
        // Targets already preserve aspect ratio and are rounded once above.
        // Recomputing scale from the rounded short edge shrinks the requested long edge.
        guard targetW != sourceW || targetH != sourceH else { return self }

        return try MetalExportResizer.shared.resized(self, width: targetW, height: targetH)
    }
}
