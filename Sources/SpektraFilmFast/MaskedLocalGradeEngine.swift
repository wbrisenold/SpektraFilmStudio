import Foundation

/// Local grades are post-film adjustments. They never change global tone settings.
/// The exact same function is invoked by settled preview and export.
enum MaskedLocalGradeEngine {
    static func apply(_ base: PixelBufferF32, grades: [LocalGradeRecord]?) -> PixelBufferF32 {
        guard let grades, !grades.isEmpty else { return base }
        let width = base.width, height = base.height
        guard width > 0, height > 0, base.pixels.count == width * height * 4 else { return base }
        var current = base
        for grade in grades where grade.enabled && grade.opacity > 0 {
            let tone = grade.tone
            let density = grade.colorDensity
            guard tone != nil || density != nil else { continue }
            let coverage = coverageForGrade(grade, width: width, height: height)
            guard coverage.contains(where: { $0 > 0.0001 }) else { continue }
            let adjusted = current.applyingHostGrade(tone: tone, density: density)
            guard adjusted.pixels.count == current.pixels.count else { continue }
            var pixels = current.pixels
            let opacity = Float(max(0, min(1, grade.opacity)))
            for i in coverage.indices {
                let a = opacity * coverage[i]
                if a <= 0 { continue }
                let p = i * 4
                for channel in 0..<3 {
                    pixels[p + channel] += (adjusted.pixels[p + channel] - pixels[p + channel]) * a
                }
            }
            current = PixelBufferF32(width: width, height: height, pixels: pixels)
        }
        return current
    }

    /// A stack with no sources means full frame by design. A stack with only disabled
    /// sources means zero coverage, so disabling a mask never silently grades globally.
    static func coverageForGrade(_ grade: LocalGradeRecord, width: Int, height: Int) -> [Float] {
        guard width > 0, height > 0 else { return [] }
        let count = width * height
        if grade.masks.sources.isEmpty { return [Float](repeating: 1, count: count) }
        let enabled = grade.masks.sources.filter(\.enabled)
        if enabled.isEmpty { return [Float](repeating: 0, count: count) }
        var coverage = [Float](repeating: 0, count: count)
        for (index, source) in enabled.enumerated() {
            let alpha = coverageForSource(source, width: width, height: height)
            for i in 0..<count {
                if index == 0 {
                    coverage[i] = source.blendMode == .subtract ? 1 - alpha[i] : alpha[i]
                } else {
                    switch source.blendMode {
                    case .add: coverage[i] = max(coverage[i], alpha[i])
                    case .subtract: coverage[i] *= 1 - alpha[i]
                    case .intersect: coverage[i] = min(coverage[i], alpha[i])
                    }
                }
            }
        }
        return coverage
    }

    private static func coverageForSource(_ source: MaskSourceRecord, width: Int, height: Int) -> [Float] {
        let count = width * height
        let opacity = Float(max(0, min(1, source.opacity)))
        var result = [Float](repeating: 0, count: count)
        let feather = Float(max(0, min(1, source.feather)))
        let radial = source.radial ?? RadialMaskGeometry()
        let linear = source.linearGradient ?? LinearGradientMaskGeometry()
        let angle = -Float(radial.rotationDegrees) * .pi / 180
        let cosA = cos(angle), sinA = sin(angle)
        let dx = Float(linear.end.x - linear.start.x)
        let dy = Float(linear.end.y - linear.start.y)
        let denominator = max(0.000001, dx * dx + dy * dy)
        let bitmap: [UInt8]
        let bitmapWidth: Int
        let bitmapHeight: Int
        if source.kind == .raster, let raster = source.raster,
           raster.width > 0, raster.height > 0, raster.width <= 8192,
           raster.height <= 8192, raster.width * raster.height <= 16_777_216 {
            bitmap = raster.decodedAlpha()
            bitmapWidth = raster.width
            bitmapHeight = raster.height
        } else { bitmap = []; bitmapWidth = 0; bitmapHeight = 0 }
        for y in 0..<height {
            let v = (Float(y) + 0.5) / Float(height)
            for x in 0..<width {
                let u = (Float(x) + 0.5) / Float(width)
                var strength: Float
                switch source.kind {
                case .radial:
                    let px = u - Float(radial.center.x), py = v - Float(radial.center.y)
                    let rx = (cosA * px - sinA * py) / max(0.0001, Float(radial.radiusX))
                    let ry = (sinA * px + cosA * py) / max(0.0001, Float(radial.radiusY))
                    let radius = sqrt(rx * rx + ry * ry)
                    strength = 1 - smoothstep(1 - feather, 1 + feather, radius)
                case .linearGradient:
                    let t = ((u - Float(linear.start.x)) * dx + (v - Float(linear.start.y)) * dy) / denominator
                    strength = smoothstep(0.5 - feather, 0.5 + feather, t)
                case .raster:
                    if bitmapWidth > 0 && bitmapHeight > 0 {
                        let px = min(bitmapWidth - 1, max(0, Int(u * Float(bitmapWidth))))
                        let py = min(bitmapHeight - 1, max(0, Int(v * Float(bitmapHeight))))
                        let pos = py * bitmapWidth + px
                        strength = pos < bitmap.count ? Float(bitmap[pos]) / 255 : 0
                    } else { strength = 0 }
                }
                if source.inverted { strength = 1 - strength }
                result[y * width + x] = max(0, min(1, strength)) * opacity
            }
        }
        return result
    }

    private static func smoothstep(_ low: Float, _ high: Float, _ value: Float) -> Float {
        let t = max(0, min(1, (value - low) / max(0.000001, high - low)))
        return t * t * (3 - 2 * t)
    }
}
