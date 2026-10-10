// Ported from pdcgomes/redlamp 0ed3a59211e4128111f2c8ba11bc5d249b0cb8dd.
// SPDX-License-Identifier: MPL-2.0. See Resources/Redlamp-MPL-2.0.txt.
import Foundation
import Metal

struct FilmEffectsSettings: Codable, Equatable, Hashable, Sendable {
    var leakAmount: Double = 0
    var leakWarmth: Double = 50
    var leakVariation: Double = 0
    var dustAmount: Double = 0
    var scratchAmount: Double = 0
    var frameStyle: Int = 0
    var frameSize: Double = 50
    var isIdentity: Bool { leakAmount == 0 && dustAmount == 0 && scratchAmount == 0 && frameStyle == 0 }
}

final class RedlampFilmEffectsEngine: @unchecked Sendable {
    static let shared = RedlampFilmEffectsEngine()
    private let device: (any MTLDevice)?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLComputePipelineState?
    private convenience init() { self.init(device: StudioGPUDevice.shared) }
    init(device: (any MTLDevice)?) {
        self.device = device
        guard let device else { return }
        queue = device.makeCommandQueue()
        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            if let function = library.makeFunction(name: "filmEffects") { pipeline = try device.makeComputePipelineState(function: function) }
        } catch { GPUProcessingFailure.report("Film effects shader: \(error.localizedDescription)") }
    }
    func encode(source: any MTLBuffer, destination: any MTLBuffer,
                command: any MTLCommandBuffer, width: Int, height: Int,
                look: RenderLook) throws {
        guard let s = look.filmEffects, !s.isIdentity else {
            throw GPULiveError.unavailable("inactive film effects should skip the GPU pass")
        }
        let space = SkinToneReference.outputSpaceIndex(look)
        guard SkinToneReference.outputRoleIndex(look) == 0,
              [14,15,16,17,18,22,23,24,25].contains(space),
              let pipeline, let device,
              command.device.registryID == device.registryID,
              let encoder = command.makeComputeCommandEncoder() else {
            throw GPULiveError.unavailable("film effects require SDR display signal")
        }
        var p: [Float] = [Float(width), Float(height), Float(space),
            Float(s.leakAmount / 100), Float(s.leakWarmth / 100),
            Float(s.leakVariation / 100), Float(s.dustAmount / 100),
            Float(s.scratchAmount / 100), Float(s.frameStyle), Float(s.frameSize / 100)]
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(source, offset: 0, index: 0)
        encoder.setBuffer(destination, offset: 0, index: 1)
        encoder.setBytes(&p, length: p.count * MemoryLayout<Float>.stride, index: 2)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
    }

    func apply(_ input: PixelBufferF32, look: RenderLook) -> PixelBufferF32 {
        guard let s = look.filmEffects, !s.isIdentity else { return input }
        let space = SkinToneReference.outputSpaceIndex(look)
        guard SkinToneReference.outputRoleIndex(look) == 0, [14,15,16,17,18,22,23,24,25].contains(space) else {
            GPUProcessingFailure.report("Light leaks, dust, scratches and frames require a display output space."); return input
        }
        guard let device, let queue, let pipeline, input.width > 0, input.height > 0,
              input.pixels.count == input.width * input.height * 4 else { GPUProcessingFailure.report("Film effects GPU unavailable"); return input }
        let bytes = input.pixels.count * 4
        var p: [Float] = [Float(input.width), Float(input.height), Float(space), Float(s.leakAmount/100), Float(s.leakWarmth/100), Float(s.leakVariation/100), Float(s.dustAmount/100), Float(s.scratchAmount/100), Float(s.frameStyle), Float(s.frameSize/100)]
        guard let source = input.pixels.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: bytes, options: .storageModeShared) }),
              let destination = device.makeBuffer(length: bytes, options: .storageModeShared),
              let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { GPUProcessingFailure.report("Film effects GPU allocation failed"); return input }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(source, offset: 0, index: 0); encoder.setBuffer(destination, offset: 0, index: 1)
        encoder.setBytes(&p, length: p.count * 4, index: 2)
        encoder.dispatchThreads(MTLSize(width: input.width, height: input.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { GPUProcessingFailure.report("Film effects GPU execution failed"); return input }
        return PixelBufferF32(width: input.width, height: input.height, pixels: Array(UnsafeBufferPointer(start: destination.contents().assumingMemoryBound(to: Float.self), count: input.pixels.count)))
    }
    private static let shader = #"""
    #include <metal_stdlib>
    using namespace metal;
static inline float hash(uint2 p, uint seed) {
    uint n = p.x * 1973u + p.y * 9277u + seed * 26699u;
    n = (n << 13u) ^ n;
    n = n * (n * n * 15731u + 789221u) + 1376312589u;
    return float(n & 0x7fffffffu) / float(0x7fffffff);
}

static inline float valueNoise(float2 p, uint seed) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0f - 2.0f * f);
    uint2 c = uint2(int2(i) + 100000);
    float a = hash(c, seed);
    float b = hash(c + uint2(1, 0), seed);
    float cc = hash(c + uint2(0, 1), seed);
    float d = hash(c + uint2(1, 1), seed);
    return mix(mix(a, b, f.x), mix(cc, d, f.x), f.y);
}

