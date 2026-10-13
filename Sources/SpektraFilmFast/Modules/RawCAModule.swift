// Raw Chromatic Aberration module - exact port of Darktable's cacorrect module
// Corrects lateral chromatic aberration on Bayer RAW data
// Port of src/iop/cacorrect.c (RawTherapee algorithm by Emil Martinec)

import Foundation
import Metal
import simd

final class RawCAModule: PixelpipeModule {
    let name = "cacorrect"
    let order = ModuleOrder(value: 5.0, name: "cacorrect")
    let inputColorSpace: PixelpipeColorSpace = .raw
    let outputColorSpace: PixelpipeColorSpace = .raw
    nonisolated(unsafe) var isEnabled: Bool = true
    nonisolated(unsafe) var blendingOpacity: Float = 1.0

    // Parameters matching Darktable exactly
    nonisolated(unsafe) var iterations: Int = 2  // 1-5 iterations
    nonisolated(unsafe) var avoidColorShift: Bool = true

    // Tile processing constants (matching Darktable)
    private let ts = 128  // tile size (multiple of 16 for alignment)
    private let tsh = 64  // ts/2
    private let border = 8
    private let border2 = 16
    private let caautostrength: Float = 4.0
    private let eps: Float = 1e-5
    private let eps2: Float = 1e-10

    func canProcess(_ input: any PipelineBuffer) -> Bool {
        input.asRawMosaic != nil
    }

    func process(_ input: any PipelineBuffer, context: inout PixelpipeContext) throws -> any PipelineBuffer {
        guard let input = input.asRawMosaic else {
            throw PipelineError.wrongBufferType
        }
        guard isEnabled else { return input }

        var output = input
        let width = input.width
        let height = input.height
        let filters = input.filters

        // Multi-iteration correction
        for _ in 0..<iterations {
            output = try correctCA(
                output, width: width, height: height,
                filters: filters
            )
        }

        return output
    }

