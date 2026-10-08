import Foundation
import CoreGraphics

/// Deterministic macOS runtime check. A passing test proves the actual viewer-compositor
/// pixel path makes a center radial mask visibly red without turning the corner red.
/// It does NOT substitute for manual UI validation at Fit, crop, zoom, and export.
enum RedlampMaskSmokeTest {
    static func run() -> Int {
        let width = 128, height = 96
        var input = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let o = i * 4
            input[o] = 90; input[o + 1] = 125; input[o + 2] = 180; input[o + 3] = 255
        }
        var grade = LocalGradeRecord(name: "Smoke test")
        var source = MaskSourceRecord(name: "Center", kind: .radial)
        source.radial = RadialMaskGeometry()
        grade.masks.sources = [source]
        guard let output = RedlampMaskDisplay.compose(
            rgba: input, displayWidth: width, displayHeight: height,
            grade: grade, preGeometryWidth: width, preGeometryHeight: height,
            geometry: nil, style: .color
        ) else { return 11 }
        // On Macs with Metal, verify the installed GPU evaluator has the same coverage
        // as the fallback, not merely that the CPU tint math works.
        if let metal = MaskMetalEngine.shared {
            guard let gpu = metal.renderCoverage(grade: grade, width: width, height: height) else {
                print("FAIL: MaskMetalEngine exists but cannot evaluate a radial mask")
                return 14
            }
            let cpu = RedlampMaskCoverage.coverage(for: grade, width: width, height: height)
            guard gpu.count == cpu.count else { return 15 }
            let largestError = zip(gpu, cpu).reduce(Float.zero) { max($0, abs($1.0 - $1.1)) }
            guard largestError < 0.03 else {
                print("FAIL: GPU/CPU mask coverage parity = \(largestError)")
                return 16
            }
        }
        let center = ((height / 2) * width + width / 2) * 4
        let corner = 0
        guard output[center] > input[center] + 25,
              output[center + 2] < input[center + 2] - 10,
              output[corner] == input[corner],
              output[corner + 1] == input[corner + 1],
              output[corner + 2] == input[corner + 2] else { return 12 }
        guard RedlampMaskDisplay.image(width: width, height: height, rgba: output) != nil else { return 13 }
        print("PASS: Redlamp-derived mask overlay changes center photo pixels, preserves corners, creates CGImage")
        return 0
    }
}
