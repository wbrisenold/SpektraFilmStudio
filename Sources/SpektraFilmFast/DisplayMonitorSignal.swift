import Foundation

struct DisplayMonitorSample: Sendable {
    let r: Float
    let g: Float
    let b: Float
    let luma: Float
    let saturation: Float
    let peak: Float
    let floor: Float
    var falseColorHighlightRisk: Bool { luma >= 0.88 }
    var falseColorHighlightHard: Bool { luma >= 0.97 }
    var falseColorShadowRisk: Bool { luma <= 0.10 }
    var falseColorShadowHard: Bool { luma <= 0.03 }
}

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

    static func sample(r: Float, g: Float, b: Float, look: RenderLook) -> DisplayMonitorSample {
        let m = rgb(r: r, g: g, b: b, look: look)
        let peak = max(m.0, max(m.1, m.2))
        let floor = min(m.0, min(m.1, m.2))
        let luma = 0.2126 * m.0 + 0.7152 * m.1 + 0.0722 * m.2
        let saturation = peak > 1.0e-6 ? (peak - floor) / peak : 0
        return DisplayMonitorSample(r: m.0, g: m.1, b: m.2, luma: luma, saturation: saturation, peak: peak, floor: floor)
    }

    static func sampleDisplay(r: Float, g: Float, b: Float) -> DisplayMonitorSample {
        let peak = max(r, max(g, b))
        let floor = min(r, min(g, b))
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let saturation = peak > 1.0e-6 ? (peak - floor) / peak : 0
        return DisplayMonitorSample(r: r, g: g, b: b, luma: luma, saturation: saturation, peak: peak, floor: floor)
    }

    static func luma(r: Float, g: Float, b: Float, look: RenderLook) -> Float {
        sample(r: r, g: g, b: b, look: look).luma
    }
}