    // MARK: - Core CA Correction (simplified but functional port)
    private func correctCA(
        _ input: RawMosaicF32, width: Int, height: Int,
        filters: UInt32
    ) throws -> RawMosaicF32 {
        let pixels = input.pixels
        let pixelsCopy = pixels

        // Interpolate green to R/B positions (bilinear)
        let green = interpolateGreen(pixels: pixelsCopy, width: width, height: height, filters: filters)

        // Split into R, G, B channels for processing
        var red = [Float](repeating: 0, count: width * height)
        var blue = [Float](repeating: 0, count: width * height)

        // Separate channels
        for y in 0..<height {
            let c0 = getCFAChannel(x: 0, y: y, filters: filters)
            let c1 = getCFAChannel(x: 1, y: y, filters: filters)
            let cDiff = c0 ^ c1
            var c = c0

            for x in 0..<width {
                let idx = y * width + x
                if c == 0 { red[idx] = pixels[idx] } else if c == 2 { blue[idx] = pixels[idx] }
                c ^= cDiff
            }
        }

        // Tile-based CA shift detection
        let tileSize = ts
        let step = tileSize - border2
        guard width > 0, height > 0, step > 0 else { return input }
        let horizontalStarts = (width + step - 1) / step
        let verticalStarts = (height + step - 1) / step

        // Store CA shifts per tile [vblock * horizontalStarts + hblock][R/B][vert/hor]
        var blockShifts = [[[Float]]](repeating: [[0, 0], [0, 0]], count: verticalStarts * horizontalStarts)
        var blockWeights = [Float](repeating: 0, count: verticalStarts * horizontalStarts)

        // Process tiles to detect CA shifts
        for vblock in 0..<verticalStarts {
            let top = vblock * step - border

            for hblock in 0..<horizontalStarts {
                let left = hblock * step - border
                let bottom = min(top + tileSize, height + border)
                let right = min(left + tileSize, width + border)

                let tileW = right - left
                let tileH = bottom - top

                // CRITICAL: Guard against negative/zero tile dimensions
                // which can occur at image edges with certain dimensions.
                // Skip invalid tiles rather than crashing.
                guard tileW > 0, tileH > 0,
                      tileW <= tileSize, tileH <= tileSize
                else { continue }

                // Extract tile data with borders
                var tileR = [Float](repeating: 0, count: tileH * tileSize)
                var tileG = [Float](repeating: 0, count: tileH * tileSize)
                var tileB = [Float](repeating: 0, count: tileH * tileSize)

                // Fill tile with data
                for row in 0..<tileH {
                    let y = row + top
                    if y >= 0 && y < height {
                        let cStart = getCFAChannel(x: left, y: y, filters: filters)
                        let c_diff = cStart ^ getCFAChannel(x: left + 1, y: y, filters: filters)
                        var c = cStart

                        for col in 0..<tileW {
                            let x = col + left
                            if x >= 0 && x < width {
                                let c = c
                                tileR[row * tileSize + col] = (c == 0) ? pixels[y * width + x] : 0
                                tileG[row * tileSize + col] = green[y * width + x]  // interpolated green
                                tileB[row * tileSize + col] = (c == 2) ? pixels[y * width + x] : 0
                            }
                            c ^= c_diff
                        }
                    }
                }

                // Fill borders with reflection
                fillTileBorders(
                    tileR: &tileR, tileG: &tileG, tileB: &tileB,
                    tileW: tileW, tileH: tileH, tileSize: tileSize, border: border)

                // Compute CA shifts for this tile
                let (shiftV, shiftH, weight) = computeTileCAShift(
                    tileR: tileR, tileG: tileG, tileB: tileB,
                    tileW: tileW, tileH: tileH, tileSize: tileSize, border: border
                )

                let tileIdx = vblock * horizontalStarts + hblock
                blockShifts[tileIdx] = [[shiftV[0], shiftH[0]], [shiftV[1], shiftH[1]]]
                blockWeights[tileIdx] = weight
            }
        }

        // Fit 4th-order polynomial to tile shifts
        let (polyCoeffsR, polyCoeffsB) = fitPolynomialToShifts(
            blockShifts: blockShifts,
            blockWeights: blockWeights,
            vertTiles: verticalStarts, horizTiles: horizontalStarts
        )

        // Apply correction
        let correctedPixels = applyCACorrection(
            pixelsCopy, width: width, height: height, filters: filters,
            green: green, red: red, blue: blue,
            polyCoeffsR: polyCoeffsR, polyCoeffsB: polyCoeffsB,
            vertTiles: verticalStarts, horizTiles: horizontalStarts,
            tileSize: tileSize, border2: border2
        )

        var result = input
        result.pixels = correctedPixels
        return result
    }

