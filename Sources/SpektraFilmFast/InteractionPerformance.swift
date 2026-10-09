import Foundation
import Accelerate

/// Raw controls that are safe to preview from an already-developed linear frame.
/// Exact CIRAWFilter development is reserved for explicit Accurate Preview / 100% / export.
enum RawInteractiveField: Sendable {
    case temperature
    case tint
}

/// Interactive rendering is intentionally dependency-aware. While the pointer is down,
/// broad halation uses reduced GPU intermediates and grain uses its preview model.
/// Mouse-up keeps the live frame; an explicit
/// Accurate Preview / 100% / export restores the exact look.
enum InteractiveRenderPolicy {
    private static let groupByParameter: [String: String] = Dictionary(
        uniqueKeysWithValues: BridgeCatalog.shared.parameters.map { ($0.name, $0.group) }
    )

    static func previewLook(
        from exactLook: RenderLook,
        changedParameter: String?,
        rawField: RawInteractiveField?
    ) -> RenderLook {
        var look = exactLook
        let group = rawField != nil ? "raw" : changedParameter.flatMap { groupByParameter[$0] }

        // Preserve spatial effects during pointer-rate feedback; use their reduced
        // GPU path instead of switching the look off. Selected export grain is untouched.
        setBool("fastSpatial", true, in: &look)
        setInt("grainModel", 0, in: &look)
        setBool("grainSublayersEnabled", false, in: &look)
        setInt("grainSubLayerCount", 1, in: &look)
        setBool("grainAnimate", false, in: &look)
        if group != "dir" {
            setScalar("dirCouplersDiffusionUm", 0, in: &look)
            setScalar("dirCouplersDiffusionTailUm", 0, in: &look)
        }

        return look
    }

    private static func setBool(_ name: String, _ value: Bool, in look: inout RenderLook) {
        // Insert even when an older sparse project omitted the key. The native renderer has
        // non-zero defaults for some stages (notably DIR), so absence is not equivalent to off.
        look.values[name] = .bool(value)
    }

    private static func setInt(_ name: String, _ value: Int32, in look: inout RenderLook) {
        look.values[name] = .int(value)
    }

    private static func setScalar(_ name: String, _ value: Double, in look: inout RenderLook) {
        look.values[name] = .scalar(value)
    }
}

