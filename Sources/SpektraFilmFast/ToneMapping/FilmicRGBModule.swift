import Foundation
import Metal
import simd

// MARK: - FilmicRGB Tone Mapping Module (ported from Lightamer)
/// Wraps the ported `spektra_filmicrgb_v5` Metal kernel as a first-class module.
/// The standalone `FilmicRGBKernels.metal` file is retained as the canonical source;
/// this wrapper embeds an identical copy so the runtime path is self-contained.
final class FilmicRGBModule {
    public struct Params {
        /// Dynamic range in stops (u[0]).
        public var dynamicRange: Float = 6.0
        /// Black exposure offset (u[1]).
        public var blackExposure: Float = 0.0
        /// Grey mid-point (u[2]).
        public var greyValue: Float = 0.18
        /// Output power / gamma (u[3]).
        public var outputPower: Float = 1.0
        /// Saturation mix — -1 = full desaturation, 0 = neutral, +1 = full chroma (u[4]).
        public var saturation: Float = 0.0
        /// Norm clamp min (u[5]) and max (u[6]) for the max-RGB normalization.
        public var normMin: Float = 0.0
        public var normMax: Float = 1.0
        /// Spline latitude min (u[7]) and max (u[8]).
        public var latitudeMin: Float = 0.0
        public var latitudeMax: Float = 1.0
        /// Display black (u[9]) and white (u[10]) for gamut mapping.
        public var displayBlack: Float = 0.0
        public var displayWhite: Float = 1.0
        /// Spline type: 0 = full polynomial, 1 = quadratic, 2 = rational (u[31]/u[32]).
        public var typeToe: Float = 2.0
        public var typeShoulder: Float = 2.0
        /// Per-channel spline coefficients M1..M5 (u[11]..u[27], 5×3 = 15 floats).
        /// We expose the middle coefficients; M1[1], M2[1], ... are set to 0 for the simple path.
        public var splineM1: SIMD3<Float> = .init(0, 0, 0)
        public var splineM2: SIMD3<Float> = .init(1, 0, 0)
        public var splineM3: SIMD3<Float> = .init(0, 0, 0)
        public var splineM4: SIMD3<Float> = .init(0, 0, 0)
        public var splineM5: SIMD3<Float> = .init(0, 0, 0)
        /// Input/output primaries as 3×3 matrices (u+33, u+42).
        public var inputPrimaries: simd_float3x3 = simd_float3x3(columns: (simd_float3(1,0,0), simd_float3(0,1,0), simd_float3(0,0,1)))
        public var outputPrimaries: simd_float3x3 = simd_float3x3(columns: (simd_float3(1,0,0), simd_float3(0,1,0), simd_float3(0,0,1)))
    }