// One channel of grain: a coarse and a fine octave of value noise, `size` full-resolution
// pixels across. With a `footprint` (full-resolution pixels per output pixel, 0 at full
// resolution or above) octaves finer than a pixel are sampled at the pixel and attenuated by
// how many grains it averages.
static inline float grainNoise(float2 position, float size, float footprint, float roughness, uint coarseSeed, uint fineSeed) {
    float fineSize = size * 0.5f;
    float coarse = (valueNoise(position / max(size, footprint), coarseSeed) - 0.5f)
        * (footprint > 0.0f ? min(1.0f, size / footprint) : 1.0f);
    float fine = (valueNoise(position / max(fineSize, footprint), fineSeed) - 0.5f)
        * (footprint > 0.0f ? min(1.0f, fineSize / footprint) : 1.0f);
    return mix(coarse, fine, roughness);
}

// MARK: - Mood effects

// Two or three soft, coloured glows from just outside the frame's edges (mostly the sides, where
// light gets in at a camera's film gate), screened over the image. `mood.y` turns them from cool
// (-1) to warm (+1); `mood.z` picks a different arrangement.
static inline float3 lightLeak(float3 encoded, float2 q, float aspect, float4 mood) {
    uint seed = uint(mood.z * 997.0f) + 3u;
    float3 leak = 0.0f;
    for (uint i = 0; i < 3; i++) {
        if (i == 2 && hash(uint2(i, 9u), seed) < 0.5f) break;
        float side = hash(uint2(i, 1u), seed);
        float along = mix(0.1f, 0.9f, hash(uint2(i, 2u), seed));
        float size = mix(0.3f, 0.75f, hash(uint2(i, 3u), seed));
        float2 centre, scale;
        if (side < 0.42f) { centre = float2(-0.1f, along); scale = float2(size * 0.55f, size); }
        else if (side < 0.84f) { centre = float2(aspect + 0.1f, along); scale = float2(size * 0.55f, size); }
        else if (side < 0.92f) { centre = float2(along * aspect, -0.1f); scale = float2(size, size * 0.55f); }
        else { centre = float2(along * aspect, 1.1f); scale = float2(size, size * 0.55f); }
        float2 d = (q - centre) / scale;
        float w = exp(-2.0f * dot(d, d));
        float3 warm = mix(float3(1.0f, 0.42f, 0.08f), float3(1.0f, 0.15f, 0.2f), hash(uint2(i, 4u), seed));
        warm = mix(warm, float3(1.0f, 0.82f, 0.32f), 0.35f * hash(uint2(i, 5u), seed));
        float3 cool = mix(float3(0.25f, 0.55f, 1.0f), float3(0.6f, 0.3f, 1.0f), hash(uint2(i, 4u), seed));
        leak += mix(cool, warm, 0.5f + 0.5f * mood.y) * w;
    }
    leak = min(leak * mood.x * 1.2f, 1.0f);
    return 1.0f - (1.0f - encoded) * (1.0f - leak);
}

