import Foundation

enum GPUGradeRegressionTests {
    static func run() throws {
        let width = 128, height = 64
        var pixels = [Float](repeating: 1, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let v = Float(i / 4 % 257) / 64 - 0.05
            pixels[i] = v; pixels[i+1] = v * 0.71; pixels[i+2] = v * 0.43
        }
        let input = PixelBufferF32(width: width, height: height, pixels: pixels)
        var cases = [ToneSettings()]
        for key in [\ToneSettings.exposureEV, \.brightness, \.midtones, \.contrast, \.shadows, \.highlights, \.highlightRecovery, \.shadowRecovery, \.blacks, \.whites, \.blackPoint, \.whitePoint] {
            for value in [-35.0, 35.0] {
                var tone = ToneSettings(); tone[keyPath: key] = key == \ToneSettings.exposureEV ? value / 35 : value
                cases.append(tone)
            }
        }
        var curved = ToneSettings()
        curved.curvePoints = [.init(x: 0, y: 0), .init(x: 0.25, y: 0.18), .init(x: 0.7, y: 0.8), .init(x: 1, y: 1)]
        cases.append(curved)
        var automatic = ToneSettings(); automatic.autoContrast = true; cases.append(automatic)
        var density = ColorDensitySettings(); density.master = -0.3; density.red = -0.4; density.blue = -0.2
        let checkpoint = GPUProcessingFailure.checkpoint()
        var worst = 0.0
        for tone in cases {
            for d in [ColorDensitySettings(), density] {
                let actual = input.applyingHostGrade(tone: tone, density: d)
                let expected = input.referenceHostGrade(tone: tone, density: d)
                for (a, b) in zip(actual.pixels, expected.pixels) {
                    let error = Double(abs(a-b)) / max(1, Double(abs(b)))
                    guard a.isFinite, error < 0.0003 else { throw RendererError.renderFailed("GPU tone parity failed: \(error)") }
                    worst = max(worst, error)
                }
            }
            let fused = input.applyingHostAndFilmGrade(tone: tone, density: density, film: tone)
            let staged = input.referenceHostGrade(tone: tone, density: density).referenceFilmExposureShape(tone)
            for (a, b) in zip(fused.pixels, staged.pixels) {
                guard a.isFinite, abs(a-b) < 0.0003 * max(1, abs(b)) else { throw RendererError.renderFailed("Fused GPU host/film parity failed") }
            }
            let actual = input.applyingFilmExposureShape(tone), expected = input.referenceFilmExposureShape(tone)
            for (a, b) in zip(actual.pixels, expected.pixels) {
                guard a.isFinite, abs(a-b) < 0.0003 * max(1, abs(b)) else { throw RendererError.renderFailed("GPU film-input parity failed") }
            }
        }
        try GPUProcessingFailure.requireSuccess(after: checkpoint)
        let first = try MaskBrushEngine.shared.paint(nil, width: 128, height: 64, points: [.init(x: 0.2, y: 0.5), .init(x: 0.4, y: 0.5)], radius: 0.03)
        let second = try MaskBrushEngine.shared.paint(first, width: 128, height: 64, points: [.init(x: 0.8, y: 0.5)], radius: 0.03)
        let a = first.decodedAlpha(), b = second.decodedAlpha()
        guard b[32 * 128 + 102] > 200,
              zip(a, b).allSatisfy({ $0 <= $1 }) else { throw RendererError.renderFailed("GPU brush union failed") }
        let erased = try MaskBrushEngine.shared.paint(second, width: 128, height: 64, points: [.init(x: 0.8, y: 0.5)], radius: 0.03, erase: true)
        let restored = try MaskBrushEngine.shared.paint(erased, width: 128, height: 64, points: [.init(x: 0.8, y: 0.5)], radius: 0.03)
        guard erased.decodedAlpha()[32 * 128 + 102] < 10, restored.decodedAlpha()[32 * 128 + 102] > 200 else { throw RendererError.renderFailed("GPU brush erase/repaint failed") }
        var look = RenderLook.defaults()
        let flat = PixelBufferF32(width: 600, height: 600, pixels: (0..<(600*600*4)).map { $0 % 4 == 3 ? Float(1) : Float(0.45) })
        guard RedlampFilmEffectsEngine.shared.apply(flat, look: look).pixels == flat.pixels else { throw RendererError.renderFailed("Disabled film effects changed pixels") }
        var effects = FilmEffectsSettings()
        for style in 1...4 {
            effects.frameStyle = style; look.filmEffects = effects
            let output = RedlampFilmEffectsEngine.shared.apply(flat, look: look)
            let center = (300 * 600 + 300) * 4
            guard output.pixels[center] == flat.pixels[center], output.pixels.contains(where: { abs($0-0.45) > 0.1 && $0 != 1 }) else { throw RendererError.renderFailed("Frame edge/center regression") }
        }
        effects = FilmEffectsSettings(); effects.leakAmount = 90; effects.leakWarmth = 100; look.filmEffects = effects
        let leaked = RedlampFilmEffectsEngine.shared.apply(flat, look: look)
        guard zip(leaked.pixels, flat.pixels).contains(where: { $0 - $1 > 0.1 }) else { throw RendererError.renderFailed("Missing light leaks") }
        for scratch in [false, true] {
            effects = FilmEffectsSettings()
            if scratch { effects.scratchAmount = 100 } else { effects.dustAmount = 100 }
            look.filmEffects = effects
            let output = RedlampFilmEffectsEngine.shared.apply(flat, look: look)
            let repeated = RedlampFilmEffectsEngine.shared.apply(flat, look: look)
            guard output.pixels == repeated.pixels, zip(output.pixels, flat.pixels).contains(where: { abs($0-$1) > 0.03 }) else { throw RendererError.renderFailed("Missing or unstable surface effects") }
        }
        let decoded = try JSONDecoder().decode(RenderLook.self, from: JSONEncoder().encode(look))
        guard decoded.filmEffects == look.filmEffects else { throw RendererError.renderFailed("Film effects settings round trip failed") }
        try GPUProcessingFailure.requireSuccess(after: checkpoint)
        print("REDLAMP FILM EFFECTS PASS: four frames, leaks, dust, scratches, repeatability, saved settings")
        print("GPU GRADE/BRUSH PASS: \(cases.count * 3) comparisons; relative error \(worst)")
    }
}