    public static let kernels = #"""
#include <metal_stdlib>
using namespace metal;

// ─────────────────────────────────────────────────────────────────────────
// FilmicRGB kernels (PORTED FROM Lightamer)
// Darktable reference: src/iop/filmicrgb.c — scene-referred filmic view transform
// - filmicrgb_v5: V5 dual-path (max-RGB norm + per-channel) with Yrg gamut mapping
// ─────────────────────────────────────────────────────────────────────────

inline float frb_clip(const float x) {
    return fmax(fmin(x, 1.0f), 0.0f);
}

inline float frb_log_tonemapping_v2(
    const float x, const float grey, const float black, const float dynamic_range)
{
    return frb_clip((log2(x / grey) - black) / dynamic_range);
}

inline float frb_spline(
    const float x,
    device const float *M1, device const float *M2, device const float *M3,
    device const float *M4, device const float *M5,
    const float latitude_min, const float latitude_max,
    const float type_toe, const float type_shoulder)
{
    float result;
    if (x < latitude_min) {
        if (type_toe == 0.0f) {
            result = M1[0] + x * (M2[0] + x * (M3[0] + x * (M4[0] + x * M5[0])));
        } else if (type_toe == 1.0f) {
            result = M1[0] + x * (M2[0] + x * (M3[0] + x * M4[0]));
        } else {
            const float xi = latitude_min - x;
            const float rat = xi * (xi * M2[0] + 1.0f);
            result = M4[0] - M1[0] * rat / (rat + M3[0]);
        }
    } else if (x > latitude_max) {
        if (type_shoulder == 0.0f) {
            result = M1[1] + x * (M2[1] + x * (M3[1] + x * (M4[1] + x * M5[1])));
        } else if (type_shoulder == 1.0f) {
            result = M1[1] + x * (M2[1] + x * (M3[1] + x * M4[1]));
        } else {
            const float xi = x - latitude_max;
            const float rat = xi * (xi * M2[1] + 1.0f);
            result = M4[1] + M1[1] * rat / (rat + M3[1]);
        }
    } else {
        result = M1[2] + x * M2[2];
    }
    return result;
}

inline float3 frb_mul9(device const float *m, const float3 v)
{
    return float3(
        m[0] * v.x + m[1] * v.y + m[2] * v.z,
        m[3] * v.x + m[4] * v.y + m[5] * v.z,
        m[6] * v.x + m[7] * v.y + m[8] * v.z);
}

inline float4 frb_rgb_to_ych(const float3 rgb, device const float *matrix_in)
{
    const float3 lms = frb_mul9(matrix_in, rgb);
    const float y = 0.68990272f * lms.x + 0.34832189f * lms.y;
    const float a = lms.x + lms.y + lms.z;
    const float3 nlms = (a == 0.0f) ? float3(0.0f) : lms / a;
    const float3 grading = float3(
        1.0877193f * nlms.x - 0.66666667f * nlms.y + 0.02061856f * nlms.z,
        -0.0877193f * nlms.x + 1.66666667f * nlms.y - 0.05154639f * nlms.z,
        1.03092784f * nlms.z);
    const float r = grading.x - 0.21902143f;
    const float g = grading.y - 0.54371398f;
    const float c = sqrt(g * g + r * r);
    const float cos_h = c != 0.0f ? r / c : 1.0f;
    const float sin_h = c != 0.0f ? g / c : 1.0f;
    return float4(y, c, cos_h, sin_h);
}

inline float3 frb_ych_to_rgb(const float4 ych, device const float *matrix_out)
{
    const float r = ych.y * ych.z + 0.21902143f;
    const float g = ych.y * ych.w + 0.54371398f;
    const float b = 1.0f - r - g;
    const float3 nlms = float3(
        0.95f * r + 0.38f * g,
        0.05f * r + 0.62f * g + 0.03f * b,
        0.97f * b);
    const float denom = 0.68990272f * nlms.x + 0.34832189f * nlms.y;
    const float scale = (denom == 0.0f) ? 0.0f : ych.x / denom;
    return frb_mul9(matrix_out, nlms * scale);
}

inline float4 frb_desaturate_v4(
    const float4 ych_original, float4 ych_final, const float saturation)
{
    const float chroma_original = ych_original.y * ych_original.x;
    float chroma_final = ych_final.y * ych_final.x;
    const float delta_chroma = saturation * (chroma_original - chroma_final);

    const bool filmic_brightens = (ych_final.x > ych_original.x);
    const bool filmic_resat = (chroma_original < chroma_final);
    const bool filmic_desat = (chroma_original > chroma_final);
    const bool user_resat = (saturation > 0.0f);
    const bool user_desat = (saturation < 0.0f);

    chroma_final = (filmic_brightens && filmic_resat)
        ? (chroma_original + chroma_final) / 2.0f
        : ((user_resat && filmic_desat) || user_desat)
            ? chroma_final + delta_chroma
            : chroma_final;

    ych_final.y = fmax(chroma_final / ych_final.x, 0.0f);
    return ych_final;
}

inline float4 frb_gamut_check_yrg(float4 ych)
{
    const float y = ych.x;
    const float r = ych.y * ych.z + 0.21902143f;
    const float g = ych.y * ych.w + 0.54371398f;
    float max_c = ych.y;
    const float cos_h = ych.z;
    const float sin_h = ych.w;

    if (r < 0.0f) max_c = fmin(-0.21902143f / cos_h, max_c);
    if (g < 0.0f) max_c = fmin(-0.54371398f / sin_h, max_c);
    if (r + g > 1.0f) max_c = fmin((1.0f - 0.21902143f - 0.54371398f) / (cos_h + sin_h), max_c);

    ych.y = max_c;
    return ych;
}

inline float frb_clip_chroma_white_raw(
    device const float *coeffs, const float target_white,
    const float y, const float cos_h, const float sin_h)
{
    const float denominator_Y_coeff =
        coeffs[0] * (0.979381443298969f * cos_h + 0.391752577319588f * sin_h)
        + coeffs[1] * (0.0206185567010309f * cos_h + 0.608247422680412f * sin_h)
        - coeffs[2] * (cos_h + sin_h);
    const float denominator_target_term =
        target_white * (0.68285981628866f * cos_h + 0.482137060515464f * sin_h);
    if (denominator_Y_coeff == 0.0f) return FLT_MAX;
    const float y_asymptote = denominator_target_term / denominator_Y_coeff;
    if (y <= y_asymptote) return FLT_MAX;
    const float denominator = y * denominator_Y_coeff - denominator_target_term;
    const float numerator = -0.427506877216495f
        * (y * (coeffs[0] + 0.856492345150334f * coeffs[1] + 0.554995960637719f * coeffs[2])
           - 0.988237752433297f * target_white);
    return numerator / denominator;
}

inline float frb_clip_chroma_white(
    device const float *coeffs, const float target_white,
    const float y, const float cos_h, const float sin_h)
{
    const float eps = 1e-3f;
    const float max_y = 1.05785528f * target_white;
    const float delta_y = fmax(max_y - y, 0.0f);
    float max_chroma;
    if (delta_y < eps) {
        max_chroma = delta_y / (eps * max_y)
            * frb_clip_chroma_white_raw(coeffs, target_white, (1.0f - eps) * max_y, cos_h, sin_h);
    } else {
        max_chroma = frb_clip_chroma_white_raw(coeffs, target_white, y, cos_h, sin_h);
    }
    return max_chroma >= 0.0f ? max_chroma : FLT_MAX;
}

inline float frb_clip_chroma_black(
    device const float *coeffs, const float cos_h, const float sin_h)
{
    const float denominator =
        coeffs[0] * (0.979381443298969f * cos_h + 0.391752577319588f * sin_h)
        + coeffs[1] * (0.0206185567010309f * cos_h + 0.608247422680412f * sin_h)
        - coeffs[2] * (cos_h + sin_h);
    if (denominator == 0.0f) return FLT_MAX;
    const float numerator = -0.427506877216495f
        * (coeffs[0] + 0.856492345150334f * coeffs[1] + 0.554995960637719f * coeffs[2]);
    const float max_chroma = numerator / denominator;
    return max_chroma >= 0.0f ? max_chroma : FLT_MAX;
}

inline float frb_clip_chroma(
    device const float *matrix_out, const float target_white,
    const float y, const float cos_h, const float sin_h, const float chroma)
{
    const float c_rw = frb_clip_chroma_white(matrix_out + 0, target_white, y, cos_h, sin_h);
    const float c_gw = frb_clip_chroma_white(matrix_out + 3, target_white, y, cos_h, sin_h);
    const float c_bw = frb_clip_chroma_white(matrix_out + 6, target_white, y, cos_h, sin_h);
    const float max_white = fmin(fmin(c_rw, c_gw), c_bw);
    const float c_rb = frb_clip_chroma_black(matrix_out + 0, cos_h, sin_h);
    const float c_gb = frb_clip_chroma_black(matrix_out + 3, cos_h, sin_h);
    const float c_bb = frb_clip_chroma_black(matrix_out + 6, cos_h, sin_h);
    const float max_black = fmin(fmin(c_rb, c_gb), c_bb);
    return fmin(fmin(chroma, max_black), max_white);
}

inline float3 frb_gamut_check_rgb(
    device const float *matrix_in, device const float *matrix_out,
    const float display_black, const float display_white, const float4 ych_in)
{
    float3 rgb_brightened = frb_ych_to_rgb(ych_in, matrix_out);
    const float min_pix = fmin(fmin(rgb_brightened.x, rgb_brightened.y), rgb_brightened.z);
    const float black_offset = fmax(-min_pix, 0.0f);
    rgb_brightened += black_offset;
    const float4 ych_brightened = frb_rgb_to_ych(rgb_brightened, matrix_in);

    const float y = clamp(
        (ych_in.x + ych_brightened.x) / 2.0f,
        1.05785528f * display_black, 1.05785528f * display_white);
    const float cos_h = ych_in.z;
    const float sin_h = ych_in.w;
    const float new_chroma =
        frb_clip_chroma(matrix_out, display_white, y, cos_h, sin_h, ych_in.y);

    const float4 ych = float4(y, new_chroma, cos_h, sin_h);
    float3 rgb_out = frb_ych_to_rgb(ych, matrix_out);
    return clamp(rgb_out, 0.0f, display_white);
}

inline float3 frb_gamut_mapping(
    float4 ych_final, const float4 ych_original,
    device const float *matrix_in, device const float *matrix_out,
    const float display_black, const float display_white)
{
    ych_final.z = ych_original.z;
    ych_final.w = ych_original.w;
    ych_final.x = clamp(
        ych_final.x, 1.05785528f * display_black, 1.05785528f * display_white);
    ych_final = frb_desaturate_v4(ych_original, ych_final, 0.0f);
    ych_final = frb_gamut_check_yrg(ych_final);
    return frb_gamut_check_rgb(matrix_in, matrix_out, display_black, display_white, ych_final);
}

kernel void spektra_filmicrgb_v5(
    texture2d<float, access::read>  in  [[texture(0)]],
    texture2d<float, access::write> out [[texture(1)]],
    device const float *u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    const float dynamic_range = u[0];
    const float black_exposure = u[1];
    const float grey_value = u[2];
    const float output_power = u[3];
    const float saturation = u[4];
    const float norm_min = u[5];
    const float norm_max = u[6];
    const float latitude_min = u[7];
    const float latitude_max = u[8];
    const float display_black = u[9];
    const float display_white = u[10];
    device const float *M1 = u + 11;
    device const float *M2 = u + 15;
    device const float *M3 = u + 19;
    device const float *M4 = u + 23;
    device const float *M5 = u + 27;
    const float type_toe = u[31];
    const float type_shoulder = u[32];
    device const float *matrix_in = u + 33;
    device const float *matrix_out = u + 42;

    float4 i = in.read(gid);
    const float alpha = i.w;
    const float3 pix = i.rgb;

    float norm = clamp(fmax(fmax(pix.x, pix.y), pix.z), norm_min, norm_max);
    float3 ratios = pix / norm;

    norm = frb_log_tonemapping_v2(norm, grey_value, black_exposure, dynamic_range);
    norm = pow(
        clamp(
            frb_spline(norm, M1, M2, M3, M4, M5, latitude_min, latitude_max,
                       type_toe, type_shoulder),
            display_black, display_white),
        output_power);

    float3 max_rgb = norm * ratios;

    float3 naive;
    naive.x = frb_log_tonemapping_v2(pix.x, grey_value, black_exposure, dynamic_range);
    naive.y = frb_log_tonemapping_v2(pix.y, grey_value, black_exposure, dynamic_range);
    naive.z = frb_log_tonemapping_v2(pix.z, grey_value, black_exposure, dynamic_range);
    naive.x = frb_spline(naive.x, M1, M2, M3, M4, M5, latitude_min, latitude_max,
                         type_toe, type_shoulder);
    naive.y = frb_spline(naive.y, M1, M2, M3, M4, M5, latitude_min, latitude_max,
                         type_toe, type_shoulder);
    naive.z = frb_spline(naive.z, M1, M2, M3, M4, M5, latitude_min, latitude_max,
                         type_toe, type_shoulder);
    naive = pow(clamp(naive, 0.0f, display_white), output_power);

    float3 o = (0.5f - saturation) * naive + (0.5f + saturation) * max_rgb;

    const float4 ych_original = frb_rgb_to_ych(pix, matrix_in);
    float4 ych_final = frb_rgb_to_ych(o, matrix_in);
    ych_final.y = fmin(ych_original.y, ych_final.y);
    const float3 result = frb_gamut_mapping(
        ych_final, ych_original, matrix_in, matrix_out, display_black, display_white);

    out.write(float4(result, alpha), gid);
}
"""#

    private var pieceBuffer: MTLBuffer?
    private let device: any MTLDevice
    private var committed: Params?

    public init(device: any MTLDevice) {
        self.device = device
    }

    private enum UniformLayout {
        static let floatCount = 51
        static let laneBase = 11
        static let toeType = 31
        static let shoulderType = 32
        static let matrixIn = 33
        static let matrixOut = 42
    }

    public func commitParams(_ params: Params) {
        committed = params
        // Uniform layout: 51 floats (Lightamer contract): u[0]..u[10] scalars,
        // M1..M5 lanes (5×4=20), u[31] type_toe, u[32] type_shoulder,
        // matrix_in (9), matrix_out (9).
        var floats = [Float](repeating: 0, count: UniformLayout.floatCount)
        floats[0] = params.dynamicRange
        floats[1] = params.blackExposure
        floats[2] = params.greyValue
        floats[3] = params.outputPower
        floats[4] = params.saturation
        floats[5] = params.normMin
        floats[6] = params.normMax
        floats[7] = params.latitudeMin
        floats[8] = params.latitudeMax
        floats[9] = params.displayBlack
        floats[10] = params.displayWhite

        // M1..M5 lanes (each 4 floats: toe, shoulder, linear, pad)
        let lanes = [params.splineM1, params.splineM2, params.splineM3,
                     params.splineM4, params.splineM5]
        for (index, lane) in lanes.enumerated() {
            let base = UniformLayout.laneBase + index * 4
            floats[base + 0] = lane.x
            floats[base + 1] = lane.y
            floats[base + 2] = lane.z
            floats[base + 3] = 0
        }

        floats[UniformLayout.toeType] = params.typeToe
        floats[UniformLayout.shoulderType] = params.typeShoulder

        let mIn = params.inputPrimaries
        floats.replaceSubrange(UniformLayout.matrixIn..<(UniformLayout.matrixIn + 9), with: [
            mIn[0].x, mIn[0].y, mIn[0].z,
            mIn[1].x, mIn[1].y, mIn[1].z,
            mIn[2].x, mIn[2].y, mIn[2].z
        ])
        let mOut = params.outputPrimaries
        floats.replaceSubrange(UniformLayout.matrixOut..<(UniformLayout.matrixOut + 9), with: [
            mOut[0].x, mOut[0].y, mOut[0].z,
            mOut[1].x, mOut[1].y, mOut[1].z,
            mOut[2].x, mOut[2].y, mOut[2].z
        ])

        precondition(floats.count == UniformLayout.floatCount)

        if pieceBuffer == nil {
            pieceBuffer = device.makeBuffer(
                bytes: floats, length: floats.count * MemoryLayout<Float>.size,
                options: .storageModeShared
            )
        } else if let buffer = pieceBuffer {
            floats.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: floats.count * 4) }
        }
    }

    public func encode(commandBuffer: MTLCommandBuffer, input: MTLTexture, output: MTLTexture, width: Int, height: Int) throws {
        guard let buffer = pieceBuffer else { return }
        let library = try device.makeLibrary(source: Self.kernels, options: nil)
        guard let function = library.makeFunction(name: "spektra_filmicrgb_v5") else { return }
        let pipeline = try device.makeComputePipelineState(function: function)
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                               threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()
    }
}
