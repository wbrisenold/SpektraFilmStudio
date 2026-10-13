// Demosaic module - produces scene-linear RGB from a RAW Bayer/X-Trans mosaic.
//
// Current implementation: PPG (Patterned Pixel Guess) interpolation as the
// demosaic path. This is an original approximation, NOT a port of Darktable's
// RCD, AMaZE, or VNG4 algorithms.
//
// The RCD tile-processing code paths (processRCDTile, populateRedBlue,
// populateRedBlueAtGreen, writeTileToOutput) are scaffolding stubs and are
// NOT wired into the active render path. The rcdDemosaic entry point falls
// back to PPG for any image.
//
// IMPORTANT: This module should NOT be described as "RCD" or attributed to
// Darktable's RCD authors in user-facing UI until a verified port exists.

import Foundation
import Metal
import simd

final class DemosaicModule: PixelpipeModule {
    let name = "demosaic"
    let order = ModuleOrder(value: 8.0, name: "demosaic")
    let inputColorSpace: PixelpipeColorSpace = .raw
    let outputColorSpace: PixelpipeColorSpace = .rgb
    nonisolated(unsafe) var isEnabled: Bool = true
    nonisolated(unsafe) var blendingOpacity: Float = 1.0

    // Algorithm selection (RCD is default, matching Darktable)
    nonisolated(unsafe) var algorithm: Algorithm = .ppg

    // RCD-specific parameters
    nonisolated(unsafe) var greenEq: GreenEq = .none
    nonisolated(unsafe) var medianThrs: Float = 0.0
    nonisolated(unsafe) var colorSmoothing: Smooth = .off
    nonisolated(unsafe) var lmmseRefine: LMMSERefine = .basic
    nonisolated(unsafe) var dualThrs: Float = 0.2
    nonisolated(unsafe) var csRadius: Float = 0.0
    nonisolated(unsafe) var csThrs: Float = 0.4
    nonisolated(unsafe) var csBoost: Float = 0.0
    nonisolated(unsafe) var csIter: Int = 8
    nonisolated(unsafe) var csCenter: Float = 0.0
    nonisolated(unsafe) var csEnabled: Bool = false

    enum Algorithm: Int, Sendable {
        case ppg = 0
        case amaze = 1
        case vng4 = 2
        case rcd = 3
        case lmmse = 4
    }

    enum GreenEq: Int, Sendable {
        case none = 0
        case local = 1
        case full = 2
        case both = 3
    }

    enum Smooth: Int, Sendable {
        case off = 0
        case once = 1
        case twice = 2
        case three = 3
        case four = 4
        case five = 5
    }

    enum LMMSERefine: Int, Sendable {
        case basic = 0
        case median = 1
        case median3 = 2
        case refineMedians = 3
        case refine2Medians = 4
    }

    // RCD constants (matching Darktable)
    private let RCD_BORDER = 10
    private let RCD_MARGIN = 9
    private let TILE_SIZE = 256  // DT_RCD_TILESIZE
    private let TILE_VALID = 236  // TILE_SIZE - 2*BORDER
    private let eps: Float = 1e-5
    private let epssq: Float = 1e-10

    // Weighting constants
    private let w1 = 256
    private let w2 = 512
    private let w3 = 768
    private let w4 = 1024

    func canProcess(_ input: any PipelineBuffer) -> Bool {
        input.asRawMosaic != nil
    }

    func process(_ input: any PipelineBuffer, context: inout PixelpipeContext) throws -> any PipelineBuffer {
        guard let rawInput = input.asRawMosaic else {
            throw PipelineError.wrongBufferType
        }
        guard isEnabled else { throw PipelineError.unsupportedModule }

        let width = rawInput.width
        let height = rawInput.height
        let pixels = rawInput.pixels
        let filters = rawInput.filters

        // Never silently substitute PPG when another algorithm was requested.
        // AMaZE/RCD/VNG4/LMMSE require verified implementations before enabling.
        guard algorithm == .ppg else {
            throw PipelineError.invalidConfiguration(
                "Demosaic algorithm \(algorithm) is not implemented; refusing silent PPG substitution")
        }
        // After RawPrepareModule has normalized the mosaic to [0,1+] scene-linear,
        // run demosaic. Do NOT divide by white level again — that was already done
        // in RawPrepare and doing it here would crush highlights.
        let output = try ppgDemosaic(
            pixels: pixels,
            width: width,
            height: height,
            filters: filters
        )

        // Convert from camera sensor color space to linear Rec.2020 working space.
        // The demosaic output is in camera-native color coordinates.
        // We apply the camera color matrix from LibRaw metadata to transform to
        // a standard working space (linear Rec.2020 primaries).
        //
        // If no color matrix is available, the output stays in camera space and
        // the NativeRenderer will treat it as unlabeled camera RGB (not Rec.2020).
        var rgbBuffer = PixelBufferF32(width: width, height: height, pixels: output)
        if let metadata = context.metadata, !metadata.colorMatrix.isEmpty {
            rgbBuffer = try applyCameraToWorkingSpaceConversion(
                rgbBuffer, colorMatrix: metadata.colorMatrix,
                metadata: metadata
            )
        }

        return rgbBuffer
    }

