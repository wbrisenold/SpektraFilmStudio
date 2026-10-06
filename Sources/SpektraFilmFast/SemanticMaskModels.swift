import Foundation

enum SemanticMaskKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case subject="Subject", background="Background", person="Person", skin="Skin Only", hair="Hair", eyes="Eyes", lips="Lips", body="Body", upperClothes="Upper Clothes", lowerClothes="Lower Clothes", arms="Arms", legs="Legs", shoes="Shoes", object="Object"
    var id:String{rawValue}
}
struct CanonicalSemanticMaskSet: Sendable { let width:Int; let height:Int; var alphaByKind:[SemanticMaskKind:[UInt8]]; var provenance:[String]; func alpha(_ kind:SemanticMaskKind)->[UInt8]?{alphaByKind[kind]} }
struct CanonicalSkinMaskPayload: Sendable { let width:Int; let height:Int; let alpha:[UInt8]; func resampled(width w:Int,height h:Int)->[UInt8]{ guard width>0,height>0,alpha.count==width*height else{return [UInt8](repeating:0,count:max(0,w*h))}; var o=[UInt8](repeating:0,count:w*h); for y in 0..<h{let sy=min(height-1,y*height/max(1,h));for x in 0..<w{let sx=min(width-1,x*width/max(1,w));o[y*w+x]=alpha[sy*width+sx]}};return o } }
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
