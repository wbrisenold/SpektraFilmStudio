import Foundation

enum DisplayMonitorSignal {
    static func code(_ value: Float, outputSpace: Int) -> Float {
        let v = max(0, min(1, value))
        if outputSpace == 14 || outputSpace == 15 || outputSpace == 16 {
            if v < 0.018 { return 4.5 * v }
            return Float(1.099 * pow(Double(v), 0.45) - 0.099)
        }
        return v
    }

    static func rgb(r: Float, g: Float, b: Float, look: RenderLook) -> (Float, Float, Float) {
        // Reuse the already-validated SDR output/profile conversion; do not infer
        // sRGB merely from a gamma-coded channel. This is the same pipeline as skin.
        if let display = SkinToneReference.canonicalDisplayRGB(r: r, g: g, b: b, look: look) {
            return display
        }
        // Some non-display renderer roles cannot be mapped to a 0..1 monitor.
        // Retain a bounded fallback so legacy scopes remain visible, but they are
        // not calibration references outside SkinToneReference.supported roles.
        let space = Int(look.values["outputColorSpace"]?.intValue ?? 25)
        return (code(r, outputSpace: space), code(g, outputSpace: space), code(b, outputSpace: space))
    }

    static func luma(r: Float, g: Float, b: Float, look: RenderLook) -> Float {
        let m = rgb(r: r, g: g, b: b, look: look)
        return 0.2126 * m.0 + 0.7152 * m.1 + 0.0722 * m.2
    }
}