extension PixelBufferF32 {
    /// Fast, high-quality scale used to derive an interactive frame from a larger cached decode.
    /// This is dramatically cheaper than asking Core Image/CIRAWFilter to develop the RAW again.
    func resized(longEdge targetLongEdge: Int) throws -> PixelBufferF32 {
        guard targetLongEdge > 0, targetLongEdge != Int.max else { return self }
        let currentLongEdge = max(width, height)
        guard currentLongEdge > targetLongEdge else { return self }

        let scale = Double(targetLongEdge) / Double(currentLongEdge)
        let targetWidth = max(1, Int((Double(width) * scale).rounded()))
        let targetHeight = max(1, Int((Double(height) * scale).rounded()))
        var destination = [Float](repeating: 0, count: targetWidth * targetHeight * 4)

        let error: vImage_Error = pixels.withUnsafeBytes { sourceBytes in
            destination.withUnsafeMutableBytes { destinationBytes in
                guard let sourceBase = sourceBytes.baseAddress,
                      let destinationBase = destinationBytes.baseAddress else {
                    return vImage_Error(kvImageNullPointerArgument)
                }

                var source = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: sourceBase),
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width * 4 * MemoryLayout<Float>.size
                )
                var output = vImage_Buffer(
                    data: destinationBase,
                    height: vImagePixelCount(targetHeight),
                    width: vImagePixelCount(targetWidth),
                    rowBytes: targetWidth * 4 * MemoryLayout<Float>.size
                )
                return vImageScale_ARGBFFFF(
                    &source,
                    &output,
                    nil,
                    vImage_Flags(kvImageHighQualityResampling)
                )
            }
        }

        guard error == kvImageNoError else {
            throw NSError(
                domain: "SpektraFilmFast.vImage",
                code: Int(error),
                userInfo: [NSLocalizedDescriptionKey: "Interactive preview resize failed (vImage \(error))."]
            )
        }
        return PixelBufferF32(width: targetWidth, height: targetHeight, pixels: destination)
    }

    /// Applies the persistent post-camera WB offset used by As Shot and Auto modes.
    /// The base image is already developed by CIRAWFilter (or the non-RAW fallback), so this
    /// matrix represents only the photographer's delta from that resolved neutral.
    func applyingWhiteBalanceOffsets(
        _ raw: RawSettings,
        baseTemperature: Double? = nil,
        baseTint: Double? = nil
    ) -> PixelBufferF32 {
        guard raw.whiteBalanceMode != .custom else { return self }
        let miredOffset = raw.temperatureOffsetMired ?? 0
        let tintOffset = raw.tintOffset ?? 0
        guard abs(miredOffset) > 1.0e-9 || abs(tintOffset) > 1.0e-9 else { return self }

        let baseKelvin = Self.clampedKelvin(baseTemperature ?? raw.temperature)
        let targetKelvin = Self.kelvin(baseKelvin: baseKelvin, miredOffset: miredOffset)
        let resolvedBaseTint = (baseTint ?? raw.tint).isFinite ? (baseTint ?? raw.tint) : 0
        let matrix = WBMatrix.rec2020Adaptation(
            sourceKelvin: targetKelvin,
            destinationKelvin: baseKelvin,
            tintDelta: tintOffset
        )
        // Tint in the persistent relative model is a delta from the camera/Auto neutral;
        // only the delta belongs in the adaptation matrix. resolvedBaseTint is intentionally
        // retained as the explicit reference for callers/debugging rather than added twice.
        _ = resolvedBaseTint
        return applyingWBMatrix(matrix)
    }

    /// Pointer-rate WB is calculated from the committed *linear developed source*, never from
    /// a film-rendered/display image. This keeps Bradford adaptation in the color space it was
    /// designed for and makes the live result converge cleanly to the exact CIRAWFilter render.
    func applyingInteractiveWhiteBalance(
        from baseline: RawSettings,
        to target: RawSettings,
        baseTemperature: Double? = nil,
        baseTint: Double? = nil
    ) -> PixelBufferF32 {
        let resolvedBaseKelvin = Self.clampedKelvin(baseTemperature ?? baseline.temperature)
        let resolvedBaseTint = (baseTint ?? baseline.tint).isFinite ? (baseTint ?? baseline.tint) : 0
        let baselineKelvin = baseline.whiteBalanceMode == .custom
            ? Self.clampedKelvin(baseline.temperature)
            : Self.kelvin(baseKelvin: resolvedBaseKelvin, miredOffset: baseline.temperatureOffsetMired ?? 0)
        let targetKelvin = target.whiteBalanceMode == .custom
            ? Self.clampedKelvin(target.temperature)
            : Self.kelvin(baseKelvin: resolvedBaseKelvin, miredOffset: target.temperatureOffsetMired ?? 0)
        let baselineTint = baseline.whiteBalanceMode == .custom
            ? baseline.tint
            : resolvedBaseTint + (baseline.tintOffset ?? 0)
        let targetTint = target.whiteBalanceMode == .custom
            ? target.tint
            : resolvedBaseTint + (target.tintOffset ?? 0)
        guard abs(baselineKelvin - targetKelvin) > 0.001 || abs(baselineTint - targetTint) > 0.001 else {
            return self
        }

        let matrix = WBMatrix.rec2020Adaptation(
            sourceKelvin: targetKelvin,
            destinationKelvin: baselineKelvin,
            tintDelta: targetTint - baselineTint
        )
        return applyingWBMatrix(matrix)
    }

    private func applyingWBMatrix(_ matrix: WBMatrix) -> PixelBufferF32 {
        var output = [Float](repeating: 0, count: pixels.count)
        let transform: [Float] = [
            Float(matrix.m00), Float(matrix.m01), Float(matrix.m02), 0,
            Float(matrix.m10), Float(matrix.m11), Float(matrix.m12), 0,
            Float(matrix.m20), Float(matrix.m21), Float(matrix.m22), 0,
            0, 0, 0, 1
        ]

        let error: vImage_Error = pixels.withUnsafeBytes { sourceBytes in
            output.withUnsafeMutableBytes { destinationBytes in
                transform.withUnsafeBufferPointer { matrixValues in
                    guard let sourceBase = sourceBytes.baseAddress,
                          let destinationBase = destinationBytes.baseAddress,
                          let matrixBase = matrixValues.baseAddress else {
                        return vImage_Error(kvImageNullPointerArgument)
                    }
                    var source = vImage_Buffer(
                        data: UnsafeMutableRawPointer(mutating: sourceBase),
                        height: vImagePixelCount(height),
                        width: vImagePixelCount(width),
                        rowBytes: width * 4 * MemoryLayout<Float>.size
                    )
                    var destination = vImage_Buffer(
                        data: destinationBase,
                        height: vImagePixelCount(height),
                        width: vImagePixelCount(width),
                        rowBytes: width * 4 * MemoryLayout<Float>.size
                    )
                    return vImageMatrixMultiply_ARGBFFFF(
                        &source, &destination, matrixBase, nil, nil,
                        vImage_Flags(kvImageNoFlags)
                    )
                }
            }
        }
        guard error == kvImageNoError else { return self }
        return PixelBufferF32(width: width, height: height, pixels: output)
    }

    static func effectiveKelvin(_ raw: RawSettings) -> Double {
        if raw.whiteBalanceMode == .custom { return clampedKelvin(raw.temperature) }
        return kelvin(baseKelvin: clampedKelvin(raw.temperature), miredOffset: raw.temperatureOffsetMired ?? 0)
    }

    static func effectiveTint(_ raw: RawSettings) -> Double {
        if raw.whiteBalanceMode == .custom { return raw.tint }
        return raw.tint + (raw.tintOffset ?? 0)
    }

    static func kelvin(baseKelvin: Double, miredOffset: Double) -> Double {
        let baseMired = 1_000_000.0 / clampedKelvin(baseKelvin)
        let targetMired = max(20.0, min(600.0, baseMired + miredOffset))
        return clampedKelvin(1_000_000.0 / targetMired)
    }

    static func miredOffset(baseKelvin: Double, targetKelvin: Double) -> Double {
        1_000_000.0 / clampedKelvin(targetKelvin) - 1_000_000.0 / clampedKelvin(baseKelvin)
    }

    static func clampedKelvin(_ value: Double) -> Double {
        min(50_000.0, max(1_667.0, value.isFinite ? value : 6_500.0))
    }

}

