import Foundation

struct ScopePayload: Sendable {
    let width: Int
    let height: Int
    let rgba: [UInt8]
}

actor ScopeEngine {
    func analyze(
        _ buffer: PixelBufferF32,
        look: RenderLook,
        mode: ScopeMode,
        skinToleranceDegrees: Double = 12.0,
        skinMaskWidth: Int = 0,
        skinMaskHeight: Int = 0,
        skinMaskAlpha: [UInt8] = [],
        skinMeanCbNormalized: Double = 0.0,
        skinMeanCrNormalized: Double = 0.0,
        skinMeanDeviationDegrees: Double = 0.0,
        skinMeasurementConfidencePercent: Double = 0.0
    ) async throws -> ScopePayload {
        try Task.checkCancellation()
        return try await Task.detached(priority: .utility) {
            try Task.checkCancellation()
            switch mode {
            case .histogram:
                return Self.histogram(buffer, look: look)
            case .waveform:
                return Self.waveform(buffer, look: look, parade: false)
            case .parade:
                return Self.waveform(buffer, look: look, parade: true)
            case .vectorscope:
                return Self.vectorscope(buffer, look: look, skinReference: false, toleranceDegrees: skinToleranceDegrees)
            case .saturation:
                return Self.saturationScope(buffer, look: look)
            case .falseColor:
                return Self.falseColor(buffer, look: look)
            case .skinVectorscope:
                return Self.vectorscope(
                    buffer, look: look, skinReference: true, toleranceDegrees: skinToleranceDegrees,
                    skinMaskWidth: skinMaskWidth, skinMaskHeight: skinMaskHeight, skinMaskAlpha: skinMaskAlpha,
                    skinMeanCbNormalized: skinMeanCbNormalized,
                    skinMeanCrNormalized: skinMeanCrNormalized,
                    skinMeanDeviationDegrees: skinMeanDeviationDegrees,
                    skinMeasurementConfidencePercent: skinMeasurementConfidencePercent
                )
            case .chromaticity:
                return Self.chromaticity(buffer)
            }
        }.value
    }

    // MARK: - Histogram

    private nonisolated static func histogram(_ buffer: PixelBufferF32, look: RenderLook) -> ScopePayload {
        let width = 384
        let height = 180
        let bins = 256
        var red = [UInt32](repeating: 0, count: bins)
        var green = red
        var blue = red
        let step = max(1, Int((Double(buffer.width * buffer.height) / 180_000.0).squareRoot()))

        for y in stride(from: 0, to: buffer.height, by: step) {
            for x in stride(from: 0, to: buffer.width, by: step) {
                let p = (y * buffer.width + x) * 4
                let monitor = DisplayMonitorSignal.rgb(
                    r: buffer.pixels[p], g: buffer.pixels[p + 1], b: buffer.pixels[p + 2], look: look
                )
                red[Int((max(0, min(1, monitor.0)) * 255).rounded())] &+= 1
                green[Int((max(0, min(1, monitor.1)) * 255).rounded())] &+= 1
                blue[Int((max(0, min(1, monitor.2)) * 255).rounded())] &+= 1
            }
        }

        var out = background(width, height)
        drawCartesianGrid(&out, width, height, vertical: true)
        let channels: [([UInt32], (UInt8, UInt8, UInt8))] = [
            (red, (255, 76, 90)),
            (green, (76, 226, 132)),
            (blue, (82, 150, 255))
        ]

        for (values, color) in channels {
            let maxCount = max(1, values.max() ?? 1)
            var previous: (Int, Int)?
            for x in 0..<width {
                let bin = min(bins - 1, x * bins / width)
                let normalized = log1p(Double(values[bin])) / log1p(Double(maxCount))
                let y = height - 2 - Int(normalized * Double(height - 8))
                let point = (x, max(1, min(height - 2, y)))
                if let previous {
                    // A dim under-trace gives the thin RGB curves the same readable density
                    // Alcedo achieves without turning the graph into a filled bar chart.
                    drawLine(&out, width, height, previous, point, color.0, color.1, color.2, 54)
                    drawLine(&out, width, height, (previous.0, previous.1 - 1), (point.0, point.1 - 1), color.0, color.1, color.2, 32)
                    drawLine(&out, width, height, previous, point, color.0, color.1, color.2, 210)
                }
                previous = point
            }
        }

        drawTopBottomRules(&out, width, height)
        return ScopePayload(width: width, height: height, rgba: out)
    }

    // MARK: - Waveform / RGB parade

    private nonisolated static func waveform(_ buffer: PixelBufferF32, look: RenderLook, parade: Bool) -> ScopePayload {
        let width = 384
        let height = 192
        let planeSize = width * height
        var counts = [UInt16](repeating: 0, count: planeSize * 3)
        let xStep = max(1, buffer.width / width)
        let yStep = max(1, buffer.height / 520)
        let segmentWidth = max(1, width / 3)

        for sy in stride(from: 0, to: buffer.height, by: yStep) {
            for sx in stride(from: 0, to: buffer.width, by: xStep) {
                let p = (sy * buffer.width + sx) * 4
                let values = DisplayMonitorSignal.rgb(
                    r: buffer.pixels[p], g: buffer.pixels[p + 1], b: buffer.pixels[p + 2], look: look
                )

                for channel in 0..<3 {
                    let value = channel == 0 ? values.0 : (channel == 1 ? values.1 : values.2)
                    let x: Int
                    if parade {
                        let localX = min(segmentWidth - 1, sx * segmentWidth / max(1, buffer.width))
                        x = min(width - 1, channel * segmentWidth + localX)
                    } else {
                        x = min(width - 1, sx * width / max(1, buffer.width))
                    }
                    let y = height - 1 - min(height - 1, Int((value * Float(height - 1)).rounded()))
                    let index = channel * planeSize + y * width + x
                    counts[index] = min(UInt16.max, counts[index] &+ 1)
                }
            }
        }

        var out = background(width, height)
        drawCartesianGrid(&out, width, height, vertical: false)
        if parade {
            for x in [segmentWidth, segmentWidth * 2] {
                guard x < width else { continue }
                for y in 0..<height { blend(&out, width, x, y, 80, 84, 92, 62) }
            }
        }

        let maxCount = max(1, counts.max() ?? 1)
        let primaryVectors: [(Double, Double, Double)] = [
            (1.00, 0.18, 0.22),
            (0.18, 1.00, 0.42),
            (0.18, 0.42, 1.00)
        ]

        for y in 0..<height {
            for x in 0..<width {
                var density = [Double](repeating: 0, count: 3)
                for channel in 0..<3 {
                    let count = counts[channel * planeSize + y * width + x]
                    if count > 0 {
                        density[channel] = sqrt(Double(count) / Double(maxCount))
                    }
                }
                let peak = density.max() ?? 0
                guard peak > 0.008 else { continue }

                var mixed = (0.0, 0.0, 0.0)
                for channel in 0..<3 {
                    mixed.0 += primaryVectors[channel].0 * density[channel]
                    mixed.1 += primaryVectors[channel].1 * density[channel]
                    mixed.2 += primaryVectors[channel].2 * density[channel]
                }
                let colorPeak = max(0.001, max(mixed.0, max(mixed.1, mixed.2)))
                let r = UInt8(clamping: Int((mixed.0 / colorPeak * 255).rounded()))
                let g = UInt8(clamping: Int((mixed.1 / colorPeak * 255).rounded()))
                let b = UInt8(clamping: Int((mixed.2 / colorPeak * 255).rounded()))
                let alpha = UInt8(clamping: Int(min(218, 8 + peak * 210).rounded()))
                blend(&out, width, x, y, r, g, b, alpha)
            }
        }

        drawTopBottomRules(&out, width, height)
        return ScopePayload(width: width, height: height, rgba: out)
    }

    // Both diagnostics use the *final* post-lens/post-geometry rendered frame,
    // never camera-linear RAW before grading. Interpret coded signal properly.
    private nonisolated static func monitorCode(_ x: Float, outputSpace: Int) -> Float {
        DisplayMonitorSignal.code(x, outputSpace: outputSpace)
    }

    private nonisolated static func saturationScope(_ buffer: PixelBufferF32, look: RenderLook) -> ScopePayload {
        let width=384, height=max(150,Int((Double(384)*Double(buffer.height)/Double(max(1,buffer.width))).rounded()))
        var out=[UInt8](repeating:0,count:width*height*4)
        let space=Int(look.values["outputColorSpace"]?.intValue ?? 25)
        for y in 0..<height { for x in 0..<width {
            let sx=min(buffer.width-1,x*buffer.width/width)
            let sy=min(buffer.height-1,y*buffer.height/height)
            let p=(sy*buffer.width+sx)*4
            let r=monitorCode(buffer.pixels[p],outputSpace:space), g=monitorCode(buffer.pixels[p+1],outputSpace:space), b=monitorCode(buffer.pixels[p+2],outputSpace:space)
            let mx=max(r,max(g,b)), mn=min(r,min(g,b))
            let saturation=mx > 1e-6 ? (mx-mn)/mx : 0
            let luma=0.2126*r+0.7152*g+0.0722*b
            let intensity=min(0.8,max(0.07,luma))*155
            var color:(UInt8,UInt8,UInt8)=(UInt8(clamping:Int(intensity)),UInt8(clamping:Int(intensity)),UInt8(clamping:Int(intensity)))
            // Black and near-white pixels have unreliable/noisy HSV saturation.
            if mx >= 0.12 && luma <= 0.94 {
                switch saturation {
                case ..<0.50: break
                case ..<0.70: color=(58,160,144)  // moderately colorful
                case ..<0.85: color=(236,184,72)  // strong color
                case ..<0.95: color=(244,107,72)  // caution
                default: color=(230,54,102)      // very high HSV saturation
                }
            }
            let o=(y*width+x)*4;out[o]=color.0;out[o+1]=color.1;out[o+2]=color.2;out[o+3]=255
        }}
        return ScopePayload(width:width,height:height,rgba:out)
    }

    private nonisolated static func falseColor(_ buffer: PixelBufferF32, look: RenderLook) -> ScopePayload {
        let width=384, height=max(150,Int((Double(384)*Double(buffer.height)/Double(max(1,buffer.width))).rounded()))
        var out=[UInt8](repeating:0,count:width*height*4)
        let space=Int(look.values["outputColorSpace"]?.intValue ?? 25)
        for y in 0..<height { for x in 0..<width {
            let sx=min(buffer.width-1,x*buffer.width/width), sy=min(buffer.height-1,y*buffer.height/height), p=(sy*buffer.width+sx)*4
            let r=monitorCode(buffer.pixels[p],outputSpace:space),g=monitorCode(buffer.pixels[p+1],outputSpace:space),b=monitorCode(buffer.pixels[p+2],outputSpace:space)
            // Y' (display-code luma) as 0–100 video-level index; unlike the old
            // implementation, linear working data must be transfer-encoded first.
            let yPrime=0.2126*r+0.7152*g+0.0722*b
            let color:(UInt8,UInt8,UInt8)
            switch yPrime {
            case ..<0.03: color=(30,29,91)     // deepest shadows
            case ..<0.10: color=(51,75,158)
            case ..<0.20: color=(53,147,198)
            case ..<0.40: color=(70,171,121)
            case ..<0.60: color=(135,145,138)  // gray around expected middle
            case ..<0.75: color=(227,190,79)
            case ..<0.88: color=(246,124,57)
            case ..<0.97: color=(224,69,87)
            default: color=(255,242,240)
            }
            let o=(y*width+x)*4;out[o]=color.0;out[o+1]=color.1;out[o+2]=color.2;out[o+3]=255
        }}
        return ScopePayload(width:width,height:height,rgba:out)
    }

    // MARK: - Vectorscopes

    private nonisolated static func vectorscope(
        _ buffer: PixelBufferF32,
        look: RenderLook,
        skinReference: Bool,
        toleranceDegrees: Double,
        skinMaskWidth: Int = 0,
        skinMaskHeight: Int = 0,
        skinMaskAlpha: [UInt8] = [],
        skinMeanCbNormalized: Double = 0.0,
        skinMeanCrNormalized: Double = 0.0,
        skinMeanDeviationDegrees: Double = 0.0,
        skinMeasurementConfidencePercent: Double = 0.0
    ) -> ScopePayload {
        let size = 280
        let pixelCount = size * size
        var counts = [UInt16](repeating: 0, count: pixelCount)
        var sumR = [Float](repeating: 0, count: pixelCount)
        var sumG = [Float](repeating: 0, count: pixelCount)
        var sumB = [Float](repeating: 0, count: pixelCount)
        let step = max(1, Int((Double(buffer.width * buffer.height) / 180_000.0).squareRoot()))

        for y in stride(from: 0, to: buffer.height, by: step) {
            for x in stride(from: 0, to: buffer.width, by: step) {
                if skinReference, skinMaskWidth > 0, skinMaskHeight > 0, !skinMaskAlpha.isEmpty {
                    let mx = min(skinMaskWidth - 1, max(0, x * skinMaskWidth / max(1, buffer.width)))
                    let my = min(skinMaskHeight - 1, max(0, y * skinMaskHeight / max(1, buffer.height)))
                    let mi = my * skinMaskWidth + mx
                    guard mi < skinMaskAlpha.count, skinMaskAlpha[mi] > 64 else { continue }
                }
                let p = (y * buffer.width + x) * 4
                let rawR = clamp01(buffer.pixels[p])
                let rawG = clamp01(buffer.pixels[p + 1])
                let rawB = clamp01(buffer.pixels[p + 2])
                let r: Float
                let g: Float
                let b: Float
                let px: Int
                let py: Int

                if skinReference {
                    guard let canonical = SkinToneReference.canonicalDisplayRGB(
                        r: rawR, g: rawG, b: rawB, look: look
                    ) else { continue }
                    r = canonical.0; g = canonical.1; b = canonical.2
                    let chroma = SkinToneReference.position(displayR: r, displayG: g, displayB: b)
                    px = min(size - 1, max(0, Int(((chroma.uNormalized * 0.5 + 0.5) * Float(size - 1)).rounded())))
                    py = min(size - 1, max(0, Int((((-chroma.vNormalized) * 0.5 + 0.5) * Float(size - 1)).rounded())))
                } else {
                    let monitor = DisplayMonitorSignal.rgb(r: rawR, g: rawG, b: rawB, look: look)
                    r = monitor.0; g = monitor.1; b = monitor.2
                    let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    let cb = (b - luma) / (2 * (1 - 0.0722))
                    let cr = (r - luma) / (2 * (1 - 0.2126))
                    px = min(size - 1, max(0, Int(((cb + 0.5) * Float(size - 1)).rounded())))
                    py = min(size - 1, max(0, Int(((0.5 - cr) * Float(size - 1)).rounded())))
                }
                let index = py * size + px
                counts[index] = min(UInt16.max, counts[index] &+ 1)
                sumR[index] += r
                sumG[index] += g
                sumB[index] += b
            }
        }

        var out = background(size, size)
        drawVectorGrid(&out, size)
        if skinReference {
            drawSkinReference(&out, size, referenceDegrees: SkinToneReference.referenceAngleDegrees, toleranceDegrees: toleranceDegrees)
        }
        drawVectorTargets(&out, size)

        let maxCount = max(1, counts.max() ?? 1)
        for y in 0..<size {
            for x in 0..<size {
                let index = y * size + x
                let count = counts[index]
                guard count > 0 else { continue }

                let divisor = Float(count)
                var r = max(0, sumR[index] / divisor)
                var g = max(0, sumG[index] / divisor)
                var b = max(0, sumB[index] / divisor)
                let maxChannel = max(0.001, max(r, max(g, b)))
                r = sqrt(min(1, r / maxChannel))
                g = sqrt(min(1, g / maxChannel))
                b = sqrt(min(1, b / maxChannel))

                let density = log1p(Double(count)) / log1p(Double(maxCount))
                let alpha = UInt8(clamping: Int(min(235, 26 + density * 209).rounded()))
                blend(
                    &out, size, x, y,
                    UInt8(clamping: Int((r * 255).rounded())),
                    UInt8(clamping: Int((g * 255).rounded())),
                    UInt8(clamping: Int((b * 255).rounded())),
                    alpha
                )
            }
        }

        if skinReference, skinMeasurementConfidencePercent > 2.0 {
            drawSkinMeasurement(
                &out,
                size: size,
                cbNormalized: skinMeanCbNormalized,
                crNormalized: skinMeanCrNormalized,
                deviationDegrees: skinMeanDeviationDegrees,
                toleranceDegrees: toleranceDegrees
            )
        }

        drawTopBottomRules(&out, size, size)
        return ScopePayload(width: size, height: size, rgba: out)
    }

    private nonisolated static func drawSkinMeasurement(
        _ out: inout [UInt8],
        size: Int,
        cbNormalized: Double,
        crNormalized: Double,
        deviationDegrees: Double,
        toleranceDegrees: Double
    ) {
        let center = Double(size - 1) * 0.5
        let radiusScale = Double(size - 1) * 0.5
        let cb = max(-1.0, min(1.0, cbNormalized))
        let cr = max(-1.0, min(1.0, crNormalized))
        let measuredRadius = min(0.96, hypot(cb, cr))
        guard measuredRadius > 0.01 else { return }

        let measured = (
            Int((center + cb * radiusScale).rounded()),
            Int((center - cr * radiusScale).rounded())
        )
        let radians = SkinToneReference.referenceAngleDegrees * Double.pi / 180.0
        let targetCb = cos(radians) * measuredRadius
        let targetCr = sin(radians) * measuredRadius
        let target = (
            Int((center + targetCb * radiusScale).rounded()),
            Int((center - targetCr * radiusScale).rounded())
        )

        // Connector answers the grading question immediately: where detected skin is vs
        // where the same chroma magnitude should land on the reference skin line.
        drawLine(&out, size, size, measured, target, 224, 184, 116, 165)

        let dx = Double(target.0 - measured.0)
        let dy = Double(target.1 - measured.1)
        let length = max(1.0, hypot(dx, dy))
        let ux = dx / length
        let uy = dy / length
        let arrow = 8.0
        let wing = 4.5
        let left = (
            Int((Double(target.0) - ux * arrow - uy * wing).rounded()),
            Int((Double(target.1) - uy * arrow + ux * wing).rounded())
        )
        let right = (
            Int((Double(target.0) - ux * arrow + uy * wing).rounded()),
            Int((Double(target.1) - uy * arrow - ux * wing).rounded())
        )
        drawLine(&out, size, size, left, target, 236, 198, 126, 220)
        drawLine(&out, size, size, right, target, 236, 198, 126, 220)

        let stateColor: (UInt8, UInt8, UInt8)
        if deviationDegrees < -toleranceDegrees {
            stateColor = (210, 92, 136)     // too magenta
        } else if deviationDegrees > toleranceDegrees {
            stateColor = (72, 184, 136)     // too green
        } else {
            stateColor = (230, 186, 104)    // on target
        }

        // Target = compact champagne crosshair.
        for d in -5...5 {
            blend(&out, size, target.0 + d, target.1, 236, 198, 126, 220)
            blend(&out, size, target.0, target.1 + d, 236, 198, 126, 220)
        }
        // Measured = high-contrast ring/dot so it stays legible over dense traces.
        for oy in -5...5 {
            for ox in -5...5 {
                let rr = ox * ox + oy * oy
                if rr >= 16 && rr <= 26 {
                    blend(&out, size, measured.0 + ox, measured.1 + oy, 244, 244, 246, 230)
                } else if rr <= 9 {
                    blend(&out, size, measured.0 + ox, measured.1 + oy,
                          stateColor.0, stateColor.1, stateColor.2, 242)
                }
            }
        }
    }

    // MARK: - CIE xy

    private nonisolated static func chromaticity(_ buffer: PixelBufferF32) -> ScopePayload {
        let width = 320
        let height = 256
        var counts = [UInt16](repeating: 0, count: width * height)
        let step = max(1, Int((Double(buffer.width * buffer.height) / 140_000.0).squareRoot()))

        for y in stride(from: 0, to: buffer.height, by: step) {
            for x in stride(from: 0, to: buffer.width, by: step) {
                let p = (y * buffer.width + x) * 4
                let r = max(0, Double(buffer.pixels[p]))
                let g = max(0, Double(buffer.pixels[p + 1]))
                let b = max(0, Double(buffer.pixels[p + 2]))
                let X = 0.6369580483 * r + 0.1446169036 * g + 0.1688809752 * b
                let Y = 0.2627002120 * r + 0.6779980715 * g + 0.0593017165 * b
                let Z = 0.0280726930 * g + 1.0609850577 * b
                let sum = X + Y + Z
                guard sum > 1.0e-8 else { continue }
                let cx = X / sum
                let cy = Y / sum
                guard cx >= 0, cx <= 0.8, cy >= 0, cy <= 0.9 else { continue }
                let px = min(width - 1, max(0, Int((cx / 0.8 * Double(width - 1)).rounded())))
                let py = min(height - 1, max(0, Int(((1 - cy / 0.9) * Double(height - 1)).rounded())))
                let index = py * width + px
                counts[index] = min(UInt16.max, counts[index] &+ 1)
            }
        }

        var out = background(width, height)
        drawChromaticityGrid(&out, width, height)
        let maxCount = max(1, counts.max() ?? 1)
        for y in 0..<height {
            for x in 0..<width {
                let count = counts[y * width + x]
                guard count > 0 else { continue }
                let density = log1p(Double(count)) / log1p(Double(maxCount))
                let alpha = UInt8(clamping: Int(min(238, 35 + density * 203).rounded()))
                blend(&out, width, x, y, 220, 228, 240, alpha)
            }
        }
        drawTopBottomRules(&out, width, height)
        return ScopePayload(width: width, height: height, rgba: out)
    }

    // MARK: - Drawing

    private nonisolated static func background(_ width: Int, _ height: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: out.count, by: 4) {
            out[i] = 9
            out[i + 1] = 11
            out[i + 2] = 14
            out[i + 3] = 255
        }
        return out
    }

    private nonisolated static func drawCartesianGrid(
        _ out: inout [UInt8], _ width: Int, _ height: Int, vertical: Bool
    ) {
        for i in 1..<4 {
            let y = Int((Double(i) / 4.0) * Double(height - 1))
            for x in 0..<width { blend(&out, width, x, y, 75, 80, 89, 48) }
            if vertical {
                let x = Int((Double(i) / 4.0) * Double(width - 1))
                for yy in 0..<height { blend(&out, width, x, yy, 75, 80, 89, 42) }
            }
        }
    }

    private nonisolated static func drawTopBottomRules(
        _ out: inout [UInt8], _ width: Int, _ height: Int
    ) {
        guard height > 1 else { return }
        for x in 0..<width {
            blend(&out, width, x, 0, 104, 110, 120, 82)
            blend(&out, width, x, height - 1, 104, 110, 120, 82)
        }
    }

    private nonisolated static func drawVectorGrid(_ out: inout [UInt8], _ size: Int) {
        let center = Double(size - 1) / 2
        let outerRadius = center * 0.91
        let innerRadius = outerRadius * 0.75
        for y in 0..<size {
            for x in 0..<size {
                let dx = Double(x) - center
                let dy = Double(y) - center
                let radius = sqrt(dx * dx + dy * dy)
                if abs(radius - outerRadius) < 0.7 || abs(radius - innerRadius) < 0.55 {
                    blend(&out, size, x, y, 88, 93, 103, 74)
                }
                if x == Int(center) || y == Int(center) {
                    blend(&out, size, x, y, 88, 93, 103, 52)
                }
            }
        }
    }

    private nonisolated static func drawSkinReference(
        _ out: inout [UInt8],
        _ size: Int,
        referenceDegrees: Double,
        toleranceDegrees: Double
    ) {
        let center = (Double(size - 1) / 2, Double(size - 1) / 2)
        let radius = Double(size - 1) * 0.455
        let tolerance = max(2, min(30, toleranceDegrees))

        // Subtle tolerance wedge behind the trace.
        for y in 0..<size {
            for x in 0..<size {
                let dx = Double(x) - center.0
                let dy = center.1 - Double(y)
                let distance = sqrt(dx * dx + dy * dy)
                guard distance <= radius else { continue }
                var angle = atan2(dy, dx) * 180 / .pi
                if angle < 0 { angle += 360 }
                var delta = angle - referenceDegrees
                while delta > 180 { delta -= 360 }
                while delta < -180 { delta += 360 }
                if abs(delta) <= tolerance {
                    blend(&out, size, x, y, 255, 167, 70, 8)
                }
            }
        }

        let origin = (Int(center.0.rounded()), Int(center.1.rounded()))
        for angle in [referenceDegrees - tolerance, referenceDegrees + tolerance] {
            let end = polar(center: center, radius: radius, degrees: angle)
            drawLine(&out, size, size, origin, end, 255, 166, 68, 80)
        }
        let end = polar(center: center, radius: radius, degrees: referenceDegrees)
        drawDashedLine(&out, size, size, origin, end, 255, 177, 78, 226)
    }

    private nonisolated static func drawVectorTargets(_ out: inout [UInt8], _ size: Int) {
        let targets: [(Float, Float, Float, (UInt8, UInt8, UInt8))] = [
            (1, 0, 0, (255, 76, 90)),
            (1, 1, 0, (247, 210, 75)),
            (0, 1, 0, (76, 226, 132)),
            (0, 1, 1, (78, 214, 226)),
            (0, 0, 1, (82, 150, 255)),
            (1, 0, 1, (221, 91, 226))
        ]
        for (r, g, b, color) in targets {
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let cb = (b - luma) / (2 * (1 - 0.0722))
            let cr = (r - luma) / (2 * (1 - 0.2126))
            let x = min(size - 1, max(0, Int(((cb + 0.5) * Float(size - 1)).rounded())))
            let y = min(size - 1, max(0, Int(((0.5 - cr) * Float(size - 1)).rounded())))
            for oy in -3...3 {
                for ox in -3...3 where abs(ox) == 3 || abs(oy) == 3 {
                    blend(&out, size, x + ox, y + oy, color.0, color.1, color.2, 150)
                }
            }
        }
    }

    private nonisolated static func drawChromaticityGrid(
        _ out: inout [UInt8], _ width: Int, _ height: Int
    ) {
        for fraction in [0.25, 0.5, 0.75] {
            let x = Int(Double(width - 1) * fraction)
            let y = Int(Double(height - 1) * fraction)
            for yy in 0..<height { blend(&out, width, x, yy, 75, 80, 89, 44) }
            for xx in 0..<width { blend(&out, width, xx, y, 75, 80, 89, 44) }
        }
        func plot(_ xy: (Double, Double)) -> (Int, Int) {
            (
                min(width - 1, max(0, Int((xy.0 / 0.8 * Double(width - 1)).rounded()))),
                min(height - 1, max(0, Int(((1 - xy.1 / 0.9) * Double(height - 1)).rounded())))
            )
        }
        let red = plot((0.708, 0.292))
        let green = plot((0.170, 0.797))
        let blue = plot((0.131, 0.046))
        let white = plot((0.3127, 0.3290))
        drawLine(&out, width, height, red, green, 112, 118, 129, 122)
        drawLine(&out, width, height, green, blue, 112, 118, 129, 122)
        drawLine(&out, width, height, blue, red, 112, 118, 129, 122)
        let markers: [((Int, Int), (UInt8, UInt8, UInt8))] = [
            (red, (255, 76, 90)),
            (green, (76, 226, 132)),
            (blue, (82, 150, 255)),
            (white, (232, 232, 232))
        ]
        for (point, color) in markers {
            for oy in -2...2 {
                for ox in -2...2 {
                    blend(&out, width, point.0 + ox, point.1 + oy, color.0, color.1, color.2, 180)
                }
            }
        }
    }

    private nonisolated static func polar(
        center: (Double, Double), radius: Double, degrees: Double
    ) -> (Int, Int) {
        let radians = degrees * .pi / 180
        return (
            Int((center.0 + radius * cos(radians)).rounded()),
            Int((center.1 - radius * sin(radians)).rounded())
        )
    }

    private nonisolated static func drawDashedLine(
        _ out: inout [UInt8], _ width: Int, _ height: Int,
        _ a: (Int, Int), _ b: (Int, Int),
        _ r: UInt8, _ g: UInt8, _ blue: UInt8, _ alpha: UInt8
    ) {
        let dx = b.0 - a.0
        let dy = b.1 - a.1
        let steps = max(1, max(abs(dx), abs(dy)))
        for i in 0...steps where (i / 5) % 2 == 0 {
            let t = Double(i) / Double(steps)
            let x = Int((Double(a.0) + Double(dx) * t).rounded())
            let y = Int((Double(a.1) + Double(dy) * t).rounded())
            if x >= 0, x < width, y >= 0, y < height {
                blend(&out, width, x, y, r, g, blue, alpha)
            }
        }
    }

    private nonisolated static func drawLine(
        _ out: inout [UInt8], _ width: Int, _ height: Int,
        _ a: (Int, Int), _ b: (Int, Int),
        _ r: UInt8, _ g: UInt8, _ blue: UInt8, _ alpha: UInt8
    ) {
        let dx = b.0 - a.0
        let dy = b.1 - a.1
        let steps = max(1, max(abs(dx), abs(dy)))
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let x = Int((Double(a.0) + Double(dx) * t).rounded())
            let y = Int((Double(a.1) + Double(dy) * t).rounded())
            if x >= 0, x < width, y >= 0, y < height {
                blend(&out, width, x, y, r, g, blue, alpha)
            }
        }
    }

    private nonisolated static func blend(
        _ out: inout [UInt8], _ width: Int, _ x: Int, _ y: Int,
        _ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8
    ) {
        guard x >= 0, y >= 0, x < width else { return }
        let height = out.count / (width * 4)
        guard y < height else { return }
        let p = (y * width + x) * 4
        let alpha = Double(a) / 255
        let inverse = 1 - alpha
        out[p] = UInt8(clamping: Int((Double(out[p]) * inverse + Double(r) * alpha).rounded()))
        out[p + 1] = UInt8(clamping: Int((Double(out[p + 1]) * inverse + Double(g) * alpha).rounded()))
        out[p + 2] = UInt8(clamping: Int((Double(out[p + 2]) * inverse + Double(b) * alpha).rounded()))
        out[p + 3] = 255
    }

    private nonisolated static func clamp01(_ value: Float) -> Float {
        max(0, min(1, value))
    }
}
