#include <metal_stdlib>
using namespace metal;

// ─────────────────────────────────────────────────────────────────────────
// Sigmoid kernels (PORTED FROM Lightamer)
// Darktable reference: src/iop/sigmoid.c — log-logistic tone mapping
// - sigmoid_per_channel : per-channel path with hue preservation
// - sigmoid_rgb_ratio   : luma-driven path with gamut compression
// ─────────────────────────────────────────────────────────────────────────

inline float sg_loglogistic(
    const float value, const float magnitude, const float paper_exp,
    const float film_fog, const float film_power, const float paper_power)
{
    const float clamped_value = fmax(value, 0.0f);
    const float film_response = pow(film_fog + clamped_value, film_power);
    const float paper_response = magnitude * pow(film_response / (paper_exp + film_response), paper_power);
    return isnan(paper_response) ? magnitude : paper_response;
}

inline float3 sg_loglogistic3(
    const float3 v, const float magnitude, const float paper_exp,
    const float film_fog, const float film_power, const float paper_power)
{
    return float3(
        sg_loglogistic(v.x, magnitude, paper_exp, film_fog, film_power, paper_power),
        sg_loglogistic(v.y, magnitude, paper_exp, film_fog, film_power, paper_power),
        sg_loglogistic(v.z, magnitude, paper_exp, film_fog, film_power, paper_power));
}

inline float3 sg_desaturate_negative(const float3 v)
{
    const float pixel_average = fmax((v.x + v.y + v.z) / 3.0f, 0.0f);
    const float min_value = fmin(fmin(v.x, v.y), v.z);
    const float saturation_factor = min_value < 0.0f ? -pixel_average / (min_value - pixel_average) : 1.0f;
    return pixel_average + saturation_factor * (v - pixel_average);
}

inline int3 sg_pixel_channel_order(const float3 v)
{
    if (v.x >= v.y) {
        if (v.y > v.z) { return int3(2, 1, 0); }
        else if (v.z > v.x) { return int3(1, 0, 2); }
        else if (v.z > v.y) { return int3(1, 2, 0); }
        else { return int3(2, 1, 0); }
    } else {
        if (v.x >= v.z) { return int3(2, 0, 1); }
        else if (v.z > v.y) { return int3(0, 1, 2); }
        else { return int3(0, 2, 1); }
    }
}

inline void sg_preserve_hue_and_energy(
    thread float3 &pix,
    const float3 per_channel,
    const int3 order,
    const float hue_preservation)
{
    const int omin = order.x, omid = order.y, omax = order.z;
    const float pixMin = pix[omin], pixMid = pix[omid], pixMax = pix[omax];
    const float perMin = per_channel[omin], perMid = per_channel[omid], perMax = per_channel[omax];

    const float chroma = pixMax - pixMin;
    const float midscale = chroma != 0.0f ? (pixMid - pixMin) / chroma : 0.0f;
    const float full_hue_correction = perMin + (perMax - perMin) * midscale;
    const float naive_hue_mid = (1.0f - hue_preservation) * perMid + hue_preservation * full_hue_correction;

    const float per_channel_energy = per_channel.x + per_channel.y + per_channel.z;
    const float naive_hue_energy = perMin + naive_hue_mid + perMax;
    const float pix_in_min_plus_mid = pixMin + pixMid;
    const float blend_factor = pix_in_min_plus_mid != 0.0f ? 2.0f * pixMin / pix_in_min_plus_mid : 0.0f;
    const float energy_target = blend_factor * per_channel_energy + (1.0f - blend_factor) * naive_hue_energy;

    if (naive_hue_mid <= perMid) {
        const float corrected_mid =
            ((1.0f - hue_preservation) * perMid
             + hue_preservation
                 * (midscale * perMax + (1.0f - midscale) * (energy_target - perMax)))
            / (1.0f + hue_preservation * (1.0f - midscale));
        pix[omin] = energy_target - perMax - corrected_mid;
        pix[omid] = corrected_mid;
        pix[omax] = perMax;
    } else {
        const float corrected_mid =
            ((1.0f - hue_preservation) * perMid
             + hue_preservation
                 * (perMin * (1.0f - midscale) + midscale * (energy_target - perMin)))
            / (1.0f + hue_preservation * midscale);
        pix[omin] = perMin;
        pix[omid] = corrected_mid;
        pix[omax] = energy_target - perMin - corrected_mid;
    }
}

