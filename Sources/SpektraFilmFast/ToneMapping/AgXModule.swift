import Foundation
import Metal
import simd

// MARK: - AgX Tone Mapping Module (ported from Lightamer)
/// Wraps the ported `spektra_kernel_agx` Metal kernel as a first-class module.
/// The standalone `AgXKernels.metal` file is retained as the canonical source;
/// this wrapper embeds an identical copy so the runtime path is self-contained.
final class AgXModule {
    public struct Params: Codable, Hashable, Sendable {
        /// Exposure offset in EV applied before the log encoding (u[24] lift is separate).
        public var exposureEV: Float = 0
        /// Output gamma / power applied after tone mapping (u[3]).
        public var outputPower: Float = 1.0
        /// Saturation mix (u[27]) — 0 = full desaturation, 1 = keep, >1 = boost.
        public var saturation: Float = 1.0
        /// Hue preservation mix (u[28]) — how strongly hue is preserved through the tone curve.
        public var huePreservation: Float = 0.0
        /// Look strength / power (u[26]) applied in agx_look when u[29] > 0.
        public var lookPower: Float = 1.0
        /// Look slope (u[25]) and lift (u[24]) — per-channel slope+offset before saturation.
        public var lookSlope: Float = 1.0
        public var lookLift: Float = 0.0
        /// Log-encoding range in EV (u[2]) and minimum EV (u[0]).
        public var logRangeEV: Float = 6.0
        public var logMinEV: Float = -6.0
        /// Gamut compression enabled (controls agx_compress_into_gamut). On by default.
        public var gamutCompression: Bool = true
        /// Enable the per-channel "look" pass (u[29]).
        public var enableLook: Bool = false
        /// Enable hue-before/after preservation (u[30]).
        public var enableHuePreservation: Bool = false
    }

