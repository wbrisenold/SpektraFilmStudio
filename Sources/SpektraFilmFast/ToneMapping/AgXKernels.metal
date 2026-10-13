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