inline float3 sg_mul9(device const float* m, const float3 v)
{
    return float3(
        m[0] * v.x + m[1] * v.y + m[2] * v.z,
        m[3] * v.x + m[4] * v.y + m[5] * v.z,
        m[6] * v.x + m[7] * v.y + m[8] * v.z);
}

kernel void spektra_sigmoid_per_channel(
    texture2d<float, access::read>  in  [[texture(0)]],
    texture2d<float, access::write> out [[texture(1)]],
    device const float *u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    const float white_target = u[0];
    const float paper_exp = u[2];
    const float film_fog = u[3];
    const float film_power = u[4];
    const float paper_power = u[5];
    const float hue_preservation = u[6];

    float4 i = in.read(gid);
    const float alpha = i.w;

    i.rgb = sg_mul9(u + 7, i.rgb);
    i.rgb = sg_desaturate_negative(i.rgb);
    i.rgb = sg_mul9(u + 16, i.rgb);

    float3 pix = i.rgb;
    const float3 per_channel = sg_loglogistic3(
        pix, white_target, paper_exp, film_fog, film_power, paper_power);

    const int3 order = sg_pixel_channel_order(pix);
    sg_preserve_hue_and_energy(pix, per_channel, order, hue_preservation);

    const float3 result = sg_mul9(u + 25, pix);
    out.write(float4(result, alpha), gid);
}

kernel void spektra_sigmoid_rgb_ratio(
    texture2d<float, access::read>  in  [[texture(0)]],
    texture2d<float, access::write> out [[texture(1)]],
    device const float *u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    const float white_target = u[0];
    const float black_target = u[1];
    const float paper_exp = u[2];
    const float film_fog = u[3];
    const float film_power = u[4];
    const float paper_power = u[5];

    float4 i = in.read(gid);
    const float alpha = i.w;

    float3 v = sg_desaturate_negative(i.rgb);

    const float luma = (v.x + v.y + v.z) / 3.0f;
    const float mapped_luma = sg_loglogistic(
        luma, white_target, paper_exp, film_fog, film_power, paper_power);

    float3 pre;
    if (luma > 1e-9f) {
        pre = (mapped_luma / luma) * v;
    } else {
        pre = float3(mapped_luma);
    }

    const float pixel_min = fmin(fmin(pre.x, pre.y), pre.z);
    const float pixel_max = fmax(fmax(pre.x, pre.y), pre.z);

    const float epsilon = 1e-6f;
    const float display_border_vs_chroma_white =
        (white_target - mapped_luma) / (pixel_max - mapped_luma + epsilon);
    const float display_border_vs_chroma_black =
        (black_target - mapped_luma) / (pixel_min - mapped_luma - epsilon);
    const float display_border_vs_chroma =
        fmin(display_border_vs_chroma_white, display_border_vs_chroma_black);
    const float chroma_vs_mapping_border =
        (mapped_luma - pixel_min) / (mapped_luma + epsilon);

    const float pixel_chroma_adjustment =
        1.0f / (chroma_vs_mapping_border * display_border_vs_chroma + epsilon);
    const float hyperbolic_chroma =
        2.0f * chroma_vs_mapping_border
        / (1.0f - chroma_vs_mapping_border * chroma_vs_mapping_border + epsilon)
        * pixel_chroma_adjustment;

    const float hyperbolic_z = sqrt(hyperbolic_chroma * hyperbolic_chroma + 1.0f);
    const float chroma_factor =
        hyperbolic_chroma / (1.0f + hyperbolic_z) * display_border_vs_chroma;

    const float3 result = mapped_luma + chroma_factor * (pre - mapped_luma);
    out.write(float4(result, alpha), gid);
}
