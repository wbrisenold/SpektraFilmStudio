import Foundation
import CoreGraphics

/// Mirrors ExportResize.swift dimension and center-crop decisions without allocating pixels.
struct StudioOutputGeometry: Equatable, Sendable {
    let width: Int
    let height: Int

    static func centerCropRect(
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Int,
        targetHeight: Int
    ) -> CGRect {
        let sw = min(16384, max(1, sourceWidth))
        let sh = min(16384, max(1, sourceHeight))
        let tw = min(16384, max(1, targetWidth))
        let th = min(16384, max(1, targetHeight))
        let targetRatio = Double(tw) / Double(th)

        let cropW: Int
        let cropH: Int
        if Double(sw) / Double(sh) > targetRatio {
            cropW = max(1, min(sw, Int((Double(sh) * targetRatio).rounded())))
            cropH = sh
        } else {
            cropW = sw
            cropH = max(1, min(sh, Int((Double(sw) / targetRatio).rounded())))
        }

        return CGRect(
            x: (sw - cropW) / 2,
            y: (sh - cropH) / 2,
            width: cropW,
            height: cropH
        )
    }

    static func calculate(
        sourceWidth: Int,
        sourceHeight: Int,
        mode: ExportResizeMode,
        width: Int,
        height: Int,
        longEdge: Int,
        dontEnlarge: Bool
    ) -> Self {
        let sw = min(16384, max(1, sourceWidth))
        let sh = min(16384, max(1, sourceHeight))
        let w = min(16384, max(1, width))
        let h = min(16384, max(1, height))
        let edge = min(16384, max(1, longEdge))

        if mode == .none {
            return .init(width: sw, height: sh)
        }

        if mode == .cropToFill {
            let crop = centerCropRect(
                sourceWidth: sw,
                sourceHeight: sh,
                targetWidth: w,
                targetHeight: h
            )
            let cw = Int(crop.width)
            let ch = Int(crop.height)
            let factor = dontEnlarge
                ? min(1, min(Double(cw) / Double(w), Double(ch) / Double(h)))
                : 1.0
            return .init(
                width: max(1, Int((Double(w) * factor).rounded())),
                height: max(1, Int((Double(h) * factor).rounded()))
            )
        }

        let ratio: Double
        switch mode {
        case .none, .cropToFill:
            ratio = 1
        case .longEdge:
            ratio = Double(edge) / Double(max(sw, sh))
        case .width:
            ratio = Double(w) / Double(sw)
        case .height:
            ratio = Double(h) / Double(sh)
        case .fitBox:
            ratio = min(Double(w) / Double(sw), Double(h) / Double(sh))
        }

        var tw = mode == .width ? w : max(1, Int((Double(sw) * ratio).rounded()))
        var th = mode == .height ? h : max(1, Int((Double(sh) * ratio).rounded()))

        if dontEnlarge && tw >= sw && th >= sh {
            return .init(width: sw, height: sh)
        }
        if dontEnlarge {
            let factor = min(1, min(Double(tw) / Double(sw), Double(th) / Double(sh)))
            tw = max(1, Int((Double(sw) * factor).rounded()))
            th = max(1, Int((Double(sh) * factor).rounded()))
        }
        return .init(width: tw, height: th)
    }
}
