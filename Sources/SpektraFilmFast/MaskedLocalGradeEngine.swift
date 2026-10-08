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