    /// Convert camera-space RGB to linear Rec.2020 working space using the
    /// camera color matrix from LibRaw metadata.
    ///
    /// The LibRaw color matrix (cmatrix) maps camera RGB to XYZ (or linear sRGB).
    /// We chain it with a conversion from linear sRGB/XYZ to linear Rec.2020.
    ///
    /// If the matrix is invalid (all zeros or degenerate), the conversion is skipped.
    private func applyCameraToWorkingSpaceConversion(
        _ buffer: PixelBufferF32,
        colorMatrix: [Float],
        metadata: RawSpeedMetadata
    ) throws -> PixelBufferF32 {
        // LibRaw's color matrix is a 3x4 matrix (cmatrix[3][4]) that maps
        // camera RGB to XYZ. The last column is typically the offset.
        // Layout: [rX, gX, bX, X0, rY, gY, bY, Y0, rZ, gZ, bZ, Z0]
        guard colorMatrix.count == 12 else { return buffer }

        // Extract the 3x3 color matrix (ignore the offset column)
        let m00 = colorMatrix[0], m01 = colorMatrix[1], m02 = colorMatrix[2]
        let m10 = colorMatrix[4], m11 = colorMatrix[5], m12 = colorMatrix[6]
        let m20 = colorMatrix[8], m21 = colorMatrix[9], m22 = colorMatrix[10]

        // Check for valid matrix (not all zeros)
        guard abs(m00) > 1e-10 || abs(m01) > 1e-10 || abs(m02) > 1e-10,
              abs(m10) > 1e-10 || abs(m11) > 1e-10 || abs(m12) > 1e-10,
              abs(m20) > 1e-10 || abs(m21) > 1e-10 || abs(m22) > 1e-10
        else { return buffer }

        // Build the 3x3 camera-to-XYZ matrix
        let camToXYZ = simd_matrix(
            SIMD3<Float>(m00, m01, m02),
            SIMD3<Float>(m10, m11, m12),
            SIMD3<Float>(m20, m21, m22)
        )

        // XYZ to linear Rec.2020 conversion matrix
        // Rec.2020 primaries: R=(0.708, 0.292), G=(0.170, 0.797), B=(0.131, 0.046)
        // D65 white point: (0.3127, 0.3290)
        //
        // XYZ -> linear Rec.2020 matrix (from ITU-R BT.2020-2):
        let xyzToRec2020 = simd_matrix(
            SIMD3<Float>( 1.7166511879712674, -0.35567078377639233, -0.25336628137365974),
            SIMD3<Float>(-0.6666843518324892,  1.6164812366349395,  0.01576854581391113),
            SIMD3<Float>( 0.017639857445310783, -0.042770613368555052,  0.9421031212354738)
        )

        // Combined: camera -> XYZ -> Rec.2020
        let camToRec2020 = xyzToRec2020 * camToXYZ

        // Apply the matrix to each pixel
        var output = buffer.pixels
        let pixelCount = buffer.width * buffer.height
        for i in 0..<pixelCount {
            let idx = i * 4
            let r = output[idx]
            let g = output[idx + 1]
            let b = output[idx + 2]

            let cameraRGB = SIMD3<Float>(r, g, b)
            let rec2020RGB = camToRec2020 * cameraRGB

            output[idx] = rec2020RGB.x
            output[idx + 1] = rec2020RGB.y
            output[idx + 2] = rec2020RGB.z
            // Alpha unchanged
        }

        return PixelBufferF32(width: buffer.width, height: buffer.height, pixels: output)
    }