private struct WBMatrix: Sendable {
    var m00: Double; var m01: Double; var m02: Double
    var m10: Double; var m11: Double; var m12: Double
    var m20: Double; var m21: Double; var m22: Double

    static let identity = WBMatrix(
        m00: 1, m01: 0, m02: 0,
        m10: 0, m11: 1, m12: 0,
        m20: 0, m21: 0, m22: 1
    )

    static let rec2020ToXYZ = WBMatrix(
        m00: 0.6369580483012914, m01: 0.14461690358620832, m02: 0.1688809751641721,
        m10: 0.2627002120112671, m11: 0.6779980715188708, m12: 0.05930171646986196,
        m20: 0.0, m21: 0.028072693049087428, m22: 1.060985057710791
    )

    static let xyzToRec2020 = WBMatrix(
        m00: 1.7166511879712674, m01: -0.35567078377639233, m02: -0.25336628137365974,
        m10: -0.6666843518324892, m11: 1.6164812366349395, m12: 0.01576854581391113,
        m20: 0.017639857445310783, m21: -0.042770613257808524, m22: 0.9421031212354738
    )

    static let bradford = WBMatrix(
        m00: 0.8951, m01: 0.2664, m02: -0.1614,
        m10: -0.7502, m11: 1.7135, m12: 0.0367,
        m20: 0.0389, m21: -0.0685, m22: 1.0296
    )

    static let bradfordInverse = WBMatrix(
        m00: 0.9869929, m01: -0.1470543, m02: 0.1599627,
        m10: 0.4323053, m11: 0.5183603, m12: 0.0492912,
        m20: -0.0085287, m21: 0.0400428, m22: 0.9684867
    )

