import Foundation

enum SemanticMaskKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case subject="Subject", background="Background", person="Person", skin="Skin Only", hair="Hair", eyes="Eyes", lips="Lips", body="Body", upperClothes="Upper Clothes", lowerClothes="Lower Clothes", arms="Arms", legs="Legs", shoes="Shoes", object="Object"
    var id:String{rawValue}
}
struct CanonicalSemanticMaskSet: Sendable { let width:Int; let height:Int; var alphaByKind:[SemanticMaskKind:[UInt8]]; var provenance:[String]; func alpha(_ kind:SemanticMaskKind)->[UInt8]?{alphaByKind[kind]} }
/// Shared soft-alpha matte for Auto Skin WB, skin overlay and skin scopes.
/// Resample once from one canonical mask, preserving smooth edges (not nearest-neighbor).
struct CanonicalSkinMaskPayload: Sendable {
    let width: Int
    let height: Int
    let alpha: [UInt8]
    func resampled(width w: Int, height h: Int) -> [UInt8] {
        guard width > 0, height > 0, w > 0, h > 0,
              width <= 16384, height <= 16384, w <= 16384, h <= 16384,
              alpha.count == width * height else { return [] }
        if w == width && h == height { return alpha }
        var output = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let sy = max(0, min(Double(height - 1), (Double(y) + 0.5) * Double(height) / Double(h) - 0.5))
            let y0 = Int(sy), y1 = min(height - 1, y0 + 1), fy = sy - Double(y0)
            for x in 0..<w {
                let sx = max(0, min(Double(width - 1), (Double(x) + 0.5) * Double(width) / Double(w) - 0.5))
                let x0 = Int(sx), x1 = min(width - 1, x0 + 1), fx = sx - Double(x0)
                let top = Double(alpha[y0 * width + x0]) * (1 - fx) + Double(alpha[y0 * width + x1]) * fx
                let bottom = Double(alpha[y1 * width + x0]) * (1 - fx) + Double(alpha[y1 * width + x1]) * fx
                output[y * w + x] = UInt8(clamping: Int((top * (1 - fy) + bottom * fy).rounded()))
            }
        }
        return output
    }
}
enum SemanticModelProfile:Int32,Sendable{case face19=1,schpLIP20=2,modnet=3}
enum SemanticLabels {
    // PayamFard123/yakhyo CelebAMask-HQ order: bg, skin, brows, eyes, glasses, ears, earring, nose, mouth, lips, neck, cloth, hair, hat.
    static let faceSkin:Set<UInt8>=[1,7,8,10,14,15]
    static let faceEyes:Set<UInt8>=[4,5]
    static let faceLips:Set<UInt8>=[12,13]
    static let faceHair:Set<UInt8>=[17]
    // SCHP LIP-20: bg, hat, hair, glove, sunglasses, upper, dress, coat, socks, pants, jumpsuit, scarf, skirt, face, arms, legs, shoes.
    static let person=Set((1...19).map(UInt8.init))
    static let hair:Set<UInt8>=[2]
    static let upperClothes:Set<UInt8>=[5,6,7,10,11]
    static let lowerClothes:Set<UInt8>=[6,8,9,10,12]
    static let arms:Set<UInt8>=[14,15]
    static let legs:Set<UInt8>=[16,17]
    static let shoes:Set<UInt8>=[18,19]
}