    // MARK: - RCD scaffolding (NOT wired into the active render path)
    //
    // These functions are retained as scaffolding for a future verified RCD port.
    // They are NOT called by process() — that path uses ppgDemosaic directly.
    //
    // populateRedBlue, populateRedBlueAtGreen, and writeTileToOutput are empty
    // stubs. Any code path reaching them would produce incorrect output.
    private func rcdDemosaic(
        pixels: [Float],
        width: Int,
        height: Int,
        filters: UInt32,
        xtrans: [[UInt8]],
        revscaler: Float
    ) throws -> [Float] {
        // This function is kept for scaffolding purposes only.
        // The active demosaic path uses ppgDemosaic directly.
        fatalError("rcdDemosaic should not be called — use ppgDemosaic instead")
    }

    // MARK: - Single Tile Processing (RCD scaffolding — NOT wired in)
    //
    // This function is scaffolding for a future verified RCD port.
    // It is NOT called by the active render path.
    // The 256x256 hardcoded tile size and stub implementations mean this
    // cannot produce correct output for any image.
    private func processRCDTile(
        pixels: [Float],
        width: Int,
        height: Int,
        filters: UInt32,
        xtrans: [[UInt8]],
        revscaler: Float,
        rowStart: Int,
        colStart: Int,
        rowEnd: Int,
        colEnd: Int,
        tileRows: Int,
        tileCols: Int
    ) throws -> [[Float]] {
        // Scaffolding: would need proper tile buffer allocation, CFA fill,
        // direction discrimination, green population, R/B population,
        // and tile write-back. All currently stub.
        let tileSize = 256
        var rgb = [[Float]](repeating: [Float](repeating: 0, count: tileSize * tileSize), count: 3)

        // Fill CFA data (scaffold)
        for row in 0..<min(tileRows, tileSize) {
            for col in 0..<min(tileCols, tileSize) {
                let srcIdx = (rowStart + row) * width + (colStart + col)
                guard srcIdx < pixels.count else { continue }
                let idx = row * tileSize + col
                rgb[0][idx] = pixels[srcIdx]
                rgb[1][idx] = pixels[srcIdx]
                rgb[2][idx] = pixels[srcIdx]
            }
        }

        return rgb
    }

