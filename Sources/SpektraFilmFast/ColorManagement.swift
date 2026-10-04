import CoreGraphics

struct OutputColorProfile {
    let displayName: String
    let cgColorSpace: CGColorSpace
    let isExactSystemMatch: Bool

    static let inputLinearRec2020 = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) ?? CGColorSpaceCreateDeviceRGB()

    static func forLook(_ look: RenderLook) -> OutputColorProfile {
        let index = Int(look.values["outputColorSpace"]?.intValue ?? 25)
        switch index {
        case 14:
            return .init(displayName: "Linear Rec.2020", cgColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) ?? CGColorSpaceCreateDeviceRGB(), isExactSystemMatch: true)
        case 15:
            return .init(displayName: "Linear Rec.709", cgColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB) ?? CGColorSpaceCreateDeviceRGB(), isExactSystemMatch: true)
        case 16:
            return .init(displayName: "Linear P3-D65", cgColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) ?? CGColorSpaceCreateDeviceRGB(), isExactSystemMatch: true)
        case 17:
            return .init(displayName: "sRGB", cgColorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), isExactSystemMatch: true)
        case 18:
            return .init(displayName: "Display P3", cgColorSpace: CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB(), isExactSystemMatch: true)
        case 19:
            return .init(displayName: "ProPhoto RGB", cgColorSpace: CGColorSpace(name: CGColorSpace.rommrgb) ?? CGColorSpaceCreateDeviceRGB(), isExactSystemMatch: true)
        case 20:
            return .init(displayName: "Adobe RGB (1998)", cgColorSpace: CGColorSpace(name: CGColorSpace.adobeRGB1998) ?? CGColorSpaceCreateDeviceRGB(), isExactSystemMatch: true)
        case 21:
            return .init(displayName: "DCI-P3", cgColorSpace: CGColorSpace(name: CGColorSpace.dcip3) ?? CGColorSpaceCreateDeviceRGB(), isExactSystemMatch: true)
        case 24, 25:
            return .init(displayName: index == 24 ? "Rec.709 Gamma 2.2" : "Rec.709 Gamma 2.4", cgColorSpace: CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB(), isExactSystemMatch: true)
        default:
            // Camera log / ACES / transfer variants do not have a reliable one-to-one
            // CoreGraphics ICC profile. Device RGB avoids falsely tagging them as Rec.709.
            return .init(displayName: "Renderer output space", cgColorSpace: CGColorSpaceCreateDeviceRGB(), isExactSystemMatch: false)
        }
    }
}