    public static let kernels = #"""
#include <metal_stdlib>
using namespace metal;

// ─────────────────────────────────────────────────────────────────────────
// AgX kernels (PORTED FROM Lightamer)
// Darktable reference: src/iop/agx.c — Blender AgX-inspired filmic variant
// - kernel_agx: full tone mapping pipeline with primaries adjustment
// ─────────────────────────────────────────────────────────────────────────

constant float agx_epsilon = 1e-6;

inline float3 agx_mul9(device const float *m, const float3 v)
{
    return float3(
        m[0] * v.x + m[1] * v.y + m[2] * v.z,
        m[3] * v.x + m[4] * v.y + m[5] * v.z,
        m[6] * v.x + m[7] * v.y + m[8] * v.z);
}

inline void agx_compress_into_gamut(thread float3 &pixel)
{
    const float3 luminance_coeffs = float3(0.2658180370250449f, 0.59846986045365f, 0.1357121025213052f);
    const float input_y = dot(pixel, luminance_coeffs);
    const float max_rgb = max(max(pixel.x, pixel.y), pixel.z);

    const float3 opponent_rgb = max_rgb - pixel;
    const float opponent_y = dot(opponent_rgb, luminance_coeffs);
    const float max_opponent = max(max(opponent_rgb.x, opponent_rgb.y), opponent_rgb.z);
    const float y_compensate_negative = max_opponent - opponent_y + input_y;

    const float min_rgb = min(min(pixel.x, pixel.y), pixel.z);
    const float offset = fmax(-min_rgb, 0.0f);
    const float3 rgb_offset = pixel + offset;

    const float max_of_rgb_offset = max(max(rgb_offset.x, rgb_offset.y), rgb_offset.z);
    const float3 opponent_rgb_offset = max_of_rgb_offset - rgb_offset;

    const float max_inverse_rgb_offset = max(max(opponent_rgb_offset.x, opponent_rgb_offset.y), opponent_rgb_offset.z);
    const float y_inverse_rgb_offset = dot(opponent_rgb_offset, luminance_coeffs);
    float y_new = dot(rgb_offset, luminance_coeffs);
    y_new = max_inverse_rgb_offset - y_inverse_rgb_offset + y_new;

    const float luminance_ratio =
        (y_new > y_compensate_negative && y_new > agx_epsilon)
            ? y_compensate_negative / y_new
            : 1.0f;
    pixel = luminance_ratio * rgb_offset;
}

inline float agx_apply_log_encoding(const float x, const float range_in_ev, const float min_ev)
{
    const float x_relative = fmax(agx_epsilon, x / 0.18f);
    const float mapped = (log2(fmax(x_relative, 0.0f)) - min_ev) / range_in_ev;
    return fmin(fmax(mapped, 0.0f), 1.0f);
}

inline float agx_sigmoid(const float x, const float power)
{
    return x / pow(1.0f + pow(x, power), 1.0f / power);
}

inline float agx_scaled_sigmoid(
    const float x, const float scale, const float slope, const float power,
    const float transition_x, const float transition_y)
{
    return scale * agx_sigmoid(slope * (x - transition_x) / scale, power) + transition_y;
}

inline float agx_fallback_toe(const float x, device const float *u)
{
    const float target_black = u[6];
    const float coefficient = u[12];
    const float power = u[13];
    return x < 0.0f
        ? target_black
        : target_black + fmax(0.0f, coefficient * pow(x, power));
}

inline float agx_fallback_shoulder(const float x, device const float *u)
{
    const float target_white = u[16];
    const float coefficient = u[22];
    const float power = u[23];
    return x >= 1.0f
        ? target_white
        : target_white - fmax(0.0f, coefficient * pow(1.0f - x, power));
}

inline float agx_apply_curve(const float x, device const float *u)
{
    float result;
    if (x < u[8]) {
        result = u[11] > 0.0f
            ? agx_fallback_toe(x, u)
            : agx_scaled_sigmoid(x, u[10], u[14], u[7], u[8], u[9]);
    } else if (x <= u[18]) {
        result = u[14] * x + u[15];
    } else {
        result = u[21] > 0.0f
            ? agx_fallback_shoulder(x, u)
            : agx_scaled_sigmoid(x, u[20], u[14], u[17], u[18], u[19]);
    }
    return clamp(result, u[6], u[16]);
}

inline float agx_apply_slope_offset(const float x, const float slope, const float offset)
{
    const float m = slope / (1.0f + offset);
    const float b = offset * m;
    return m * x + b;
}

inline float3 agx_rgb2hsv(const float3 rgb)
{
    const float mn = min(min(rgb.x, rgb.y), rgb.z);
    const float mx = max(max(rgb.x, rgb.y), rgb.z);
    const float delta = mx - mn;
    float s, h;
    if (fabs(mx) > 1e-6f && fabs(delta) > 1e-6f) {
        s = delta / mx;
        float hue;
        if (rgb.x == mx) {
            hue = (rgb.y - rgb.z) / delta;
        } else if (rgb.y == mx) {
            hue = 2.0f + (rgb.z - rgb.x) / delta;
        } else {
            hue = 4.0f + (rgb.x - rgb.y) / delta;
        }
        hue /= 6.0f;
        h = hue - floor(hue);
    } else {
        s = 0.0f;
        h = 0.0f;
    }
    return float3(h, s, mx);
}

inline float3 agx_hsv2rgb(const float3 hsv)
{
    const float c = hsv.y * hsv.z;
    const float m = hsv.z - c;
    const float h = hsv.x * 6.0f;
    const float i = floor(h);
    const float f = h - i;
    const float fc = f * c;
    const float top = c + m;
    const float inc = fc + m;
    const float dec = top - fc;
    const int idx = int(i) % 6;
    switch (idx) {
        case 0: return float3(top, inc, m);
        case 1: return float3(dec, top, m);
        case 2: return float3(m, top, inc);
        case 3: return float3(m, dec, top);
        case 4: return float3(inc, m, top);
        default: return float3(top, m, dec);
    }
}

inline float agx_lerp_hue(const float original_hue, const float processed_hue, const float mix)
{
    const float shortest_distance = processed_hue - original_hue - rint(processed_hue - original_hue);
    const float mixed_hue = (1.0f - mix) * shortest_distance + original_hue;
    return mixed_hue - floor(mixed_hue);
}

inline void agx_look(thread float3 &pixel, device const float *u)
{
    const float slope = u[25];
    const float lift = u[24];
    const float power = u[26];
    const float sat = u[27];

    float3 temp;
    temp.x = agx_apply_slope_offset(pixel.x, slope, lift);
    temp.y = agx_apply_slope_offset(pixel.y, slope, lift);
    temp.z = agx_apply_slope_offset(pixel.z, slope, lift);

    pixel.x = temp.x > 0.0f ? pow(temp.x, power) : temp.x;
    pixel.y = temp.y > 0.0f ? pow(temp.y, power) : temp.y;
    pixel.z = temp.z > 0.0f ? pow(temp.z, power) : temp.z;

    const float luma = agx_mul9(u + 58, pixel).y;
    pixel = luma + sat * (pixel - luma);
}

inline void agx_tone_mapping(thread float3 &rgb_in_out, device const float *u)
{
    float h_before = 0.0f;
    if (u[30] > 0.0f) {
        h_before = agx_rgb2hsv(rgb_in_out).x;
    }

    float3 transformed;
    transformed.x = agx_apply_curve(agx_apply_log_encoding(rgb_in_out.x, u[2], u[0]), u);
    transformed.y = agx_apply_curve(agx_apply_log_encoding(rgb_in_out.y, u[2], u[0]), u);
    transformed.z = agx_apply_curve(agx_apply_log_encoding(rgb_in_out.z, u[2], u[0]), u);

    if (u[29] > 0.0f) {
        agx_look(transformed, u);
    }

    transformed = pow(fmax(transformed, 0.0f), u[3]);

    if (u[30] > 0.0f) {
        float3 hsv = agx_rgb2hsv(transformed);
        hsv.x = agx_lerp_hue(h_before, hsv.x, u[28]);
        rgb_in_out = agx_hsv2rgb(hsv);
    } else {
        rgb_in_out = transformed;
    }
}

kernel void spektra_kernel_agx(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    device const float *u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    float4 in_pixel = input.read(gid);

    if (any(isnan(in_pixel))) {
        in_pixel = float4(0.0f);
    } else {
        in_pixel = clamp(in_pixel, -1e6f, 1e6f);
    }

    float3 base_rgb = agx_mul9(u + 31, in_pixel.rgb);
    agx_compress_into_gamut(base_rgb);

    float3 rendering_rgb = agx_mul9(u + 40, base_rgb);
    agx_tone_mapping(rendering_rgb, u);

    const float3 out_pixel = agx_mul9(u + 49, rendering_rgb);
    output.write(float4(out_pixel, in_pixel.w), gid);
}
"""#

    private var pieceBuffer: MTLBuffer?
    private let device: any MTLDevice
    private var committed: Params?

    public init(device: any MTLDevice) {
        self.device = device
    }

    public func commitParams(_ params: Params) {
        committed = params
        // AgX uniform layout: 60 floats.
        // u[00] = logMinEV, u[01] = (reserved), u[02] = logRangeEV, u[03] = outputPower,
        // u[04] = saturation, u[05] = norm_min, u[06] = target_black, u[07] = type_toe,
        // u[08] = latitude_min, u[09] = transition_x, u[10] = scale, u[11] = toe M1[0],
        // u[12] = toe coefficient, u[13] = toe power, u[14] = mid slope, u[15] = mid M2[0],
        // u[16] = target_white, u[17] = shoulder transition, u[18] = latitude_max,
        // u[19] = shoulder M3[0], u[20] = shoulder scale, u[21] = shoulder coefficient,
        // u[22] = shoulder coefficient2, u[23] = shoulder power,
        // u[24] = look lift, u[25] = look slope, u[26] = look power, u[27] = look saturation,
        // u[28] = hue preservation, u[29] = enable look, u[30] = enable hue preservation.
        //
        // We keep the matrices at u+31..u+40 (input primaries), u+40..u+49 (rendering),
        // u+49..u+58 (output primaries) as identity for the simple wrapped path.
        var floats = [Float](repeating: 0, count: 60)
        floats[0] = params.logMinEV
        floats[2] = params.logRangeEV
        floats[3] = params.outputPower
        floats[4] = params.saturation
        floats[5] = 0.001 // norm_min
        floats[6] = 0.0   // target_black
        floats[7] = 0.0   // type_toe (0 = spline toe)
        floats[8] = 0.0   // latitude_min
        floats[9] = 0.0   // transition_x
        floats[10] = 1.0  // scale
        floats[11] = 0.0  // toe M1[0]
        floats[12] = 0.5  // toe coefficient
        floats[13] = 1.0  // toe power
        floats[14] = 1.0  // mid slope
        floats[15] = 0.0  // mid M2[0]
        floats[16] = 1.0  // target_white
        floats[17] = 1.0  // shoulder transition
        floats[18] = 1.0  // latitude_max
        floats[19] = 0.0  // shoulder M3[0]
        floats[20] = 1.0  // shoulder scale
        floats[21] = 0.5  // shoulder coefficient
        floats[22] = 0.5  // shoulder coefficient2
        floats[23] = 1.0  // shoulder power
        floats[24] = params.lookLift
        floats[25] = params.lookSlope
        floats[26] = params.lookPower
        floats[27] = params.saturation
        floats[28] = params.huePreservation
        floats[29] = params.enableLook ? 1.0 : 0.0
        floats[30] = params.enableHuePreservation ? 1.0 : 0.0

        // identity matrices at u+31, u+40, u+49
        let identity: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        floats.replaceSubrange(31..<40, with: identity)
        floats.replaceSubrange(40..<49, with: identity)
        floats.replaceSubrange(49..<58, with: identity)

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
        guard let function = library.makeFunction(name: "spektra_kernel_agx") else { return }
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