    // MARK: - PPG Initial Demosaicing (for edges)
    ///
    /// Produces a 4-channel interleaved RGBA buffer (PixelBufferF32 layout):
    /// - R = red CFA samples (interpolated where missing)
    /// - G = green CFA samples (combines G and G2 Bayer positions)
    /// - B = blue CFA samples (interpolated where missing)
    /// - A = 1.0 (fully opaque) everywhere
    ///
    /// The 4 CFA accumulators are mapped as: 0->R, 1->G, 2->B, 3->G2.
    /// G and G2 are averaged into the single green channel.
    private func ppgDemosaic(pixels: [Float], width: Int, height: Int, filters: UInt32) throws -> [Float] {
        var output = [Float](repeating: 0, count: width * height * 4)

        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x

                var sumR: Float = 0
                var sumG: Float = 0
                var sumB: Float = 0
                var sumG2: Float = 0
                var cntR: Float = 0
                var cntG: Float = 0
                var cntB: Float = 0
                var cntG2: Float = 0

                for dy in -1...1 {
                    for dx in -1...1 {
                        let ny = y + dy
                        let nx = x + dx
                        if nx >= 0 && nx < width && ny >= 0 && ny < height {
                            let nIdx = ny * width + nx
                            let nColor = getCFAChannel(row: ny, col: nx, filters: filters)
                            let val = max(0, pixels[nIdx])
                            switch nColor {
                            case 0: sumR += val; cntR += 1
                            case 1: sumG += val; cntG += 1
                            case 2: sumB += val; cntB += 1
                            case 3: sumG2 += val; cntG2 += 1
                            default: break
                            }
                        }
                    }
                }

                let outIdx = idx * 4
                // R channel: average of red CFA samples
                output[outIdx] = cntR > 0 ? sumR / cntR : 0
                // G channel: combine green (1) and green2 (3) averages
                let gAvg = cntG > 0 ? sumG / cntG : 0
                let g2Avg = cntG2 > 0 ? sumG2 / cntG2 : 0
                output[outIdx + 1] = (cntG > 0 && cntG2 > 0) ? (gAvg + g2Avg) * 0.5 : (cntG > 0 ? gAvg : (cntG2 > 0 ? g2Avg : 0))
                // B channel: average of blue CFA samples
                output[outIdx + 2] = cntB > 0 ? sumB / cntB : 0
                // A channel: fully opaque
                output[outIdx + 3] = 1.0
            }
        }

        return output
    }

    // MARK: - RCD Step 1: Direction Discrimination
    private func computeDirections(
        cfa: inout [Float],
        VH_Dir: inout [Float],
        tileRows: Int,
        tileCols: Int,
        filters: UInt32
    ) throws {
        // Step 1.1: Calculate squared vertical and horizontal color difference high pass filter
        var bufferV = [[Float]](repeating: [Float](repeating: 0, count: 256 - 8), count: 3)

        // Vertical buffer rolling
        var V0 = [Float](repeating: 0, count: 256 - 8)
        var V1 = [Float](repeating: 0, count: 256 - 8)
        var V2 = [Float](repeating: 0, count: 256 - 8)

        // Step 1.1: First few rows for initial V buffers
        for row in 3..<min(tileRows - 3, 5) {
            for col in 4..<tileCols - 4 {
                let indx = row * 256 + col
                bufferV[row - 3][col - 4] = sqrf(
                    (cfa[indx - w3] - cfa[indx - w1] - cfa[indx + w1] + cfa[indx + w3])
                        - 3.0 * (cfa[indx - w2] + cfa[indx + w2]) + 6.0 * cfa[indx]
                )
            }
        }

        // Step 1.2: Main direction discrimination loop
        var bufferH = [Float](repeating: 0, count: 256)

        // Rolling V buffers
        V0 = bufferV[0]
        V1 = bufferV[1]
        V2 = bufferV[2]

        for row in 4..<tileRows - 4 {
            // Horizontal pass
            for col in 3..<tileCols - 3 {
                let indx = row * 256 + col
                bufferH[col - 3] = sqrf(
                    (cfa[indx - 3] - cfa[indx - 1] - cfa[indx + 1] + cfa[indx + 3])
                        - 3.0 * (cfa[indx - 2] + cfa[indx + 2]) + 6.0 * cfa[indx]
                )
            }

            // Update V buffers
            for col in 4..<tileCols - 4 {
                let indx = (row + 1) * 256 + col
                V2[col - 4] = sqrf(
                    (cfa[indx - w3] - cfa[indx - w1] - cfa[indx + w1] + cfa[indx + w3])
                        - 3.0 * (cfa[indx - w2] + cfa[indx + w2]) + 6.0 * cfa[indx]
                )
            }

            // Compute VH direction
            for col in 4..<tileCols - 4 {
                let indx = row * 256 + col
                let V_Stat = max(epssq, V0[col - 4] + V1[col - 4] + V2[col - 4])
                let H_Stat = max(epssq, bufferH[col - 4] + bufferH[col - 3] + bufferH[col - 2])
                VH_Dir[indx] = V_Stat / (V_Stat + H_Stat)
            }

            // Roll V buffers
            let tmp = V0
            V0 = V1
            V1 = V2
            V2 = tmp
        }
    }

    // Low pass filter computation
    private func computeLowPassFilter(
        cfa: [Float],
        lpf: inout [Float],
        tileRows: Int,
        tileCols: Int,
        filters: UInt32
    ) {
        for row in 2..<tileRows - 2 {
            let cStart = getCFAChannel(row: row, col: 0, filters: filters) & 1
            var lpIdx = 0
            for col in stride(from: 2 + cStart, to: tileCols - 2, by: 2) {
                let indx = row * 256 + col
                _ = indx / 2
                let val1 = cfa[indx]
                let val2 = 0.5 * (cfa[indx - 256] + cfa[indx + 256] + cfa[indx - 1] + cfa[indx + 1])
                let val3 = 0.25 * (cfa[indx - 257] + cfa[indx - 255] + cfa[indx + 255] + cfa[indx + 257])
                lpf[lpIdx] = val1 + val2 + val3
                lpIdx += 1
            }
        }
    }

    // STEP 3: Populate green at blue and red positions
    private func populateGreen(
        cfa: [Float],
        lpf: [Float],
        rgb: inout [[Float]],
        VH_Dir: [Float],
        tileRows: Int,
        tileCols: Int,
        filters: UInt32
    ) throws {
        for row in 4..<tileRows - 4 {
            let cStart = getCFAChannel(row: row, col: 0, filters: filters) & 1
            var lpIdx = 0

            for col in stride(from: 4 + cStart, to: tileCols - 4, by: 2) {
                let indx = row * 256 + col
                let cfai = cfa[indx]
                let lpfi = lpf[lpIdx]

                // Cardinal gradients
                let N_Grad =
                    eps + abs(cfa[indx - 256] - cfa[indx + 256]) + abs(cfai - cfa[indx - 512])
                    + abs(cfa[indx - 256] - cfa[indx - 768]) + abs(cfa[indx - 512] - cfa[indx - 1024])
                let S_Grad =
                    eps + abs(cfa[indx + 256] - cfa[indx - 256]) + abs(cfai - cfa[indx + 512])
                    + abs(cfa[indx + 256] - cfa[indx + 768]) + abs(cfa[indx + 512] - cfa[indx + 1024])
                let W_Grad =
                    eps + abs(cfa[indx - 1] - cfa[indx + 1]) + abs(cfai - cfa[indx - 2])
                    + abs(cfa[indx - 1] - cfa[indx - 3]) + abs(cfa[indx - 2] - cfa[indx - 4])
                let E_Grad =
                    eps + abs(cfa[indx + 1] - cfa[indx - 1]) + abs(cfai - cfa[indx + 2])
                    + abs(cfa[indx + 1] - cfa[indx + 3]) + abs(cfa[indx + 2] - cfa[indx + 4])

                let N_Est = cfa[indx - 256] * (lpfi + lpfi) / (eps + lpfi + lpf[lpIdx - 256])
                let S_Est = cfa[indx + 256] * (lpfi + lpfi) / (eps + lpfi + lpf[lpIdx + 256])
                let W_Est = cfa[indx - 1] * (lpfi + lpfi) / (eps + lpfi + lpf[lpIdx - 1])
                let E_Est = cfa[indx + 1] * (lpfi + lpfi) / (eps + lpfi + lpf[lpIdx + 1])

                let V_Est = (S_Grad * N_Est + N_Grad * S_Est) / (N_Grad + S_Grad)
                let H_Est = (E_Grad * W_Est + W_Grad * E_Est) / (E_Grad + W_Grad)

                // VH direction discrimination
                let VH_Central = VH_Dir[indx]
                let VH_Neigh =
                    0.25 * (VH_Dir[indx - 257] + VH_Dir[indx - 255] + VH_Dir[indx + 255] + VH_Dir[indx + 257])
                let VH_Disc = (abs(0.5 - VH_Central) < abs(0.5 - VH_Neigh)) ? VH_Neigh : VH_Central

                // Interpolate green
                rgb[1][indx] = interpolate(CLIP(VH_Disc), H_Est, V_Est)

                lpIdx += 1
            }
        }
    }

    // STEP 4: Populate red/blue at blue/red positions (STUB)
    private func populateRedBlue(
        cfa: [Float],
        rgb: inout [[Float]],
        PQ_Dir: [Float],
        tileRows: Int,
        tileCols: Int,
        filters: UInt32
    ) throws {
        // STUB: Not implemented. Would need P/Q diagonal color difference
        // high-pass filter and directional red/blue interpolation.
        throw PipelineError.unsupportedModule
    }

    // Populate R/B at green positions (STUB)
    private func populateRedBlueAtGreen(
        rgb: inout [[Float]],
        VH_Dir: [Float],
        tileRows: Int,
        tileCols: Int,
        filters: UInt32
    ) throws {
        // STUB: Not implemented. Would need directional R/B interpolation
        // at green CFA positions using VH_Dir weighting.
        throw PipelineError.unsupportedModule
    }

    // MARK: - Helper Functions

    private func getCFAChannel(row: Int, col: Int, filters: UInt32) -> Int {
        if filters == 9 {  // X-Trans - simplified
            return 0
        }
        return Int((filters >> ((row & 1) * 2 + (col & 1)) * 2) & 3)
    }

    private func getCFAChannel(row: Int, col: Int, filters: UInt32, xtrans: [[UInt8]]) -> Int {
        if filters == 9 {
            return Int(xtrans[row % 6][col % 6])
        }
        return Int((filters >> ((row & 1) * 2 + (col & 1)) * 2) & 3)
    }

    private func sqrf(_ x: Float) -> Float { x * x }
    private func CLIP(_ x: Float) -> Float { max(0, min(1, x)) }

    private func interpolate(_ x: Float, _ a: Float, _ b: Float) -> Float {
        return a + x * (b - a)
    }

    // Tile output writing (STUB)
    private func writeTileToOutput(
        tileOutput: [[Float]],
        output: inout [Float],
        width: Int,
        rowStart: Int,
        colStart: Int,
        firstVertical: Int,
        lastVertical: Int,
        firstHorizontal: Int,
        lastHorizontal: Int
    ) {
        // STUB: Not implemented. Would need to copy tile RGB data back
        // to the output buffer at the correct position.
    }
}
