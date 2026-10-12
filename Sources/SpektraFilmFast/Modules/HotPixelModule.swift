// Hot Pixel module - exact port of Darktable's hotpixels module
// Detects and corrects abnormally bright pixels by comparing to same-color neighbors
// src/iop/hotpixels.c

import Foundation
import Metal

final class HotPixelModule: PixelpipeModule {
    typealias InputBuffer = RawMosaicF32
    typealias OutputBuffer = RawMosaicF32

    let name = "hotpixels"
    let order = ModuleOrder(value: 6.0, name: "hotpixels")
    let inputColorSpace: PixelpipeColorSpace = .raw
    let outputColorSpace: PixelpipeColorSpace = .raw
    nonisolated(unsafe) var isEnabled: Bool = true
    nonisolated(unsafe) var blendingOpacity: Float = 1.0

    // Parameters matching Darktable exactly
    nonisolated(unsafe) var threshold: Float = 0.05  // Detection threshold
    nonisolated(unsafe) var strength: Float = 0.25  // Multiplier for neighbor comparison
    nonisolated(unsafe) var permissive: Bool = false  // 3 neighbors (true) or 4 (false)
    nonisolated(unsafe) var markFixed: Bool = false  // Mark fixed pixels

    func canProcess(_ input: any PipelineBuffer) -> Bool {
        input.asRawMosaic != nil
    }

    func process(_ input: any PipelineBuffer, context: inout PixelpipeContext) throws -> any PipelineBuffer {
        guard let rawInput = input.asRawMosaic else {
            throw PipelineError.wrongBufferType
        }
        guard isEnabled else { return rawInput }

        let width = rawInput.width
        let height = rawInput.height
        let filters = rawInput.filters
        let xtrans = rawInput.xtrans
        let multiplier = strength
        let thresh = threshold
        let minNeighbours = permissive ? 3 : 4
        guard width > 4, height > 4 else { return rawInput }

        // Verified against darktable src/iop/hotpixels.c _process_bayer /
        // _process_xtrans (GPL-3.0-or-later): neighbours are read from the
        // *input* buffer and the result written to a separate output buffer.
        // Reading from the buffer being mutated made the result depend on scan
        // order: already-corrected pixels were compared while not-yet-visited
        // ones were not.
        let source = rawInput.pixels
        guard source.count >= width * height else { return rawInput }
        var output = source

        let isXTrans = filters == 9
        // darktable _process_xtrans: nearest same-colour neighbours are found by
        // walking this fixed search order (nearest first) and taking the first four
        // hits for the cell's colour.
        let search: [(Int, Int)] = [
            (-1, 0), (1, 0), (0, -1), (0, 1),
            (-1, -1), (-1, 1), (1, -1), (1, 1),
            (-2, 0), (2, 0), (0, -2), (0, 2),
            (-2, -1), (-2, 1), (2, -1), (2, 1),
            (-1, -2), (1, -2), (-1, 2), (1, 2),
        ]
        let xtransOffsets: [[[(dx: Int, dy: Int)]]]? = {
            guard isXTrans, let xtrans, xtrans.count >= 6 else { return nil }
            var table = [[[(dx: Int, dy: Int)]]](repeating: [], count: 6)
            for j in 0..<6 {
                for i in 0..<6 {
                    let c = cfaChannel(x: i, y: j, filters: filters, xtrans: xtrans)
                    var found: [(dx: Int, dy: Int)] = []
                    // FCNxtrans() indexes a periodic 6x6 tile, so a candidate one
                    // step outside the tile still resolves to a real CFA site.
                    for s in search where found.count < 4 {
                        if c == cfaChannel(x: i + s.0, y: j + s.1, filters: filters, xtrans: xtrans) {
                            found.append((dx: s.0, dy: s.1))
                        }
                    }
                    table[j].append(found)
                }
            }
            return table
        }()

        // Process from row 2 to height-2, col 2 to width-2 (need a 2-pixel border)
        for row in 2..<height - 2 {
            let rowBase = row * width
            for col in 2..<width - 2 {
                let idx = rowBase + col
                let value = source[idx]

                // darktable tests the *original* value against the threshold.
                if value <= thresh { continue }

                let mid = value * multiplier
                var count = 0
                var maxNeighbor: Float = 0.0

                if let table = xtransOffsets {
                    for o in table[row % 6][col % 6] {
                        let nx = col + o.dx
                        let ny = row + o.dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let neighborVal = source[ny * width + nx]
                        if mid > neighborVal {
                            count += 1
                            if neighborVal > maxNeighbor { maxNeighbor = neighborVal }
                        }
                    }
                } else {
                    // Bayer: at distance 2 the sample is the same CFA colour by
                    // construction, so no channel test is needed.
                    let offsets = [(-2, 0), (0, -2), (2, 0), (0, 2)]
                    for (dx, dy) in offsets {
                        let nx = col + dx
                        let ny = row + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let neighborVal = source[ny * width + nx]
                        if mid > neighborVal {
                            count += 1
                            if neighborVal > maxNeighbor { maxNeighbor = neighborVal }
                        }
                    }
                }

                if count >= minNeighbours {
                    output[idx] = maxNeighbor
                    if markFixed {
                        // darktable: mark the run of same-colour pixels around
                        // the fix with the original value.
                        let channel = cfaChannel(x: col, y: row, filters: filters, xtrans: xtrans)
                        // Bayer visits every second site (i -= 2); X-Trans visits all of
                        // them and filters on CFA colour (--i).
                        let step = isXTrans ? 1 : 2
                        var i = -2
                        while i >= -10 && i >= -col {
                            let nx = col + i
                            if !isXTrans || cfaChannel(x: nx, y: row, filters: filters, xtrans: xtrans) == channel {
                                output[rowBase + nx] = value
                            }
                            i -= step
                        }
                        i = 2
                        while i <= 10 && i < width - col {
                            let nx = col + i
                            if !isXTrans || cfaChannel(x: nx, y: row, filters: filters, xtrans: xtrans) == channel {
                                output[rowBase + nx] = value
                            }
                            i += step
                        }
                    }
                }
            }
        }

        var result = rawInput
        result.pixels = output
        return result
    }

    /// CFA colour index at (x, y): X-Trans pattern when `filters == 9`, else the
    /// 2x2 Bayer pattern packed into two-bit fields.
    /// darktable `FCNxtrans()`: the X-Trans pattern is a periodic 6x6 tile, so a
    /// coordinate outside one tile wraps into the next. Swift's `%` truncates toward
    /// zero, which would index backwards past the tile, so normalise first.
    private func cfaChannel(x: Int, y: Int, filters: UInt32, xtrans: [[UInt8]]?) -> Int {
        if filters == 9 {
            // xtrans comes from camera metadata, so a malformed tile must not index out of range.
            guard let xtrans, xtrans.count >= 6, xtrans.allSatisfy({ $0.count >= 6 }) else { return 0 }
            return Int(xtrans[((y % 6) + 6) % 6][((x % 6) + 6) % 6])
        }
        return Int((filters >> (((y & 1) * 2 + (x & 1)) * 2)) & 3)
    }
}
