import Foundation
import CoreML
import CoreGraphics
import CoreVideo

/// Apple's Apache-2.0 Core ML conversion of Meta SAM 2.1 Hiera Tiny.
/// Confined to SemanticMaskEngine; inference never runs on the UI actor.
final class SAM2TinySegmenter {
    private let encoder: MLModel
    private let prompt: MLModel
    private let decoder: MLModel
    private var lastImage: CGImage?
    private var lastEmbedding: MLFeatureProvider?

    init(directory: URL? = nil) throws {
        guard let base = directory ?? Bundle.main.resourceURL?.appendingPathComponent("AIModels/SAM2Tiny") else { throw Self.failure("Model resources unavailable") }
        let configuration = StudioGPUDevice.modelConfiguration(forSAM2: true)
        func load(_ role: String) throws -> MLModel {
            let url = base.appendingPathComponent("SAM2_1Tiny\(role)FLOAT16.mlmodelc")
            return try MLModel(contentsOf: url, configuration: configuration)
        }
        encoder = try load("ImageEncoder")
        prompt = try load("PromptEncoder")
        decoder = try load("MaskDecoder")
    }

    func mask(image: CGImage, point: CGPoint) throws -> [UInt8] {
        guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y),
              image.width > 0, image.height > 0, image.width <= 16384, image.height <= 16384 else { throw failure("Invalid object selection") }
        let encoded: MLFeatureProvider
        if let previous = lastImage, previous === image, let cached = lastEmbedding {
            encoded = cached
        } else {
            let buffer = try Self.input(image)
            encoded = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)]))
            lastImage = image
            lastEmbedding = encoded
        }
        let points = try MLMultiArray(shape: [1, 1, 2], dataType: .float32)
        points[0] = NSNumber(value: Double(point.x) * 1024)
        points[1] = NSNumber(value: Double(point.y) * 1024)
        let labels = try MLMultiArray(shape: [1, 1], dataType: .float32)
        labels[0] = 1
        let prompted = try prompt.prediction(from: MLDictionaryFeatureProvider(dictionary: ["points": points, "labels": labels]))
        var features: [String: MLFeatureValue] = [:]
        for key in ["image_embedding", "feats_s0", "feats_s1"] {
            guard let value = encoded.featureValue(for: key) else { throw failure("Missing image embedding") }
            features[key] = value
        }
        guard let sparse = prompted.featureValue(for: "sparse_embeddings"),
              let dense = prompted.featureValue(for: "dense_embeddings") else { throw failure("Missing object prompt") }
        features["sparse_embedding"] = sparse
        features["dense_embedding"] = dense
        let decoded = try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: features))
        guard let scores = decoded.featureValue(for: "scores")?.multiArrayValue,
              let masks = decoded.featureValue(for: "low_res_masks")?.multiArrayValue,
              scores.count >= 3, masks.shape.map(\.intValue) == [1, 3, 256, 256] else { throw failure("Unexpected object mask output") }
        // NSNumber indexing honors Core ML's strides and fp16 storage on Intel, too.
        func logit(_ proposal: Int, _ x: Int, _ y: Int) -> Double {
            masks[[0, NSNumber(value: proposal), NSNumber(value: y), NSNumber(value: x)]].doubleValue
        }
        let values = (0..<3).map { scores[$0].doubleValue }
        guard values.allSatisfy(\.isFinite) else { throw failure("Invalid model scores") }
        let top = values.max()!
        let candidates = (0..<3).filter { values[$0] >= top - 0.15 }
        let best = candidates.max { a, b in
            func area(_ n: Int) -> Int {
                var count = 0
                for y in stride(from: 0, to: 256, by: 4) {
                    for x in stride(from: 0, to: 256, by: 4) where logit(n, x, y) > 0 { count += 1 }
                }
                return count
            }
            return area(a) < area(b)
        } ?? 0
        var low = [UInt8](repeating: 0, count: 256 * 256)
        for y in 0..<256 { for x in 0..<256 {
            let value = logit(best, x, y)
            guard value.isFinite else { throw failure("Invalid mask coverage") }
            low[y * 256 + x] = UInt8(clamping: Int((255 / (1 + exp(-max(-80, min(80, value * 2))))).rounded()))
        } }
        return CanonicalSkinMaskPayload(width: 256, height: 256, alpha: low).resampled(width: image.width, height: image.height)
    }

    private static func input(_ image: CGImage) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 1024, 1024, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result)
        guard status == kCVReturnSuccess, let buffer = result else { throw failure("Cannot allocate model input") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 1024, height: 1024,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { throw failure("Cannot draw model input") }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
        return buffer
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Spektra.SAM2", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private func failure(_ message: String) -> NSError { Self.failure(message) }
}
