import Foundation
import CoreGraphics
import CoreVideo

/// Compatibility adapter for saved semantic masks and diagnostic skin overlays.
/// The editing UI uses RedlampMaskService and its replayable recipes directly.
actor SemanticMaskEngine {
    func clearCache() { cache.removeAll() }
    func invalidate(imageURL: URL) { cache = cache.filter { $0.key != imageURL } }
    private var cache: [URL: CanonicalSemanticMaskSet] = [:]
    private var cachedStamp: Date?

    func analyze(imageURL: URL, cgImage: CGImage, targetLongEdge: Int = 1080, requested: Set<SemanticMaskKind> = [.skin]) async throws -> CanonicalSemanticMaskSet {
        let image = try await RedlampMaskService.shared.analysisImage(imageURL)
        let provider = VisionMaskProvider()
        let size = PixelSize(width: cgImage.width, height: cgImage.height)
        let stamp = try? imageURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        var alpha = cache[imageURL].flatMap { cached in
            cached.width == size.width && cached.height == size.height && stamp == cachedStamp ? cached.alphaByKind : nil
        } ?? [:]
        for (kind, request) in [
            (SemanticMaskKind.subject, MaskRequest(kind: .subject)),
            (.background, MaskRequest(kind: .background)),
            (.person, MaskRequest(kind: .people)),
            (.skin, MaskRequest(kind: .people, part: .faceSkin)),
            (.eyes, MaskRequest(kind: .people, part: .eyeSclera)),
            (.lips, MaskRequest(kind: .people, part: .lips))
        ] where requested.contains(kind) && alpha[kind] == nil {
            guard let masks = try? provider.masks(for: request, in: image), let first = masks.first else { continue }
            let combined = masks.dropFirst().reduce(first.mask) { $0.union($1.mask) }
            alpha[kind] = combined.resized(to: size).pixels
        }
        let result = CanonicalSemanticMaskSet(width: size.width, height: size.height, alphaByKind: alpha,
                                              provenance: ["Apple Vision · Redlamp face parts · unedited original"])
        cache = [imageURL: result]
        cachedStamp = stamp
        return result
    }

    func objectMask(cgImage: CGImage, normalizedPoint: CGPoint) throws -> [UInt8] {
        try SAM2TinySegmenter().mask(image: cgImage, point: normalizedPoint)
    }
}
enum PixelMaskResize {
    static func copy(pixelBuffer: CVPixelBuffer, width: Int, height: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let sw = CVPixelBufferGetWidth(pixelBuffer), sh = CVPixelBufferGetHeight(pixelBuffer)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard sw > 0, sh > 0, let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return [UInt8](repeating: 0, count: width * height) }
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        func sample(_ x: Int, _ y: Int) -> Double {
            let xx = min(sw - 1, max(0, x)), yy = min(sh - 1, max(0, y))
            switch format {
            case kCVPixelFormatType_OneComponent8:
                let row = base.advanced(by: yy * stride).assumingMemoryBound(to: UInt8.self)
                return Double(row[xx]) / 255.0
            case kCVPixelFormatType_OneComponent32Float:
                let row = base.advanced(by: yy * stride).assumingMemoryBound(to: Float.self)
                return Double(max(0, min(1, row[xx])))
            default:
                return 0
            }
        }
        var out = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let fy = (Double(y) + 0.5) * Double(sh) / Double(max(1, height)) - 0.5
            let y0 = Int(floor(fy)), y1 = y0 + 1, ty = fy - Double(y0)
            for x in 0..<width {
                let fx = (Double(x) + 0.5) * Double(sw) / Double(max(1, width)) - 0.5
                let x0 = Int(floor(fx)), x1 = x0 + 1, tx = fx - Double(x0)
                let a = sample(x0, y0) * (1 - tx) + sample(x1, y0) * tx
                let b = sample(x0, y1) * (1 - tx) + sample(x1, y1) * tx
                let v = max(0, min(1, a * (1 - ty) + b * ty))
                out[y * width + x] = UInt8(clamping: Int((v * 255).rounded()))
            }
        }
        return out
    }
}