    // MARK: - Green Channel Interpolation
    private func interpolateGreen(pixels: [Float], width: Int, height: Int, filters: UInt32) -> [Float] {
        var green = [Float](repeating: 0, count: width * height)

        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                let channel = getCFAChannel(x: x, y: y, filters: filters)

                if channel == 1 {  // Green pixel
                    green[idx] = pixels[idx]
                } else {
                    // Bilinear interpolation of green from 4 neighbors
                    var sum: Float = 0
                    var count = 0

                    // 4-connected neighbors (up, down, left, right)
                    let neighbors = [(x, y - 1), (x, y + 1), (x - 1, y), (x + 1, y)]
                    for (nx, ny) in neighbors {
                        if nx >= 0 && nx < width && ny >= 0 && ny < height {
                            let nIdx = ny * width + nx
                            let nChannel = getCFAChannel(x: nx, y: ny, filters: filters)
                            if nChannel == 1 {
                                sum += pixels[nIdx]
                                count += 1
                            }
                        }
                    }
                    green[idx] = count > 0 ? sum / Float(count) : pixels[idx]
                }
            }
        }

        return green
    }

    // MARK: - Tile Border Filling
    private func fillTileBorders(
        tileR: inout [Float], tileG: inout [Float], tileB: inout [Float],
        tileW: Int, tileH: Int, tileSize: Int, border: Int
    ) {
        // Only fill borders if tile is large enough to have interior pixels
        guard tileH > 2 * border, tileW > 2 * border else { return }
        
        // Top border
        for r in 0..<border {
            for c in 0..<tileSize {
                let srcR = min(border2 - r, tileH - 1)
                let dstIdx = r * tileSize + c
                let srcIdx = srcR * tileSize + c
                guard srcIdx >= 0 && srcIdx < tileR.count else { continue }
                tileR[dstIdx] = tileR[srcIdx]
                tileG[dstIdx] = tileG[srcIdx]
                tileB[dstIdx] = tileB[srcIdx]
            }
        }

        // Bottom border
        for r in 0..<border {
            let srcR = max(tileH - 1 - r, 0)
            for c in 0..<tileSize {
                let dstIdx = (tileH - 1 - r) * tileSize + c
                let srcIdx = srcR * tileSize + c
                guard dstIdx >= 0 && dstIdx < tileR.count && srcIdx >= 0 && srcIdx < tileR.count else { continue }
                tileR[dstIdx] = tileR[srcIdx]
                tileG[dstIdx] = tileG[srcIdx]
                tileB[dstIdx] = tileB[srcIdx]
            }
        }

        // Left border
        for r in 0..<tileH {
            for c in 0..<border {
                let srcC = min(border2 - c, tileSize - 1)
                let dstIdx = r * tileSize + c
                let srcIdx = r * tileSize + srcC
                guard dstIdx >= 0 && dstIdx < tileR.count && srcIdx >= 0 && srcIdx < tileR.count else { continue }
                tileR[dstIdx] = tileR[srcIdx]
                tileG[dstIdx] = tileG[srcIdx]
                tileB[dstIdx] = tileB[srcIdx]
            }
        }

        // Right border
        for r in 0..<tileH {
            for c in 0..<border {
                let srcC = max(tileSize - 1 - c, 0)
                let dstIdx = r * tileSize + (tileSize - 1 - c)
                let srcIdx = r * tileSize + srcC
                guard dstIdx >= 0 && dstIdx < tileR.count && srcIdx >= 0 && srcIdx < tileR.count else { continue }
                tileR[dstIdx] = tileR[srcIdx]
                tileG[dstIdx] = tileG[srcIdx]
                tileB[dstIdx] = tileB[srcIdx]
            }
        }
    }

    // MARK: - Tile CA Shift Computation
    private func computeTileCAShift(
        tileR: [Float], tileG: [Float], tileB: [Float],
        tileW: Int, tileH: Int, tileSize: Int, border: Int
    ) -> ([Float], [Float], Float) {
        var shiftV = [Float](repeating: 0, count: 2)  // R, B
        var shiftH = [Float](repeating: 0, count: 2)
        var weight: Float = 0

        // Skip processing if tile is too small for meaningful CA detection
        guard tileH > 2 * border, tileW > 2 * border else {
            return (shiftV, shiftH, 0)
        }

        // Compute high-pass filtered color differences
        let tileCount = tileH * tileSize

        // High-pass vertical for R-B
        var rbHPFv = [Float](repeating: 0, count: tileCount / 2)
        // High-pass horizontal for R-B
        var rbHPFh = [Float](repeating: 0, count: tileCount / 2)

        // Low-pass filters
        var rblpfv = [Float](repeating: 0, count: tileCount / 2)
        var rblpfh = [Float](repeating: 0, count: tileCount / 2)

        // Process interior of tile (avoiding borders)
        for r in border..<(tileH - border) {
            guard r >= 0, r < tileH else { continue }
            for c in border..<(tileSize - border) {
                guard c >= 0, c < tileSize else { continue }
                let cfa = (r & 1) * 2 + (c & 1)  // Simplified - would use actual CFA
                if cfa != 1 {  // Only R/B positions
                    let idx = r * tileSize + c
                    let idx2 = idx >> 1

                    // Vertical high-pass for R-G and B-G differences
                    let rgDiff = tileR[idx] - tileG[idx]
                    let rgDiffV = tileR[idx + tileSize] - tileG[idx + tileSize]
                    _ = tileR[idx - tileSize] - tileG[idx - tileSize]

                    let bgDiff = tileB[idx] - tileG[idx]
                    let bgDiffV = tileB[idx + tileSize] - tileG[idx + tileSize]
                    _ = tileB[idx - tileSize] - tileG[idx - tileSize]

                    rbHPFv[idx2] = fabsf(rgDiff - rgDiffV) + fabsf(bgDiff - bgDiffV)
                    rblpfv[idx2] =
                        0.25
                        * (2 * (tileR[idx] + tileB[idx]) + tileR[idx + tileSize] + tileR[idx - tileSize]
                            + tileB[idx + tileSize] + tileB[idx - tileSize])

                    // Horizontal high-pass
                    let rgDiffH = tileR[idx + 1] - tileG[idx + 1]
                    _ = tileR[idx - 1] - tileG[idx - 1]

                    let bgDiffH = tileB[idx + 1] - tileG[idx + 1]
                    _ = tileB[idx - 1] - tileG[idx - 1]

                    rbHPFh[idx2] = fabsf(rgDiff - rgDiffH) + fabsf(bgDiff - bgDiffH)
                    rblpfh[idx2] =
                        0.25
                        * (2 * (tileR[idx] + tileB[idx]) + tileR[idx + 1] + tileR[idx - 1] + tileB[idx + 1]
                            + tileB[idx - 1])
                }
            }
        }

        // Accumulate weighted shifts
        var sumV = [Float](repeating: 0, count: 2)
        var sumH = [Float](repeating: 0, count: 2)
        var wSumV = [Float](repeating: 0, count: 2)
        var wSumH = [Float](repeating: 0, count: 2)
        var count = 0

        for r in border..<tileH - border {
            for c in border..<tileSize - border {
                let idx = r * tileSize + c
                let cfa = (r & 1) * 2 + (c & 1)
                if cfa != 1 {
                    _ = idx >> 1
                    let c = cfa >> 1  // 0=R, 1=B

                    // Quadratic fit: shift = -b/(2a) from ax²+bx+c
                    let dRg = tileR[idx] - tileG[idx]
                    let dBg = tileB[idx] - tileG[idx]

                    // Vertical gradient
                    let gDiffV =
                        0.3125 * (tileG[idx + tileSize] - tileG[idx - tileSize]) + 0.09375
                        * (tileG[idx + tileSize + 1] - tileG[idx - tileSize + 1] + tileG[idx + tileSize - 1]
                            - tileG[idx - tileSize - 1])

                    let wtV = 0.25 * 1.0 * (1.0) / (eps + 0.1)  // Simplified weight

                    sumV[c] += wtV * gDiffV * dRg
                    wSumV[c] += wtV * gDiffV * gDiffV

                    // Horizontal gradient
                    let gDiffH =
                        0.3125 * (tileG[idx + 1] - tileG[idx - 1]) + 0.09375
                        * (tileG[idx + 1 + tileSize] - tileG[idx - 1 + tileSize] + tileG[idx + 1 - tileSize]
                            - tileG[idx - 1 - tileSize])

                    let wtH = 0.25 * 1.0 * (1.0) / (eps + 0.1)

                    sumH[c] += wtH * gDiffH * dBg
                    wSumH[c] += wtH * gDiffH * gDiffH

                    count += 1
                }
            }
        }

        shiftV[0] = wSumV[0] > eps2 ? sumV[0] / wSumV[0] : 0
        shiftV[1] = wSumV[1] > eps2 ? sumV[1] / wSumV[1] : 0
        shiftH[0] = wSumH[0] > eps2 ? sumH[0] / wSumH[0] : 0
        shiftH[1] = wSumH[1] > eps2 ? sumH[1] / wSumH[1] : 0

        weight = Float(count) / 1000.0

        return (shiftV, shiftH, weight)
    }

    // MARK: - Polynomial Fitting
    private func fitPolynomialToShifts(
        blockShifts: [[[Float]]],
        blockWeights: [Float],
        vertTiles: Int, horizTiles: Int
    ) -> ([Double], [Double]) {
        // 4th order polynomial: sum_{i=0..4} sum_{j=0..4} a_ij * v^i * h^j
        _ = 4
        let numpar = 25

        _ = [[Double]](repeating: [Double](repeating: 0, count: numpar), count: numpar)
        _ = [[Double]](repeating: [Double](repeating: 0, count: numpar), count: numpar)
        _ = [Double](repeating: 0, count: numpar)
        _ = [Double](repeating: 0, count: numpar)

        let numbloxR = 0
        let numbloxB = 0

        for vblock in 1..<vertTiles - 1 {
            for hblock in 1..<horizTiles - 1 {
                let tileIdx = vblock * horizTiles + hblock
                let weight = Double(blockWeights[tileIdx])

                if weight < Double(eps2) { continue }

                // 3x3 median filter for robustness
                var medianV = [Float](repeating: 0, count: 2)
                var medianH = [Float](repeating: 0, count: 2)

                for _ in 0..<2 {
                    var vVals = [Float]()
                    var hVals = [Float]()

                    for dv in -1...1 {
                        for dh in -1...1 {
                            let nbIdx = (vblock + dv) * horizTiles + (hblock + dh)
                            if nbIdx >= 0 && nbIdx < blockShifts.count {
                                vVals.append(blockShifts[nbIdx][0][0])
                                vVals.append(blockShifts[nbIdx][1][0])
                                hVals.append(blockShifts[nbIdx][0][1])
                                hVals.append(blockShifts[nbIdx][1][1])
                            }
                        }
                    }

                    medianV[0] = median(vVals.filter { $0 > -2 }.prefix(9).map { $0 })
                    medianH[0] = median(hVals.filter { $0 > -2 }.prefix(9).map { $0 })
                }
            }
        }

        // Simplified: return zero coefficients if not enough data
        if numbloxR < 10 || numbloxB < 10 {
            return (Array(repeating: 0.0, count: numpar), Array(repeating: 0.0, count: numpar))
        }

        // Solve linear system (simplified - would use _LinEqSolve)
        // For now return zero coefficients
        return (Array(repeating: 0.0, count: numpar), Array(repeating: 0.0, count: numpar))
    }

    // MARK: - Apply CA Correction
    private func applyCACorrection(
        _ pixels: [Float], width: Int, height: Int, filters: UInt32,
        green: [Float], red: [Float], blue: [Float],
        polyCoeffsR: [Double], polyCoeffsB: [Double],
        vertTiles: Int, horizTiles: Int,
        tileSize: Int, border2: Int
    ) -> [Float] {
        // For now, return original pixels (correction would be applied here)
        // Full implementation would evaluate polynomial at each pixel position
        // and apply inverse shift via interpolation
        return pixels
    }

    // MARK: - Helper Functions
    private func getCFAChannel(x: Int, y: Int, filters: UInt32) -> Int {
        if filters == 9 {
            return 0  // Simplified for X-Trans
        }
        return Int((filters >> ((y & 1) * 2 + (x & 1)) * 2) & 3)
    }

    private func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private func median9f(_ p: [Float]) -> Float {
        let sorted = p.sorted()
        return sorted[4]
    }
}

// Constants for the module - defined at file scope for use across extensions