// Dust: at most one speck per cell of 60 frame pixels, mostly small and dark (dust on a scanned
// negative or slide), a few bright. A speck smaller than an output pixel fades by its share of it.
static inline float3 dust(float3 encoded, float2 position, float framePixel, float footprint, float amount) {
    float cell = 60.0f * framePixel;
    int2 c = int2(floor(position / cell));
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int2 at = c + int2(dx, dy);
            uint2 key = uint2(at + 100000);
            if (hash(key, 41u) >= 0.06f * amount) continue;
            float2 centre = (float2(at) + float2(hash(key, 43u), hash(key, 47u))) * cell;
            float radius = mix(1.2f, 9.0f, pow(hash(key, 53u), 2.5f)) * framePixel;
            float2 offset = position - centre;
            float stretch = mix(1.0f, 2.5f, hash(key, 61u));
            float angle = hash(key, 67u) * 6.2831853f;
            float2 axis = float2(cos(angle), sin(angle));
            float along = dot(offset, axis) / stretch;
            float across = dot(offset, float2(-axis.y, axis.x));
            float distance = length(float2(along, across));
            float soft = max(radius * 0.35f, footprint * 0.5f);
            float coverage = (1.0f - smoothstep(radius - soft, radius + soft, distance))
                * min(1.0f, radius * radius / (footprint * footprint));
            float3 speck = hash(key, 59u) < 0.75f ? float3(0.04f) : float3(0.96f);
            encoded = mix(encoded, speck, coverage * 0.85f);
        }
    }
    return encoded;
}

// Scratches: fine vertical lines down the frame, as a film's travel through a camera or
// projector leaves them, flickering in strength along their length.
static inline float3 scratches(float3 encoded, float2 position, float2 fullSize, float framePixel, float footprint, float amount) {
    float bucket = 45.0f * framePixel;
    int b = int(floor(position.x / bucket));
    for (int db = -1; db <= 1; db++) {
        uint2 key = uint2(uint(b + db + 100000), 7u);
        if (hash(key, 71u) >= 0.05f * amount) continue;
        float x = (float(b + db) + hash(key, 73u)) * bucket;
        float width = mix(1.0f, 3.0f, hash(key, 79u)) * framePixel;
        float start = hash(key, 83u) * fullSize.y * 0.7f;
        float extent = mix(0.3f, 1.0f, hash(key, 89u)) * fullSize.y;
        float inside = smoothstep(start, start + 40.0f * framePixel, position.y)
            * (1.0f - smoothstep(start + extent - 40.0f * framePixel, start + extent, position.y));
        float soft = max(width * 0.5f, footprint * 0.5f);
        float coverage = (1.0f - smoothstep(width - soft, width + soft, abs(position.x - x)))
            * min(1.0f, width / footprint) * inside;
        float flicker = 0.45f + 0.55f * valueNoise(float2(x, position.y / (180.0f * framePixel)), 97u);
        float3 line = hash(key, 101u) < 0.6f ? float3(0.95f) : float3(0.08f);
        encoded = mix(encoded, line, coverage * flicker * 0.7f);
    }
    return encoded;
}

