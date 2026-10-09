import Foundation

// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.
//
// Redlamp-derived per-pixel mask component evaluation and ordered combination.
// Source: https://github.com/pdcgomes/redlamp/blob/main/packages/RedlampKernels/Sources/Shaders/Masks.h
// The GPU Masks.h evaluator was adapted to SpektraFilm's serialized MaskSourceRecord
// and a CPU fallback for Intel Macs. The original Redlamp shader is not an API drop-in.
// SpektraFilm keeps its legacy linear-gradient orientation for saved-mask compatibility.
// The same coverage function is used for local edits and the viewer overlay.

enum RedlampMaskCoverage {
    static func coverage(for grade: LocalGradeRecord, width: Int, height: Int) -> [Float] {
        guard width > 0, height > 0, width <= 16384, height <= 16384,
              width <= Int.max / height else { return [] }
        let count = width * height
        if grade.masks.sources.isEmpty { return [Float](repeating: 1, count: count) }
        let sources = grade.masks.sources.filter(\.enabled).map(MaskRasterProcessing.prepared).map(MaskRasterProcessing.depthPrepared)
        guard !sources.isEmpty else { return [Float](repeating: 0, count: count) }

        var coverage = [Float](repeating: 0, count: count)
        for (index, source) in sources.enumerated() {
            if Task.isCancelled { return coverage }
            let samples = evaluate(source, width: width, height: height)
            guard samples.count == count else { return [Float](repeating: 0, count: count) }
            for i in 0..<count {
                // Redlamp's combineMaskCoverage: union=max, subtraction=a*(1-b),
                // intersection=a*b. A first subtract is empty, not inverted full-frame.
                let weight = samples[i]
                if index == 0 {
                    coverage[i] = source.blendMode == .subtract ? 0 : weight
                } else {
                    switch source.blendMode {
                    case .add: coverage[i] = max(coverage[i], weight)
                    case .subtract: coverage[i] *= 1 - weight
                    case .intersect: coverage[i] *= weight
                    }
                }
            }
        }
        return coverage
    }

    private static func evaluate(_ source: MaskSourceRecord, width: Int, height: Int) -> [Float] {
        let count = width * height
        let opacity = Float(max(0, min(1, source.opacity)))
        let feather = Float(max(0.00001, min(1, source.feather)))
        let radial = source.radial ?? RadialMaskGeometry()
        let linear = source.linearGradient ?? LinearGradientMaskGeometry()
        let angle = Float(-radial.rotationDegrees * .pi / 180)
        let cs = cos(angle), sn = sin(angle)
        let ax = Float(linear.end.x - linear.start.x)
        let ay = Float(linear.end.y - linear.start.y)
        let axisLength2 = max(0.00000001, ax * ax + ay * ay)
        let raster = source.raster
        let rasterAlpha = source.kind == .raster ? (raster?.decodedAlpha() ?? []) : []
        let rw = raster?.width ?? 0, rh = raster?.height ?? 0
        var values = [Float](repeating: 0, count: count)
        for y in 0..<height {
            if y.isMultiple(of: 16) && Task.isCancelled { return values }
            let v = (Float(y) + 0.5) / Float(height)
            for x in 0..<width {
                let u = (Float(x) + 0.5) / Float(width)
                let coverage: Float
                switch source.kind {
                case .linearGradient:
                    let t = ((u - Float(linear.start.x)) * ax + (v - Float(linear.start.y)) * ay) / axisLength2
                    // Saved SpektraFilm gradients are 0 at start and 1 at end.
                    coverage = smoothstep(0.5 - feather, 0.5 + feather, t)
                case .radial:
                    let dx = u - Float(radial.center.x), dy = v - Float(radial.center.y)
                    let rotatedX = cs * dx - sn * dy
                    let rotatedY = sn * dx + cs * dy
                    let rx = rotatedX / max(0.00001, Float(radial.radiusX))
                    let ry = rotatedY / max(0.00001, Float(radial.radiusY))
                    let distance = sqrt(rx * rx + ry * ry)
                    let inner = min(0.999, 1 - feather)
                    coverage = 1 - smoothstep(inner, 1, distance)
                case .raster:
                    // Redlamp samples its mask textures bilinearly instead of the old
                    // nearest-neighbor integer lookup. Preserve subpixel edges and hair.
                    guard rw > 0, rh > 0, rasterAlpha.count == rw * rh else { continue }
                    let fx = max(0, min(Float(rw - 1), u * Float(rw) - 0.5))
                    let fy = max(0, min(Float(rh - 1), v * Float(rh) - 0.5))
                    let x0 = Int(fx), y0 = Int(fy)
                    let x1 = min(rw - 1, x0 + 1), y1 = min(rh - 1, y0 + 1)
                    let tx = fx - Float(x0), ty = fy - Float(y0)
                    let a = Float(rasterAlpha[y0 * rw + x0]) * (1 - tx)
                          + Float(rasterAlpha[y0 * rw + x1]) * tx
                    let b = Float(rasterAlpha[y1 * rw + x0]) * (1 - tx)
                          + Float(rasterAlpha[y1 * rw + x1]) * tx
                    coverage = (a * (1 - ty) + b * ty) / 255
                }
                let value = source.inverted ? 1 - coverage : coverage
                values[y * width + x] = max(0, min(1, value * opacity))
            }
        }
        return values
    }

    private static func smoothstep(_ a: Float, _ b: Float, _ value: Float) -> Float {
        let t = max(0, min(1, (value - a) / max(0.000001, b - a)))
        return t * t * (3 - 2 * t)
    }
}