    static func rec2020Adaptation(sourceKelvin: Double, destinationKelvin: Double, tintDelta: Double) -> WBMatrix {
        let sourceWhite = whiteXYZ(kelvin: sourceKelvin)
        let destinationWhite = whiteXYZ(kelvin: destinationKelvin)

        let srcLMS = bradford.applying(to: sourceWhite)
        let dstLMS = bradford.applying(to: destinationWhite)
        let diagonal = WBMatrix(
            m00: safeRatio(dstLMS.0, srcLMS.0), m01: 0, m02: 0,
            m10: 0, m11: safeRatio(dstLMS.1, srcLMS.1), m12: 0,
            m20: 0, m21: 0, m22: safeRatio(dstLMS.2, srcLMS.2)
        )

        let temperatureMatrix = xyzToRec2020 * bradfordInverse * diagonal * bradford * rec2020ToXYZ

        // Positive CIRAW-style tint is magenta; negative is green. Keep the interactive
        // approximation conservative so it tracks direction smoothly without overshooting.
        let tintStops = max(-1.0, min(1.0, tintDelta / 150.0)) * 0.32
        let magentaGain = pow(2.0, tintStops)
        let greenGain = 1.0 / magentaGain
        let tintMatrix = WBMatrix(
            m00: magentaGain, m01: 0, m02: 0,
            m10: 0, m11: greenGain, m12: 0,
            m20: 0, m21: 0, m22: magentaGain
        )
        return tintMatrix * temperatureMatrix
    }

    private static func whiteXYZ(kelvin: Double) -> (Double, Double, Double) {
        let t = max(1667.0, min(50000.0, kelvin))
        let x: Double
        if t <= 4000 {
            x = -0.2661239e9 / pow(t, 3) - 0.2343580e6 / pow(t, 2) + 0.8776956e3 / t + 0.179910
        } else {
            x = -3.0258469e9 / pow(t, 3) + 2.1070379e6 / pow(t, 2) + 0.2226347e3 / t + 0.240390
        }

        let y: Double
        if t <= 2222 {
            y = -1.1063814 * pow(x, 3) - 1.34811020 * pow(x, 2) + 2.18555832 * x - 0.20219683
        } else if t <= 4000 {
            y = -0.9549476 * pow(x, 3) - 1.37418593 * pow(x, 2) + 2.09137015 * x - 0.16748867
        } else {
            y = 3.0817580 * pow(x, 3) - 5.87338670 * pow(x, 2) + 3.75112997 * x - 0.37001483
        }

        let safeY = max(y, 1.0e-6)
        return (x / safeY, 1.0, (1.0 - x - y) / safeY)
    }

    private static func safeRatio(_ numerator: Double, _ denominator: Double) -> Double {
        guard abs(denominator) > 1.0e-9 else { return 1.0 }
        return numerator / denominator
    }

    func applying(to v: (Double, Double, Double)) -> (Double, Double, Double) {
        (
            m00 * v.0 + m01 * v.1 + m02 * v.2,
            m10 * v.0 + m11 * v.1 + m12 * v.2,
            m20 * v.0 + m21 * v.1 + m22 * v.2
        )
    }

    static func * (lhs: WBMatrix, rhs: WBMatrix) -> WBMatrix {
        WBMatrix(
            m00: lhs.m00*rhs.m00 + lhs.m01*rhs.m10 + lhs.m02*rhs.m20,
            m01: lhs.m00*rhs.m01 + lhs.m01*rhs.m11 + lhs.m02*rhs.m21,
            m02: lhs.m00*rhs.m02 + lhs.m01*rhs.m12 + lhs.m02*rhs.m22,
            m10: lhs.m10*rhs.m00 + lhs.m11*rhs.m10 + lhs.m12*rhs.m20,
            m11: lhs.m10*rhs.m01 + lhs.m11*rhs.m11 + lhs.m12*rhs.m21,
            m12: lhs.m10*rhs.m02 + lhs.m11*rhs.m12 + lhs.m12*rhs.m22,
            m20: lhs.m20*rhs.m00 + lhs.m21*rhs.m10 + lhs.m22*rhs.m20,
            m21: lhs.m20*rhs.m01 + lhs.m21*rhs.m11 + lhs.m22*rhs.m21,
            m22: lhs.m20*rhs.m02 + lhs.m21*rhs.m12 + lhs.m22*rhs.m22
        )
    }
}
