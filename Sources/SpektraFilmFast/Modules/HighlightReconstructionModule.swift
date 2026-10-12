// Highlight Reconstruction module - guided Laplacians method
// Equivalent to Darktable's highlights module (DT_IOP_HIGHLIGHTS_LAPLACIAN)

import Foundation
import Metal
import simd

final class HighlightReconstructionModule: PixelpipeModule {
    let name = "highlights"
    let order = ModuleOrder.highlightRecon
    let inputColorSpace: PixelpipeColorSpace = .raw
    let outputColorSpace: PixelpipeColorSpace = .raw
    nonisolated(unsafe) var isEnabled: Bool = true
    nonisolated(unsafe) var blendingOpacity: Float = 1.0

    // Parameters matching Darktable
    nonisolated(unsafe) var mode: Mode = .opposed
    nonisolated(unsafe) var clipThreshold: Float = 1.0  // Clipping threshold
    nonisolated(unsafe) var scale: Scale = .scale7  // Diameter of reconstruction
    nonisolated(unsafe) var iterations: Int = 30  // Number of iterations
    nonisolated(unsafe) var strength: Float = 0.0  // Overall strength
    nonisolated(unsafe) var candidating: Float = 0.4  // Candidating threshold
    nonisolated(unsafe) var combine: Float = 2.0  // Combine factor
    nonisolated(unsafe) var recovery: RecoveryMode = .off
    nonisolated(unsafe) var solidColor: Float = 0.0  // Flat color inpaint
    nonisolated(unsafe) var noiseLevel: Float = 0.0  // Noise level for wavelet

    enum Mode: Int, Sendable {
        case clip = 0
        case lch = 1
        case inpaint = 2
        case guidedLaplacians = 3
        case segmentation = 4
        case opposed = 5
    }

    enum Scale: Int, Sendable {
        case scale1 = 0  // 2px
        case scale2 = 1  // 4px
        case scale3 = 2  // 8px
        case scale4 = 3  // 16px
        case scale5 = 4  // 32px
        case scale6 = 5  // 64px
        case scale7 = 6  // 128px
        case scale8 = 7  // 256px
        case scale9 = 8  // 512px
    }

    enum RecoveryMode: Int, Sendable {
        case off = 0
        case adapt = 5
        case adaptFlat = 6
        case small = 1
        case large = 2
        case smallFlat = 3
        case largeFlat = 4
    }

    func canProcess(_ input: any PipelineBuffer) -> Bool {
        input.asRawMosaic != nil
    }

    func process(_ input: any PipelineBuffer, context: inout PixelpipeContext) throws -> any PipelineBuffer {
        guard let rawInput = input.asRawMosaic else {
            throw PipelineError.wrongBufferType
        }
        guard isEnabled else { return rawInput }
        guard rawInput.width > 0, rawInput.height > 0,
            rawInput.pixels.count >= rawInput.width * rawInput.height
        else { return rawInput }

        switch mode {
        case .clip:
            return processClip(rawInput)
        case .opposed:
            return processOpposed(rawInput)
        case .lch, .inpaint, .segmentation, .guidedLaplacians:
            // Not ported yet. Reporting loudly beats silently passing pixels
            // through unchanged and implying the edit was applied.
            throw PipelineError.unsupportedModule
        }
    }

    // MARK: - Verified ports

    /// darktable src/iop/highlights.c:56
    /// `static float highlights_clip_magics[6] = { 1.0f, 1.0f, 0.987f, 0.995f, 0.987f, 0.987f }`
    /// indexed by `dt_iop_highlights_mode_t`.
    private static let clipMagics: [Float] = [1.0, 1.0, 0.987, 0.995, 0.987, 0.987]

    /// darktable `fcol(row, col, filters, xtrans)`: CFA colour index at (row, col).
    private func cfa(row: Int, col: Int, filters: UInt32, xtrans: [[UInt8]]?) -> Int {
        if filters == 9 {
            guard let xtrans, xtrans.count >= 6 else { return 0 }
            return Int(xtrans[row % 6][col % 6])
        }
        return Int((filters >> (((row & 1) * 2 + (col & 1)) * 2)) & 3)
    }

