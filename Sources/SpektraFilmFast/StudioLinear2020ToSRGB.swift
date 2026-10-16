import Foundation
@preconcurrency import Metal

/// Explicit photographic ODT for full-resolution Look-pack exports. The preview
/// starts in extended-linear Rec.2020 and Core Image presents it as display sRGB;
/// export must encode identical RGB data before the ImageIO writer tags it sRGB.
final class StudioLinear2020ToSRGB {
    private let pipeline: any MTLComputePipelineState
    init(device: any MTLDevice) throws {
        let lib = try device.makeLibrary(source: Self.shader, options: nil)
        guard let f = lib.makeFunction(name: "studioEncodePhotoSRGB") else {
            throw GPULiveError.unavailable("Photographic output encoder missing")
        }
        pipeline = try device.makeComputePipelineState(function: f)
    }

    func encode(
        _ image: any MTLBuffer, width: Int, height: Int,
        command: any MTLCommandBuffer,
    ) throws {
        guard width > 0, height > 0, width <= Int(UInt32.max), height <= Int(UInt32.max),
              let encoder = command.makeComputeCommandEncoder()
        else {
            throw GPULiveError.unavailable("Photographic output encoder unavailable")
        }
        var dims = SIMD2<UInt32>(UInt32(width), UInt32(height))
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(image, offset: 0, index: 0)
        encoder.setBytes(&dims, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 1)
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1),
        )
        encoder.endEncoding()
    }

    private static let shader = #"""
    #include <metal_stdlib>
    using namespace metal;
    inline float linearToSRGB(float x) {
        // Native display ODT clips negative primaries for encoded SDR output;
        // preserve >1 scene headroom until the final ImageIO quantization stage.
        x = max(x, 0.f);
        return x <= 0.0031308f ? 12.92f*x : 1.055f*pow(x, 1.f/2.4f)-0.055f;
    }
    kernel void studioEncodePhotoSRGB(device float4 *image [[buffer(0)]],
        constant uint2 &shape [[buffer(1)]], uint2 xy [[thread_position_in_grid]]) {
        if (xy.x>=shape.x || xy.y>=shape.y) return;
        uint i=xy.y*shape.x+xy.x;
        float4 p=image[i];
        float3 rgb=float3(dot(p.rgb,float3(1.660227f,-0.587547f,-0.072839f)),
                          dot(p.rgb,float3(-0.124554f,1.132926f,-0.008349f)),
                          dot(p.rgb,float3(-0.018155f,-0.100603f,1.118998f)));
        image[i]=float4(linearToSRGB(rgb.x),linearToSRGB(rgb.y),linearToSRGB(rgb.z),p.a);
    }
    """#
}
