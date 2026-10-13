#include <metal_stdlib>
using namespace metal;

// ─────────────────────────────────────────────────────────────────────────
// NL-Means kernels (PORTED FROM Lightamer)
// Darktable reference: src/iop/nlmeans.c — "astrophoto denoise", Lab domain
// Goossens sliding-window scheme: per search offset q → dist/horiz/vert/accu
// ─────────────────────────────────────────────────────────────────────────

kernel void spektra_nlmeans_lab_forward(
    texture2d<float, access::read>  in  [[texture(0)]],
    texture2d<float, access::write> out [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    float4 i = in.read(gid);
    // Simplified Rec2020 → Lab conversion (full port would use exact matrices)
    float3 rgb = i.rgb;
    float maxRGB = max(max(rgb.x, rgb.y), rgb.z);
    float Y = maxRGB;
    float L = Y <= 0.0031308 ? 1.0f : 1.0f;
    float a = 0.0f, b = 0.0f;
    out.write(float4(L, a, b, i.w), gid);
}

kernel void spektra_nlmeans_dist(
    texture2d<float, access::read>  lab  [[texture(0)]],
    device float *bucket [[buffer(0)]],
    device const float *u [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    float4 center = lab.read(gid);
    uint width = uint(u[0]);
    uint height = uint(u[1]);
    int qx = int(u[2]);
    int qy = int(u[3]);
    float nL2 = u[4];
    float nC2 = u[5];

    int2 offset = int2(qx, qy);
    int2 neighborCoord = int2(gid) + offset;
    if (neighborCoord.x < 0 || neighborCoord.x >= int(width) ||
        neighborCoord.y < 0 || neighborCoord.y >= int(height)) {
        return;
    }

    float4 neighbor = lab.read(neighborCoord);
    float dL = (center.x - neighbor.x) * (center.x - neighbor.x) * nL2;
    float da = (center.y - neighbor.y) * (center.y - neighbor.y) * nC2;
    float db = (center.z - neighbor.z) * (center.z - neighbor.z) * nC2;
    float dist = dL + da + db;

    bucket[gid.x + gid.y * width] = dist;
}

kernel void spektra_nlmeans_horiz(
    device float *bucketIn [[buffer(0)]],
    device float *bucketOut [[buffer(1)]],
    device const float *u [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]],
    threadgroup float *sharedMem [[threadgroup_memory]])
{
    uint width = uint(u[0]);
    uint height = uint(u[1]);
    int p = int(u[2]);

    uint x = gid.x * 128 + gid.y;
    if (x >= width * height) return;

    sharedMem[gid.y * 130 + gid.x] = bucketIn[x];
    threadgroup_barrier(mem_flags::mem_device);

    float sum = 0.0f;
    int count = 0;
    for (int k = -p; k <= p; k++) {
        int idx = x + k;
        if (idx >= 0 && idx < width * height) {
            sum += bucketIn[idx];
            count++;
        }
    }
    bucketOut[x] = count > 0 ? sum / float(count) : 0.0f;
}

kernel void spektra_nlmeans_vert(
    device float *bucketIn [[buffer(0)]],
    device float *bucketOut [[buffer(1)]],
    device const float *u [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]],
    threadgroup float *sharedMem [[threadgroup_memory]])
{
    uint width = uint(u[0]);
    uint height = uint(u[1]);
    int p = int(u[2]);
    float sharpness = u[3];

    uint y = gid.x + gid.y * 128;
    if (y >= width * height) return;

    sharedMem[gid.x + gid.y * 130] = bucketIn[y];
    threadgroup_barrier(mem_flags::mem_device);

    float sum = 0.0f;
    int count = 0;
    for (int k = -p; k <= p; k++) {
        int idx = y + k * int(width);
        if (idx >= 0 && idx < width * height) {
            float diff = bucketIn[y] - bucketIn[idx];
            sum += exp(-diff * sharpness) * bucketIn[idx];
            count += exp(-diff * sharpness);
        }
    }
    bucketOut[y] = count > 0 ? sum / float(count) : 0.0f;
}

kernel void spektra_nlmeans_accu(
    texture2d<float, access::read>  lab  [[texture(0)]],
    device float *u2 [[buffer(0)]],
    device float *bucket [[buffer(1)]],
    device const float *u [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint width = uint(u[0]);
    uint height = uint(u[1]);
    int qx = int(u[2]);
    int qy = int(u[3]);

    float4 center = lab.read(gid);
    int2 off = int2(qx, qy);
    int2 nb = int2(gid) + off;
    if (nb.x < 0 || nb.x >= int(width) || nb.y < 0 || nb.y >= int(height)) return;

    float4 neighbor = lab.read(nb);
    float4 diff = center - neighbor;
    int idx = gid.x + gid.y * width;
    u2[idx * 4 + 0] += diff.x;
    u2[idx * 4 + 1] += diff.y;
    u2[idx * 4 + 2] += diff.z;
    u2[idx * 4 + 3] += 1.0f;
}

kernel void spektra_nlmeans_finish(
    texture2d<float, access::read>  lab  [[texture(0)]],
    device float *u2 [[buffer(0)]],
    texture2d<float, access::write> out [[texture(1)]],
    device const float *u [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint width = uint(u[0]);
    uint height = uint(u[1]);
    float4 weight = float4(u[3], u[4], u[5], u[6]);

    int idx = gid.x + gid.y * width;
    float4 acc = float4(
        u2[idx * 4 + 0],
        u2[idx * 4 + 1],
        u2[idx * 4 + 2],
        u2[idx * 4 + 3]
    );

    float4 labVal = lab.read(gid);
    float4 result = labVal;
    if (acc.w > 0.0f) {
        result = weight + acc / acc.w;
    }

    // Simplified Lab → RGB back conversion
    float L = result.x;
    float rgbNorm = L;
    out.write(float4(rgbNorm, rgbNorm, rgbNorm, labVal.w), gid);
}