    /// darktable `process_clip` (Bayer/X-Trans branch):
    /// `out[ox] = fminf(in[ix], clips[c])`
    private func processClip(_ input: RawMosaicF32) -> RawMosaicF32 {
        let clipper = clipThreshold * Self.clipMagics[mode.rawValue]
        var output = input
        for row in 0..<input.height {
            for col in 0..<input.width {
                let idx = row * input.width + col
                // darktable builds `dt_aligned_pixel_t clips = {clip,clip,clip,clip}`
                // and writes `fminf(in[ix], clips[c])`, so the CFA colour index
                // does not change the result here.
                output.pixels[idx] = min(input.pixels[idx], clipper)
            }
        }
        return output
    }

    /// darktable `segbased.c:_calc_refavg` with `linear = TRUE` and
    /// `correction = (1,1,1)` (no late white-balance correction here).
    private func calcRefAvg(
        _ pixels: [Float],
        width: Int,
        height: Int,
        row: Int,
        col: Int,
        filters: UInt32,
        xtrans: [[UInt8]]?
    ) -> Float {
        let color = cfa(row: row, col: col, filters: filters, xtrans: xtrans)
        var mean = [Float](repeating: 0, count: 4)
        var cnt = [Float](repeating: 0, count: 4)

        let dymin = max(0, row - 1)
        let dxmin = max(0, col - 1)
        let dymax = min(height - 1, row + 2)
        let dxmax = min(width - 1, col + 2)

        for dy in dymin..<dymax {
            for dx in dxmin..<dxmax {
                let val = max(0, pixels[dy * width + dx])
                let c = cfa(row: dy, col: dx, filters: filters, xtrans: xtrans)
                mean[c] += val
                cnt[c] += 1
            }
        }
        for c in 0..<4 where cnt[c] > 0 {
            mean[c] = Float(cbrt(Double(mean[c] / cnt[c])))
        }

        let crootRefAvg: [Float] = [
            0.5 * (mean[1] + mean[2]),
            0.5 * (mean[0] + mean[2]),
            0.5 * (mean[0] + mean[1]),
            0.0,  // darktable leaves index 3 at 0
        ]
        return color < 3 ? crootRefAvg[color] * crootRefAvg[color] * crootRefAvg[color] : 0
    }

    /// darktable `opposed.c:_mask_dilated`.
    private func maskDilated(_ mask: [UInt8], at index: Int, w1: Int) -> UInt8 {
        if mask[index] != 0 { return 1 }
        func at(_ o: Int) -> UInt8 { mask[index + o] }
        if (at(-w1 - 1) | at(-w1) | at(-w1 + 1) | at(-1) | at(1)
            | at(w1 - 1) | at(w1) | at(w1 + 1)) != 0
        {
            return 1
        }
        let w2 = 2 * w1, w3 = 3 * w1
        let offsets = [
            -w3 - 2, -w3 - 1, -w3, -w3 + 1, -w3 + 2,
            -w2 - 3, -w2 - 2, -w2 - 1, -w2, -w2 + 1, -w2 + 2, -w2 + 3,
            -w1 - 3, -w1 - 2, -w1 + 2, -w1 + 3,
            -3, -2, 2, 3,
            w1 - 3, w1 - 2, w1 + 2, w1 + 3,
            w2 - 3, w2 - 2, w2 - 1, w2, w2 + 1, w2 + 2, w2 + 3,
            w3 - 2, w3 - 1, w3, w3 + 1, w3 + 2,
        ]
        for o in offsets where at(o) != 0 { return 1 }
        return 0
    }

