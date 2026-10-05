import Foundation

struct SkinChromaPosition: Sendable {
    let uNormalized: Float
    let vNormalized: Float
    let radius: Float
    let angleDegrees: Double
    let luma: Float
}

enum DiagnosticColorError: LocalizedError {
    case unsupportedOutputSpace(Int)
    case unsupportedOutputRole(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedOutputSpace(let index):
            return "Skin diagnostics are not calibrated for output color-space index \(index). Use sRGB, Display P3, Linear Rec.709/2020/P3, P3-D65 Gamma, Adobe RGB, or Rec.709 Gamma."
        case .unsupportedOutputRole(let role):
            return "Skin diagnostics require the SDR display-output role. Current output role is \(role)."
        }
    }
}

/// Canonical skin diagnostic math.
///
/// Reference behavior is based on the open-source ScopeWalker vectorscope (CC0):
/// Y = .299R + .587G + .114B, U = (B-Y)*.492, V = (R-Y)*.877.
/// ScopeWalker derives the flesh/skin line from RGB(255, 200, 160) rather than mixing
/// a 123° constant with a different YCbCr basis. SpektraFilm follows that same rule so
/// the measured cluster, skin line, correction arrow, and Auto WB solver all share one
/// coordinate system.
///
/// Every supported renderer output is normalized to display-encoded sRGB before skin
/// classification/vector math. This prevents the old double-gamma path and prevents
/// P3/Rec.709 transfer choices from silently moving the diagnostic line.
enum SkinToneReference {
    private static let p3ToSRGB: [Double] = [
         1.224940176, -0.224940176,  0.0,
        -0.042056955,  1.042056955,  0.0,
        -0.019637555, -0.078636046,  1.098273601
    ]

    private static let rec2020ToXYZD65: [Double] = [
        0.6369580483, 0.1446169036, 0.1688809752,
        0.2627002120, 0.6779980715, 0.0593017165,
        0.0000000000, 0.0280726930, 1.0609850577
    ]

    private static let adobeToXYZD65: [Double] = [
        0.5767309, 0.1855540, 0.1881852,
        0.2973769, 0.6273491, 0.0752741,
        0.0270343, 0.0706872, 0.9911085
    ]

    private static let proPhotoToXYZD50: [Double] = [
        0.7976749, 0.1351917, 0.0313534,
        0.2880402, 0.7118741, 0.0000857,
        0.0000000, 0.0000000, 0.8252100
    ]

    private static let d50ToD65: [Double] = [
         0.9555766, -0.0230393, 0.0631636,
        -0.0282895,  1.0099416, 0.0210077,
         0.0122982, -0.0204830, 1.3299098
    ]

    private static let xyzD65ToSRGB: [Double] = [
         3.2404542, -1.5371385, -0.4985314,
        -0.9692660,  1.8760108,  0.0415560,
         0.0556434, -0.2040259,  1.0572252
    ]

    static let referenceAngleDegrees: Double = {
        position(displayR: 1.0, displayG: 200.0 / 255.0, displayB: 160.0 / 255.0).angleDegrees
    }()

    static func outputSpaceIndex(_ look: RenderLook) -> Int {
        Int(look.values["outputColorSpace"]?.intValue ?? 25)
    }

    static func outputRoleIndex(_ look: RenderLook) -> Int {
        Int(look.values["outputRole"]?.intValue ?? 0)
    }

    static func validate(_ look: RenderLook) throws {
        let role = outputRoleIndex(look)
        guard role == 0 else { throw DiagnosticColorError.unsupportedOutputRole(role) }
        let index = outputSpaceIndex(look)
        guard supportedOutputSpaces.contains(index) else {
            throw DiagnosticColorError.unsupportedOutputSpace(index)
        }
    }

    private static let supportedOutputSpaces: Set<Int> = [
        14, 15, 16, 17, 18, 19, 20, 22, 23, 24, 25
    ]

