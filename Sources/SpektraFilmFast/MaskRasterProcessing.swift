import Foundation

/// Edge/Feather shape the body while retaining the matte's fine strands (Redlamp process 14).
/// Cache the result so slider-independent renders only upload a texture once.
enum MaskRasterProcessing {
    private struct Entry {
        var input: RasterMaskPayload
        var feather: Double
        var edge: Double
        var output: RasterMaskPayload
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [UUID: Entry] = [:]
    static func depthPrepared(_ source: MaskSourceRecord) -> MaskSourceRecord {
        guard let recipe = source.aiRecipe, recipe.kind == .depthRange, let raster = source.raster else { return source }
        let softness = max(0.001, recipe.depthSoftness)
        func smooth(_ x: Double) -> Double { let t = min(1, max(0, x)); return t * t * (3 - 2 * t) }
        let alpha = raster.decodedAlpha().map { pixel -> UInt8 in
            let value = Double(pixel) / 255
            let weight = smooth((value - recipe.depthLower + softness) / softness) * smooth((recipe.depthUpper + softness - value) / softness)
            return UInt8((weight * 255).rounded())
        }
        var result = source
        result.raster = RasterMaskPayload(width: raster.width, height: raster.height, alpha: alpha)
        return result
    }

    static func prepared(_ source: MaskSourceRecord) -> MaskSourceRecord {
        guard let recipe = source.aiRecipe, let raster = source.raster,
              recipe.feather != 0 || recipe.edge != 0 else { return source }
        lock.lock(); defer { lock.unlock() }
        var result = source
        if let cached = cache[source.id], cached.input == raster,
           cached.feather == recipe.feather, cached.edge == recipe.edge {
            result.raster = cached.output; return result
        }
        let mask = GrayMask(width: raster.width, height: raster.height, pixels: raster.decodedAlpha())
            .shaped(feather: recipe.feather, edge: recipe.edge,
                    reach: max(1, max(raster.width, raster.height) / 40), keepingDetail: true)
        let payload = RasterMaskPayload(width: mask.width, height: mask.height, alpha: mask.pixels)
        let cost = raster.rle.count + payload.rle.count
        let budget = 128 * 1024 * 1024
        let retained = cache.values.reduce(0) { $0 + $1.input.rle.count + $1.output.rle.count }
        if cache.count >= 32 || retained + cost > budget { cache.removeAll(keepingCapacity: true) }
        if cost <= budget {
            cache[source.id] = Entry(input: raster, feather: recipe.feather, edge: recipe.edge, output: payload)
        }
        result.raster = payload
        return result
    }
}