// A border over the photo's edges (FrameStyle): a keyline, a white print border, a 35 mm film
// rebate with its sprocket holes, or a slide mount. `q` is in frame heights; `pixel` is an output
// pixel in the same units, for antialiasing.
static inline float3 frameBorder(float3 encoded, float2 q, float aspect, int style, float size, float pixel) {
    float toEdge = min(min(q.x, aspect - q.x), min(q.y, 1.0f - q.y));
    if (style == 1) {
        float width = 0.006f * size;
        return mix(encoded, float3(0.02f), 1.0f - smoothstep(width - pixel, width + pixel, toEdge));
    }
    if (style == 2) {
        float width = 0.035f * size;
        float paper = 1.0f - smoothstep(width - pixel, width + pixel, toEdge);
        return mix(encoded, float3(0.96f, 0.955f, 0.94f), paper);
    }
    if (style == 3) {
        // The rebate runs along the long sides with the sprocket holes in it (a 35 mm frame is
        // eight perforations long), with a thin black edge on the short sides.
        bool landscape = aspect >= 1.0f;
        float2 r = landscape ? q : float2(q.y * aspect, q.x / aspect);
        float span = landscape ? aspect : 1.0f / aspect;
        float band = 0.13f * size, side = 0.02f * size;
        float alongEdge = min(r.y, 1.0f - r.y);
        float black = max(1.0f - smoothstep(band - pixel, band + pixel, alongEdge),
                          1.0f - smoothstep(side - pixel, side + pixel, min(r.x, span - r.x)));
        float pitch = span / 8.0f;
        float2 hole = float2(fmod(r.x + pitch * 0.5f, pitch) - pitch * 0.5f, alongEdge - band * 0.5f);
        float2 halfSize = float2(pitch * 0.29f, band * 0.3f);
        float2 outside = abs(hole) - halfSize + 0.01f * size;
        float holeDistance = length(max(outside, 0.0f)) + min(max(outside.x, outside.y), 0.0f) - 0.01f * size;
        float lit = (1.0f - smoothstep(-pixel, pixel, holeDistance)) * step(alongEdge, band);
        float3 rebate = mix(float3(0.015f, 0.012f, 0.01f), float3(0.98f, 0.93f, 0.84f), lit);
        return mix(encoded, rebate, black);
    }
    if (style == 4) {
        float inset = 0.06f * size, radius = 0.035f * size;
        float2 halfWindow = float2(aspect * 0.5f - inset, 0.5f - inset);
        float2 outside = abs(q - float2(aspect * 0.5f, 0.5f)) - halfWindow + radius;
        float distance = length(max(outside, 0.0f)) + min(max(outside.x, outside.y), 0.0f) - radius;
        float mount = smoothstep(-pixel, pixel, distance);
        float bevel = smoothstep(0.0f, 0.012f * size, distance);
        return mix(encoded, mix(float3(0.8f, 0.79f, 0.77f), float3(0.93f, 0.925f, 0.91f), bevel), mount);
    }
    return encoded;
}


    float encodeSRGB(float v) { float a=abs(v); return copysign(a<=0.0031308f ? 12.92f*a : 1.055f*pow(a,1.0f/2.4f)-0.055f,v); }
    float decodeSRGB(float v) { float a=abs(v); return copysign(a<=0.04045f ? a/12.92f : pow((a+0.055f)/1.055f,2.4f),v); }
    kernel void filmEffects(device const float4 *source [[buffer(0)]], device float4 *destination [[buffer(1)]], constant float *p [[buffer(2)]], uint2 xy [[thread_position_in_grid]]) {
        uint w=uint(p[0]),h=uint(p[1]); if(xy.x>=w||xy.y>=h)return;
        uint index=xy.y*w+xy.x; float4 pixel=source[index]; float3 c=pixel.rgb;
        bool linear=p[2]>=14&&p[2]<=16;
        if(linear)c=float3(encodeSRGB(c.r),encodeSRGB(c.g),encodeSRGB(c.b));
        float aspect=float(w)/float(h); float2 uv=(float2(xy)+0.5f)/float2(w,h),q=float2(uv.x*aspect,uv.y);
        if(p[3]>0)c=lightLeak(c,q,aspect,float4(p[3],p[4],p[5],p[6]));
        float2 fullSize=float2(w,h),position=uv*fullSize; float framePixel=max(fullSize.x,fullSize.y)/3000.0f;
        if(p[6]>0)c=dust(c,position,framePixel,1.0f,p[6]);
        if(p[7]>0)c=scratches(c,position,fullSize,framePixel,1.0f,p[7]);
        if(p[8]>0)c=frameBorder(c,q,aspect,int(p[8]+0.5f),mix(0.4f,1.6f,p[9]),1.0f/float(h));
        if(linear)c=float3(decodeSRGB(c.r),decodeSRGB(c.g),decodeSRGB(c.b));
        destination[index]=float4(c,pixel.a);
    }
"""#
}
