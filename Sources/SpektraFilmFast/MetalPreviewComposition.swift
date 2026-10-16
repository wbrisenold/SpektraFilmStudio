import CoreGraphics
import CoreImage
import Foundation
import Metal

/// One path for the actual MTKView and the real-Metal presentation smoke test.
/// Never declare a GPU render successful simply because a command buffer completed.
enum MetalPreviewComposition {
    enum Failure: LocalizedError {
        case missingImage
        var errorDescription: String? {
            "Metal preview texture could not be imported as a CIImage"
        }
    }

    static func content(texture: any MTLTexture, colorSpace: CGColorSpace) throws -> CIImage {
        guard texture.width > 0, texture.height > 0,
              let image = CIImage(mtlTexture: texture, options: [.colorSpace: colorSpace]),
              !image.extent.isEmpty, image.extent.width.isFinite,
              image.extent.height.isFinite
        else {
            throw Failure.missingImage
        }
        return image
    }

    static func letterbox(_ image: CIImage, width: Int, height: Int) -> CIImage {
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        let bounds = image.extent
        let scale = min(
            CGFloat(width) / max(1, bounds.width),
            CGFloat(height) / max(1, bounds.height),
        )
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = scaled.extent
        let centered = scaled.transformed(
            by: CGAffineTransform(
                translationX: (CGFloat(width) - extent.width) * 0.5 - extent.minX,
                y: (CGFloat(height) - extent.height) * 0.5 - extent.minY,
            ),
        )
        let background = CIImage(color: CIColor.black).cropped(to: target)
        return centered.composited(over: background)
    }
}
