import Foundation

/// Mirrors ExportResize.swift dimension decisions, without allocating pixels.
/// Input dimensions must be the post-geometry image dimensions, not the camera RAW dimensions.
struct StudioOutputGeometry: Equatable, Sendable {
    let width: Int
    let height: Int

    static func calculate(sourceWidth: Int, sourceHeight: Int, mode: ExportResizeMode,
                          width: Int, height: Int, longEdge: Int, dontEnlarge: Bool) -> Self {
        let sw = max(1, sourceWidth), sh = max(1, sourceHeight)
        let w = max(1, width), h = max(1, height), edge = max(1, longEdge)
        if mode == .none { return .init(width: sw, height: sh) }
        if mode == .cropToFill {
            let aspect = Double(w) / Double(h)
            let cw: Int, ch: Int
            if Double(sw) / Double(sh) > aspect {
                cw = max(1, min(sw, Int((Double(sh) * aspect).rounded())))
                ch = sh
            } else {
                cw = sw
                ch = max(1, min(sh, Int((Double(sw) / aspect).rounded())))
            }
            let factor = dontEnlarge ? min(1, min(Double(cw) / Double(w), Double(ch) / Double(h))) : 1.0
            return .init(width: max(1, Int((Double(w) * factor).rounded())),
                         height: max(1, Int((Double(h) * factor).rounded())))
        }
        let ratio: Double
        switch mode {
        case .none, .cropToFill: ratio = 1 // handled above
        case .longEdge: ratio = Double(edge) / Double(max(sw, sh))
        case .width: ratio = Double(w) / Double(sw)
        case .height: ratio = Double(h) / Double(sh)
        case .fitBox: ratio = min(Double(w) / Double(sw), Double(h) / Double(sh))
        }
        // Exact export first rounds the requested target and then applies no-upscale logic.
        var tw = mode == .width ? w : max(1, Int((Double(sw) * ratio).rounded()))
        var th = mode == .height ? h : max(1, Int((Double(sh) * ratio).rounded()))
        if dontEnlarge && tw >= sw && th >= sh { return .init(width: sw, height: sh) }
        if dontEnlarge {
            let factor = min(1, min(Double(tw) / Double(sw), Double(th) / Double(sh)))
            tw = max(1, Int((Double(sw) * factor).rounded()))
            th = max(1, Int((Double(sh) * factor).rounded()))
        }
        return .init(width: tw, height: th)
    }
}
