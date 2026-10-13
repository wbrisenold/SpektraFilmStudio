#include <metal_stdlib>
using namespace metal;

// ─────────────────────────────────────────────────────────────────────────
// Bilateral kernels (PORTED FROM Lightamer)
// Darktable reference: src/iop/bilateral.cc — "surface blur", RGB domain
// Two paths: direct stamp (≤ rad 6) + 5D grid for larger radii
// ─────────────────────────────────────────────────────────────────────────

struct BilateralDirectUniforms {
    int width;
    int height;
    int radius;
    float isig2r;
    float isig2g;
    float isig2b;
};

kernel void spektra_bilateral_direct(
    texture2d<float, access::read>  in  [[texture(0)]],
    texture2d<float, access::write> out [[texture(1)]],
    device const float *weights [[buffer(0)]],
    device const BilateralDirectUniforms &u [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    int w = u.width;
    int h = u.height;
    int rad = u.radius;

    if (gid.x < rad || gid.x >= w - rad || gid.y < rad || gid.y >= h - rad) {
        out.write(in.read(gid), gid);
        return;
    }

    float4 center = in.read(gid);

    float wSum = 0.0f;
    float4 acc = float4(0.0f);

    int wd = 2 * rad + 1;
    for (int l = -rad; l <= rad; l++) {
        for (int k = -rad; k <= rad; k++) {
            int2 nb = int2(gid) + int2(k, l);
            float4 pix = in.read(nb);
            float dr = center.x - pix.x;
            float dg = center.y - pix.y;
            float db = center.z - pix.z;
            float colorDist = dr * dr * u.isig2r + dg * dg * u.isig2g + db * db * u.isig2b;
            float weight = weights[(l + rad) * wd + (k + rad)] * exp(-colorDist);
            wSum += weight;
            acc += pix * weight;
        }
    }

    out.write(acc / float(wSum), gid);
}

struct Bilateral5DUniforms {
    int width;
    int height;
    int originX;
    int originY;
    int baseX;
    int baseY;
    int cellsX;
    int cellsY;
    int cellsR;
    int cellsG;
    int cellsB;
    float sigmaS;
    float sigmaR;
    float sigmaG;
    float sigmaB;
};

kernel void spektra_bilateral5d_splat(
    texture2d<float, access::read>  in  [[texture(0)]],
    device float *grid [[buffer(0)]],
    device const Bilateral5DUniforms &u [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    int w = u.width;
    int h = u.height;

    float4 pix = in.read(gid);
    float r = pix.x, g = pix.y, b = pix.z;

    float sigmaS = u.sigmaS;
    float sx = (float(gid.x) - float(u.originX)) / sigmaS;
    float sy = (float(gid.y) - float(u.originY)) / sigmaS;

    int cx = int(floor(sx)) - u.baseX;
    int cy = int(floor(sy)) - u.baseY;

    if (cx < 0 || cx >= u.cellsX || cy < 0 || cy >= u.cellsY) return;

    int cr = int(floor(r / u.sigmaR));
    int cg = int(floor(g / u.sigmaG));
    int cb = int(floor(b / u.sigmaB));

    if (cr < 0 || cr >= u.cellsR || cg < 0 || cg >= u.cellsG || cb < 0 || cb >= u.cellsB) return;

    int idx = ((cx * u.cellsY + cy) * u.cellsR + cr) * u.cellsG + cg;
    idx = idx * u.cellsB + cb;

    float4 weighted = pix;
    weighted.w = 1.0f;

    grid[idx * 4 + 0] += weighted.x;
    grid[idx * 4 + 1] += weighted.y;
    grid[idx * 4 + 2] += weighted.z;
    grid[idx * 4 + 3] += weighted.w;
}

kernel void spektra_bilateral5d_blur_line(
    device float *gridIn [[buffer(0)]],
    device float *gridOut [[buffer(1)]],
    device const Bilateral5DUniforms &u [[buffer(2)]],
    device const int2 &axisWidth [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]])
{
    int axis = axisWidth.x;
    int width = axisWidth.y;

    int idx = gid.x + gid.y * width;
    if (idx >= u.cellsX * u.cellsY * u.cellsR * u.cellsG * u.cellsB) return;

    float sum = 0.0f;
    int count = 0;
    for (int i = -1; i <= 1; i++) {
        int neighborIdx = idx + i * (axis == 0 ? u.cellsY * u.cellsR * u.cellsG * u.cellsB : 1);
        if (neighborIdx >= 0 && neighborIdx < u.cellsX * u.cellsY * u.cellsR * u.cellsG * u.cellsB) {
            sum += gridIn[neighborIdx * 4 + axis];
            count++;
        }
    }
    gridOut[idx * 4 + axis] = count > 0 ? sum / float(count) : 0.0f;
}

kernel void spektra_bilateral5d_slice(
    texture2d<float, access::read>  in  [[texture(0)]],
    texture2d<float, access::write> out [[texture(1)]],
    device const float *grid [[buffer(0)]],
    device const Bilateral5DUniforms &u [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    int w = u.width;
    int h = u.height;

    float4 pix = in.read(gid);
    float r = pix.x, g = pix.y, b = pix.z;

    float sx = (float(gid.x) - float(u.originX)) / u.sigmaS;
    float sy = (float(gid.y) - float(u.originY)) / u.sigmaS;

    float cr = r / u.sigmaR;
    float cg = g / u.sigmaG;
    float cb = b / u.sigmaB;

    int cx = int(floor(sx)) - u.baseX;
    int cy = int(floor(sy)) - u.baseY;

    float result = 0.0f;
    float wSum = 0.0f;

    for (int dx = -1; dx <= 1; dx++) {
        for (int dy = -1; dy <= 1; dy++) {
            for (int dr = -1; dr <= 1; dr++) {
                for (int dg = -1; dg <= 1; dg++) {
                    for (int db = -1; db <= 1; db++) {
                        int nx = max(0, min(u.cellsX - 1, cx + dx));
                        int ny = max(0, min(u.cellsY - 1, cy + dy));
                        int nr = max(0, min(u.cellsR - 1, cr + dr));
                        int ng = max(0, min(u.cellsG - 1, cg + dg));
                        int nb = max(0, min(u.cellsB - 1, cb + db));

                        int idx = ((nx * u.cellsY + ny) * u.cellsR + nr) * u.cellsG + ng;
                        idx = idx * u.cellsB + nb;

                        float w = grid[idx * 4 + 3];
                        wSum += w;
                        result += grid[idx * 4] * w;
                    }
                }
            }
        }
    }

    out.write(float4(result / max(wSum, 0.001f), result / max(wSum, 0.001f), result / max(wSum, 0.001f), pix.w), gid);
}
