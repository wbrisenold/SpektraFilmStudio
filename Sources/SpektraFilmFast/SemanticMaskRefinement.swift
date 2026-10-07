import Foundation

enum SemanticMaskRefinement {
    static func refine(_ alpha: [UInt8], width: Int, height: Int) -> [UInt8] {
        guard width > 2, height > 2, alpha.count == width * height else { return alpha }
        let hasSoftAlpha = alpha.contains { $0 > 0 && $0 < 255 }
        let radius: Float = hasSoftAlpha ? 1.25 : 2.0
        return SpektraStudioCore.feather(
            alpha,
            width: width,
            height: height,
            radius: radius
        ) ?? alpha
    }
}