    static func canonicalLinearSRGBUnclamped(
        r: Float, g: Float, b: Float,
        look: RenderLook
    ) -> (Float, Float, Float)? {
        let role = outputRoleIndex(look)
        guard role == 0 else { return nil }

        let index = outputSpaceIndex(look)
        let rr = Double(r), gg = Double(g), bb = Double(b)
        let linearSRGB: (Double, Double, Double)

        switch index {
        case 14: // Linear Rec.2020
            linearSRGB = xyzToSRGB(mul(rec2020ToXYZD65, (rr, gg, bb)))
        case 15: // Linear Rec.709
            linearSRGB = (rr, gg, bb)
        case 16: // Linear P3-D65
            linearSRGB = mul(p3ToSRGB, (rr, gg, bb))
        case 17: // sRGB
            linearSRGB = (
                srgbDecode(rr),
                srgbDecode(gg),
                srgbDecode(bb)
            )
        case 18: // Display P3, sRGB transfer
            linearSRGB = mul(p3ToSRGB, (
                srgbDecode(rr), srgbDecode(gg), srgbDecode(bb)
            ))
        case 19: // ProPhoto RGB, D50
            let pro = (
                proPhotoDecode(rr), proPhotoDecode(gg), proPhotoDecode(bb)
            )
            let xyzD50 = mul(proPhotoToXYZD50, pro)
            let xyzD65 = mul(d50ToD65, xyzD50)
            linearSRGB = xyzToSRGB(xyzD65)
        case 20: // Adobe RGB (1998)
            let gamma = 563.0 / 256.0
            linearSRGB = xyzToSRGB(mul(adobeToXYZD65, (
                signedPowerDecode(rr, gamma),
                signedPowerDecode(gg, gamma),
                signedPowerDecode(bb, gamma)
            )))
        case 22: // P3-D65 Gamma 2.2
            linearSRGB = mul(p3ToSRGB, (
                signedPowerDecode(rr, 2.2),
                signedPowerDecode(gg, 2.2),
                signedPowerDecode(bb, 2.2)
            ))
        case 23: // P3-D65 Gamma 2.6
            linearSRGB = mul(p3ToSRGB, (
                signedPowerDecode(rr, 2.6),
                signedPowerDecode(gg, 2.6),
                signedPowerDecode(bb, 2.6)
            ))
        case 24: // Rec.709 Gamma 2.2
            linearSRGB = (
                signedPowerDecode(rr, 2.2),
                signedPowerDecode(gg, 2.2),
                signedPowerDecode(bb, 2.2)
            )
        case 25: // Rec.709 Gamma 2.4
            linearSRGB = (
                signedPowerDecode(rr, 2.4),
                signedPowerDecode(gg, 2.4),
                signedPowerDecode(bb, 2.4)
            )
        default:
            return nil
        }

        return (
            Float(linearSRGB.0),
            Float(linearSRGB.1),
            Float(linearSRGB.2)
        )
    }

    static func canonicalDisplayRGBUnclamped(
        r: Float, g: Float, b: Float,
        look: RenderLook
    ) -> (Float, Float, Float)? {
        guard let linear = canonicalLinearSRGBUnclamped(r: r, g: g, b: b, look: look) else {
            return nil
        }
        return (
            Float(srgbEncode(Double(linear.0))),
            Float(srgbEncode(Double(linear.1))),
            Float(srgbEncode(Double(linear.2)))
        )
    }

    static func canonicalDisplayRGB(
        r: Float, g: Float, b: Float,
        look: RenderLook
    ) -> (Float, Float, Float)? {
        guard let display = canonicalDisplayRGBUnclamped(r: r, g: g, b: b, look: look) else {
            return nil
        }
        return (
            clamp01(display.0),
            clamp01(display.1),
            clamp01(display.2)
        )
    }

    static func position(displayR: Float, displayG: Float, displayB: Float) -> SkinChromaPosition {
        let r = Double(displayR)
        let g = Double(displayG)
        let b = Double(displayB)
        let y = 0.299 * r + 0.587 * g + 0.114 * b
        let u = (b - y) * 0.492
        let v = (r - y) * 0.877

        let commonScale = 0.615
        let un = max(-1.0, min(1.0, u / commonScale))
        let vn = max(-1.0, min(1.0, v / commonScale))
        let radius = min(1.0, hypot(un, vn))
        var angle = atan2(v, u) * 180.0 / .pi
        if angle < 0 { angle += 360.0 }

        return SkinChromaPosition(
            uNormalized: Float(un),
            vNormalized: Float(vn),
            radius: Float(radius),
            angleDegrees: angle,
            luma: Float(y)
        )
    }

    static func angularDifferenceDegrees(_ lhs: Double, _ rhs: Double) -> Double {
        var delta = lhs - rhs
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }
        return delta
    }

    private static func xyzToSRGB(_ xyz: (Double, Double, Double)) -> (Double, Double, Double) {
        mul(xyzD65ToSRGB, xyz)
    }

    private static func mul(_ m: [Double], _ v: (Double, Double, Double)) -> (Double, Double, Double) {
        (
            m[0] * v.0 + m[1] * v.1 + m[2] * v.2,
            m[3] * v.0 + m[4] * v.1 + m[5] * v.2,
            m[6] * v.0 + m[7] * v.1 + m[8] * v.2
        )
    }

    private static func signedPowerDecode(_ x: Double, _ gamma: Double) -> Double {
        let sign = x < 0 ? -1.0 : 1.0
        return sign * pow(abs(x), gamma)
    }

    private static func srgbDecode(_ x: Double) -> Double {
        let sign = x < 0 ? -1.0 : 1.0
        let a = abs(x)
        if a <= 0.04045 { return sign * (a / 12.92) }
        return sign * pow((a + 0.055) / 1.055, 2.4)
    }

    private static func srgbEncode(_ x: Double) -> Double {
        let sign = x < 0 ? -1.0 : 1.0
        let a = abs(x)
        if a <= 0.0031308 { return sign * 12.92 * a }
        return sign * (1.055 * pow(a, 1.0 / 2.4) - 0.055)
    }

    private static func proPhotoDecode(_ x: Double) -> Double {
        let sign = x < 0 ? -1.0 : 1.0
        let a = abs(x)
        if a <= 16.0 / 512.0 { return sign * (a / 16.0) }
        return sign * pow(a, 1.8)
    }

    private static func clamp01(_ x: Float) -> Float {
        max(0, min(1, x))
    }

    private static func clamp01(_ x: Double) -> Double {
        max(0, min(1, x))
    }
}
