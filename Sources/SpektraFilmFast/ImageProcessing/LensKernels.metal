#include <metal_stdlib>
using namespace metal;

// ─────────────────────────────────────────────────────────────────────────
// Lens correction kernels (PORTED FROM Lightamer)
// Darktable reference: src/iop/lens.cc — distortion + TCA + vignetting
// ─────────────────────────────────────────────────────────────────────────

struct LensUniforms {
    float centerX;
    float centerY;
    float halfWidth;
    float halfHeight;
    float k1;
    float k2;
    float k3;
    float k4;
    float tcaRed;
    float tcaGreen;
    float tcaBlue;
    float vigK1;
    float vigK2;
    float vigK3;
    float vigK4;
    float reserved[4];
};

kernel void spektra_lens_correct(
    texture2d<float, access::read>  in  [[texture(0)]],
    texture2d<float, access::write> out [[texture(1)]],
    device const LensUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    float2 pixel = float2(gid) - float2(u.centerX, u.centerY);
    float2 norm = pixel / float2(u.halfWidth, u.halfHeight);
    float r2 = dot(norm, norm);
    float r4 = r2 * r2;
    float r6 = r4 * r2;

    // Distortion correction (inverse polynomial)
    float distortion = 1.0f + u.k1 * r2 + u.k2 * r4 + u.k3 * r6 + u.k4 * r6 * r2;
    float2 correctedNorm = norm / distortion;

    // TCA (lateral chromatic aberration)
    float redOffset = u.tcaRed * norm.x;
    float blueOffset = u.tcaBlue * norm.x;
    float greenOffset = (u.tcaRed + u.tcaBlue) * 0.5f * norm.x;

    float2 redCoord = correctedNorm + float2(redOffset, 0.0f);
    float2 greenCoord = correctedNorm + float2(greenOffset, 0.0f);
    float2 blueCoord = correctedNorm + float2(blueOffset, 0.0f);

    // Convert back to pixel coords
    float2 redPixel = redCoord * float2(u.halfWidth, u.halfHeight) + float2(u.centerX, u.centerY);
    float2 greenPixel = greenCoord * float2(u.halfWidth, u.halfHeight) + float2(u.centerX, u.centerY);
    float2 bluePixel = blueCoord * float2(u.halfWidth, u.halfHeight) + float2(u.centerX, u.centerY);

    // Vignetting correction (division)
    float vigR2 = dot(correctedNorm, correctedNorm);
    float vigCorrection = 1.0f / max(1.0f + u.vigK1 * vigR2 + u.vigK2 * vigR2 * vigR2 + u.vigK3 * vigR2 * vigR2 * vigR2 + u.vigK4 * vigR2 * vigR2 * vigR2 * vigR2, 0.001f);

    // Sample with bilinear interpolation (simplified to nearest here)
    float4 result;
    result.x = in.read(uint2(redPixel)).x * vigCorrection;
    result.y = in.read(uint2(greenPixel)).y * vigCorrection;
    result.z = in.read(uint2(bluePixel)).z * vigCorrection;
    result.w = in.read(gid).w;

    out.write(result, gid);
}