    /// darktable `opposed.c:_process_opposed` with `keep = FALSE`
    /// (the path darktable takes for Bayer sensors in `highlights.c`).
    private func processOpposed(_ input: RawMosaicF32) -> RawMosaicF32 {
        let width = input.width
        let height = input.height
        let pixels = input.pixels
        let filters = input.filters
        let xtrans = input.xtrans
        let mwidth = width / 3
        let mheight = height / 3
        let clipval = clipThreshold * Self.clipMagics[mode.rawValue]
        // correction = 1 in this pipeline, so a single clip level is used
        let clips = (0..<4).map { _ in clipval }

        var chrominance = [Float](repeating: 0, count: 4)
        var output = pixels

        guard mwidth > 6, mheight > 6 else {
            // Too small for the 3x3 superpixel mask; nothing clipped to work with.
            for idx in pixels.indices { output[idx] = pixels[idx] }
            return rebuilt(input, pixels: output)
        }

        // darktable over-allocates with dt_round_size(mw, 8) * dt_round_size(mh, 8).
        // That padding is load-bearing: _raw_to_cmap addresses the *full* image
        // grid, so a 40px-wide image yields mdx up to 13*13+13 = 182, which is out
        // of range for a bare mwidth*mheight (169) buffer.
        let msize = ((mwidth + 7) / 8 * 8) * ((mheight + 7) / 8 * 8)
        var mask = [UInt8](repeating: 0, count: 6 * msize)
        var anyClipped = false

        // Step 1: mark 3x3 superpixels that contain clipped photosites.
        for mrow in 0..<mheight {
            let irow = 3 * mrow
            for mcol in 0..<mwidth {
                let icol = 3 * mcol
                var mbuff = [UInt8](repeating: 0, count: 3)
                for y in irow..<(irow + 3) {
                    guard y < height else { continue }
                    for x in icol..<(icol + 3) {
                        guard x < width else { continue }
                        // opposed.c: `for_three_channels(c) if(input[idx] >= clips[c])`.
                        // The CFA colour plays no part here -- a clipped photosite marks
                        // every channel mask at its 3x3 cmap position.
                        for ch in 0..<3 where pixels[y * width + x] >= clips[ch] {
                            mbuff[ch] = 1
                        }
                    }
                }
                let mx = mrow * mwidth + mcol
                for ch in 0..<3 {
                    if mbuff[ch] != 0 {
                        mask[ch * msize + mx] = 1
                        anyClipped = true
                    }
                }
            }
        }

        if anyClipped {
            // Step 2: dilate so unclipped photosites near clipped data contribute.
            for row in 0..<mheight {
                for col in 0..<mwidth {
                    let mx = row * mwidth + col
                    let safe = col >= 3 && row >= 3 && col < mwidth - 3 && row < mheight - 3
                    for ch in 0..<3 {
                        mask[(ch + 3) * msize + mx] =
                            safe
                            ? maskDilated(mask, at: ch * msize + mx, w1: mwidth)
                            : mask[ch * msize + mx]
                    }
                }
            }

            // Step 3: per-channel chrominance offset from nearby unclipped photosites.
            var sums = [Float](repeating: 0, count: 4)
            var cnts = [Float](repeating: 0, count: 4)
            for row in 0..<height {
                for col in 0..<width {
                    let idx = row * width + col
                    let color = cfa(row: row, col: col, filters: filters, xtrans: xtrans)
                    guard color < 3 else { continue }
                    let inval = pixels[idx]
                    let mdx = (row / 3) * mwidth + (col / 3)
                    if inval < clips[color], inval > 0.2 * clips[color],
                        mask[(color + 3) * msize + mdx] != 0
                    {
                        sums[color] +=
                            inval
                            - calcRefAvg(
                                pixels, width: width, height: height,
                                row: row, col: col,
                                filters: filters, xtrans: xtrans)
                        cnts[color] += 1
                    }
                }
            }
            for ch in 0..<3 {
                chrominance[ch] = cnts[ch] > 100 ? sums[ch] / cnts[ch] : 0
            }
        }

        // Step 4: reconstruct clipped photosites from the opposing channels.
        for row in 0..<height {
            for col in 0..<width {
                let idx = row * width + col
                let color = cfa(row: row, col: col, filters: filters, xtrans: xtrans)
                var oval = pixels[idx]
                if color < 3, oval >= clips[color] {
                    let ref = calcRefAvg(
                        pixels, width: width, height: height,
                        row: row, col: col, filters: filters, xtrans: xtrans)
                    oval = max(oval, ref + chrominance[color])
                }
                output[idx] = oval
            }
        }
        return rebuilt(input, pixels: output)
    }

    private func rebuilt(_ input: RawMosaicF32, pixels: [Float]) -> RawMosaicF32 {
        var output = input
        output.pixels = pixels
        return output
    }
}
