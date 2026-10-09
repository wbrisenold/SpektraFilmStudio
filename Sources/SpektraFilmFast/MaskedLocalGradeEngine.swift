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
            guard tone != nil || density != nil || grade.localColor != nil else { continue }
            let coverage = coverageForGrade(grade, width: width, height: height)
            guard coverage.contains(where: { $0 > 0.0001 }) else { continue }
            var adjustmentInput = current
            let enabled = grade.masks.sources.filter(\.enabled)
            if enabled.count == 1, let source = enabled.first, source.aiRecipe?.kind == .sky,
               source.aiRecipe?.feather == 0, !source.inverted,
               coverage.contains(where: { $0 >= 0.98 * Float(source.opacity) }) {
                let colours = (0..<(width * height)).map { i in
                    SIMD3(current.pixels[i * 4], current.pixels[i * 4 + 1], current.pixels[i * 4 + 2])
                }
                let sky = coverage.map { $0 >= 0.98 * Float(source.opacity) }
                let inside = SkyMatte.SkyColour(colours, sky: sky, width: width, height: height)
                var input = current.pixels
                for i in coverage.indices where coverage[i] > 0 && coverage[i] < 0.98 * Float(source.opacity) {
                    let colour = inside.at(i)
                    input[i * 4] = colour.x; input[i * 4 + 1] = colour.y; input[i * 4 + 2] = colour.z
                }
                adjustmentInput = PixelBufferF32(width: width, height: height, pixels: input)
            }
            let toned = adjustmentInput.applyingHostGrade(tone: tone, density: density)
            let adjusted = applyColor(toned, settings: grade.localColor)
            guard adjusted.pixels.count == current.pixels.count else { continue }
            var pixels = current.pixels
            let opacity = Float(max(0, min(1, grade.opacity)))
            for i in coverage.indices {
                let a = opacity * coverage[i]
                if a <= 0 { continue }
                let p = i * 4
                for channel in 0..<3 {
                    pixels[p + channel] += (adjusted.pixels[p + channel] - adjustmentInput.pixels[p + channel]) * a
                }
            }
            current = PixelBufferF32(width: width, height: height, pixels: pixels)
        }
        return current
    }

    private static func applyColor(_ image: PixelBufferF32, settings: LocalMaskColorSettings?) -> PixelBufferF32 {
        guard let settings else { return image }
        let count = image.width * image.height
        var pixels = image.pixels
        let saturation = Float(1 + min(100, max(-100, settings.saturation)) / 100)
        let warmth = Float(min(100, max(-100, settings.temperature)) / 400)
        var detail: [Float]?
        if settings.texture != 0 || settings.clarity != 0 {
            var luma = [Float](repeating: 0, count: count)
            for i in 0..<count {
                let p = i * 4
                luma[i] = pixels[p] * Float(0.2627) + pixels[p + 1] * Float(0.6780) + pixels[p + 2] * Float(0.0593)
            }
            let fine = BoxFilter.blur(luma, width: image.width, height: image.height, radius: max(1, image.width / 600))
            let broad = BoxFilter.blur(luma, width: image.width, height: image.height, radius: max(2, image.width / 80))
            var values = [Float](repeating: 0, count: count)
            let texture = Float(settings.texture / 100), clarity = Float(settings.clarity / 100)
            for i in 0..<count { values[i] = (luma[i] - fine[i]) * texture + (fine[i] - broad[i]) * clarity }
            detail = values
        }
        for i in 0..<count {
            let p = i * 4
            let y = pixels[p] * 0.2627 + pixels[p + 1] * 0.6780 + pixels[p + 2] * 0.0593
            for c in 0..<3 {
                let temperature: Float = c == 0 ? (1 + warmth) : (c == 2 ? 1 - warmth : 1)
                pixels[p + c] = max(0, (y + (pixels[p + c] - y) * saturation + (detail?[i] ?? 0)) * temperature)
            }
        }
        return PixelBufferF32(width: image.width, height: image.height, pixels: pixels)
    }

    /// A stack with no sources means full frame by design. A stack with only disabled
    /// sources means zero coverage, so disabling a mask never silently grades globally.
    // Redlamp-derived coverage is the only evaluator used by local edit AND overlay.
    static func coverageForGrade(_ grade: LocalGradeRecord, width: Int, height: Int) -> [Float] {
        guard let gpu = MaskMetalEngine.shared?.renderCoverage(
            grade: grade, width: width, height: height
        ), gpu.count == width * height else {
            GPUProcessingFailure.report("Mask Metal pipeline failed. Local mask processing stopped; no CPU fallback is running.")
            return []
        }
        return gpu
    }
}
