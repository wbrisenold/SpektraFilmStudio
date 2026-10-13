import Foundation
import Metal
import simd

// MARK: - Tone mapping module (ported from Lightamer)
/// Simplified Sigmoid tone mapping using ported Metal kernels

final class SigmoidToneModule {
    public struct Params: Codable, Hashable, Sendable {
        public var contrast: Float = 1.0
        public var skewness: Float = 0.0
        public var whiteTarget: Float = 100.0
        public var blackTarget: Float = 0.01517634
        public var huePreservation: Float = 100.0
        public var basePrimaries: Int = 0
    }

    private var pieceBuffer: MTLBuffer?
    private let device: any MTLDevice
    private var committedParams: Params?

    public init(device: any MTLDevice) {
        self.device = device
    }

    public func commitParams(_ params: Params) {
        committedParams = params
        let scalars = deriveScalars(params)
        var floats = [Float](repeating: 0, count: 34)
        floats[0] = scalars.whiteTarget
        floats[1] = scalars.blackTarget
        floats[2] = scalars.paperExposure
        floats[3] = scalars.filmFog
        floats[4] = scalars.filmPower
        floats[5] = scalars.paperPower
        floats[6] = scalars.huePreservation
        // Identity matrices for defaults
        let identity: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        floats.replaceSubrange(7..<16, with: identity)
        floats.replaceSubrange(16..<25, with: identity)
        floats.replaceSubrange(25..<34, with: identity)

        if pieceBuffer == nil {
            pieceBuffer = device.makeBuffer(
                bytes: floats, length: floats.count * MemoryLayout<Float>.size,
                options: .storageModeShared
            )
        } else if let buffer = pieceBuffer {
            floats.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: floats.count * 4) }
        }
    }

    private func deriveScalars(_ params: Params) -> (whiteTarget: Float, blackTarget: Float, paperExposure: Float, filmFog: Float, filmPower: Float, paperPower: Float, huePreservation: Float) {
        let middleGrey: Double = 0.1845
        let delta: Double = 1e-6

        func loglogistic(_ value: Double, _ magnitude: Double, _ paperExp: Double, _ filmFog: Double, _ filmPower: Double, _ paperPower: Double) -> Double {
            let clamped = max(value, 0.0)
            let filmResp = pow(filmFog + clamped, filmPower)
            let paperResp = magnitude * pow(filmResp / (paperExp + filmResp), paperPower)
            return paperResp.isNaN ? magnitude : paperResp
        }

        func slopeAtGrey(mag: Double, pe: Double, ff: Double, fp: Double, pp: Double) -> Double {
            let h = loglogistic(middleGrey + delta, mag, pe, ff, fp, pp)
            let l = loglogistic(middleGrey - delta, mag, pe, ff, fp, pp)
            return (h - l) / 2.0 / delta
        }

        let refFilmPower = Double(params.contrast)
        let refPaperPower = 1.0
        let refMagnitude = 1.0
        let refFilmFog = 0.0
        let refPaperExposure = pow(refFilmFog + middleGrey, refFilmPower) * ((refMagnitude / middleGrey) - 1.0)

        let paperPower = pow(5.0, -Double(params.skewness))
        let tempFilmPower = 1.0
        let tempWhiteTarget = 0.01 * Double(params.whiteTarget)
        let tempWhiteGreyRelation = pow(tempWhiteTarget / middleGrey, 1.0 / paperPower) - 1.0
        let tempPaperExposure = pow(middleGrey, tempFilmPower) * tempWhiteGreyRelation
        let tempSlope = slopeAtGrey(mag: tempWhiteTarget, pe: tempPaperExposure, ff: refFilmFog, fp: tempFilmPower, pp: paperPower)
        let refSlope = slopeAtGrey(mag: refMagnitude, pe: refPaperExposure, ff: refFilmFog, fp: refFilmPower, pp: refPaperPower)

        let filmPower = refSlope / tempSlope
        let whiteTarget = 0.01 * Double(params.whiteTarget)
        let blackTarget = 0.01 * Double(params.blackTarget)
        let whiteGreyRelation = pow(whiteTarget / middleGrey, 1.0 / paperPower) - 1.0
        let whiteBlackRelation = pow(blackTarget / whiteTarget, -1.0 / paperPower) - 1.0
        let filmFog = middleGrey * pow(whiteGreyRelation, 1.0 / filmPower) / (pow(whiteBlackRelation, 1.0 / filmPower) - pow(whiteGreyRelation, 1.0 / filmPower))
        let paperExposure = pow(filmFog + middleGrey, filmPower) * whiteGreyRelation
        let huePreservation = min(max(0.01 * Double(params.huePreservation), 0.0), 1.0)

        return (Float(whiteTarget), Float(blackTarget), Float(paperExposure), Float(filmFog), Float(filmPower), Float(paperPower), Float(huePreservation))
    }

    public func encode(commandBuffer: MTLCommandBuffer, input: MTLTexture, output: MTLTexture) throws {
        guard let buffer = pieceBuffer else { return }
        let library = try device.makeLibrary(source: Self.kernels, options: nil)
        guard let function = library.makeFunction(name: "spektra_sigmoid_per_channel") else { return }
        let pipeline = try device.makeComputePipelineState(function: function)
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: input.width, height: input.height, depth: 1),
                               threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()
    }

    public static let kernels = #"""
#include <metal_stdlib>
using namespace metal;

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
"""#
}
