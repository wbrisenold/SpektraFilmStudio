import Foundation
import Accelerate

/// Small native feather pass used after semantic masks. This replaces the old
/// PhotoCraft feather bridge and keeps mask refinement inside SpektraFilm.
enum SemanticMaskRefinement {
    static func refine(_ alpha: [UInt8], width: Int, height: Int) -> [UInt8] {
        guard width > 2, height > 2, alpha.count == width * height else { return alpha }

        let hasSoftAlpha = alpha.contains { $0 > 0 && $0 < 255 }
        let kernel: UInt32 = hasSoftAlpha ? 3 : 5
        var source = alpha
        var destination = [UInt8](repeating: 0, count: alpha.count)

        let error: vImage_Error = source.withUnsafeMutableBytes { srcBytes in
            destination.withUnsafeMutableBytes { dstBytes in
                guard let src = srcBytes.baseAddress, let dst = dstBytes.baseAddress else {
                    return vImage_Error(kvImageNullPointerArgument)
                }
                var input = vImage_Buffer(
                    data: src,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width
                )
                var output = vImage_Buffer(
                    data: dst,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width
                )
                return vImageTentConvolve_Planar8(
                    &input,
                    &output,
                    nil,
                    0,
                    0,
                    kernel,
                    kernel,
                    0,
                    vImage_Flags(kvImageEdgeExtend)
                )
            }
        }

        return error == kvImageNoError ? destination : alpha
    }
}
