import Foundation
@preconcurrency import Metal
import simd

// Linear-light geometry stage. Matches GeometryEngine's projective coordinate
// convention and runs after Look/film/lens effects, never on the CPU preview.
// No full-frame readback and no source-image re-decode while editing crop.
final class StudioMetalGeometry {
    private let pipeline: any MTLComputePipelineState

    init(device: any MTLDevice) throws {
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        guard let function = library.makeFunction(name: "studioPostFilmGeometry") else {
            throw GPULiveError.unavailable("Metal geometry shader unavailable")
        }
        pipeline = try device.makeComputePipelineState(function: function)
    }

    static func targetSize(sourceWidth: Int, sourceHeight: Int,
                           geometry: GeometrySettings) -> (width: Int, height: Int) {
        var crop = geometry.crop
        crop.clamp()
        let x = Int((crop.x * Double(sourceWidth)).rounded(.down))
        let y = Int((crop.y * Double(sourceHeight)).rounded(.down))
        let w = max(1, min(sourceWidth - x, Int((crop.width * Double(sourceWidth)).rounded())))
        let h = max(1, min(sourceHeight - y, Int((crop.height * Double(sourceHeight)).rounded())))
        return (w, h)
    }

    func encode(source: any MTLBuffer, destination: any MTLTexture,
                width: Int, height: Int, geometry: GeometrySettings,
                command: any MTLCommandBuffer) throws {
        guard width > 0, height > 0 else { throw GPULiveError.unavailable("Invalid geometry dimensions") }
        var crop = geometry.crop
        crop.clamp()
        let rect = Self.targetSize(sourceWidth: width, sourceHeight: height, geometry: geometry)
        guard destination.width == rect.width, destination.height == rect.height else {
            throw GPULiveError.unavailable("Geometry output dimensions disagree")
        }
        var effective = geometry
        if geometry.autoCrop {
            effective.scale = max(geometry.scale, GeometryEngine.minimumScaleToCoverCrop(
                settings: geometry, width: width, height: height))
        }
        let angle = effective.rotationDegrees * .pi / 180
        let c = cos(angle), s = sin(angle)
        let flipX = effective.flipHorizontal ? -1.0 : 1.0
        let flipY = effective.flipVertical ? -1.0 : 1.0
        let stretch = pow(2.0, effective.aspect / 200.0)
        let zoom = max(0.1, effective.scale / 100.0)
        let pX = max(-100.0, min(100.0, effective.verticalPerspective)) * 0.0045
        let pY = max(-100.0, min(100.0, effective.horizontalPerspective)) * 0.0045
        let tx = effective.xOffset / 200.0
        let ty = -effective.yOffset / 200.0
        let f = simd_double3x3(rows: [SIMD3(flipX, 0, 0), SIMD3(0, flipY, 0), SIMD3(0, 0, 1)])
        let r = simd_double3x3(rows: [SIMD3(c, -s, 0), SIMD3(s, c, 0), SIMD3(0, 0, 1)])
        let a = simd_double3x3(rows: [SIMD3(stretch * zoom, 0, tx),
                                      SIMD3(0, zoom, ty), SIMD3(pX, pY, 1)])
        let forward = a * r * f
        guard abs(simd_determinant(forward)) > 1.0e-10 else {
            throw GPULiveError.unavailable("Singular perspective transform")
        }
        let inverse = simd_inverse(forward)
        var row0 = SIMD4<Float>(Float(inverse.columns.0.x), Float(inverse.columns.1.x), Float(inverse.columns.2.x), 0)
        var row1 = SIMD4<Float>(Float(inverse.columns.0.y), Float(inverse.columns.1.y), Float(inverse.columns.2.y), 0)
        var row2 = SIMD4<Float>(Float(inverse.columns.0.z), Float(inverse.columns.1.z), Float(inverse.columns.2.z), 0)
        let startX = Int((crop.x * Double(width)).rounded(.down))
        let startY = Int((crop.y * Double(height)).rounded(.down))
        var sourceSize = SIMD2<UInt32>(UInt32(width), UInt32(height))
        var origin = SIMD2<UInt32>(UInt32(startX), UInt32(startY))
        guard let encoder = command.makeComputeCommandEncoder() else {
            throw GPULiveError.unavailable("Metal geometry encoder unavailable")
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(source, offset: 0, index: 0)
        encoder.setTexture(destination, index: 0)
        encoder.setBytes(&sourceSize, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 1)
        encoder.setBytes(&origin, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 2)
        encoder.setBytes(&row0, length: MemoryLayout<SIMD4<Float>>.stride, index: 3)
        encoder.setBytes(&row1, length: MemoryLayout<SIMD4<Float>>.stride, index: 4)
        encoder.setBytes(&row2, length: MemoryLayout<SIMD4<Float>>.stride, index: 5)
        encoder.dispatchThreads(MTLSize(width: rect.width, height: rect.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
    }

    private static let shader = #"""
    #include <metal_stdlib>
    using namespace metal;
    kernel void studioPostFilmGeometry(
        device const float4 *source [[buffer(0)]],
        texture2d<float, access::write> destination [[texture(0)]],
        constant uint2 &sourceSize [[buffer(1)]],
        constant uint2 &cropOrigin [[buffer(2)]],
        constant float4 &row0 [[buffer(3)]],
        constant float4 &row1 [[buffer(4)]],
        constant float4 &row2 [[buffer(5)]],
        uint2 xy [[thread_position_in_grid]]) {
        if (xy.x >= destination.get_width() || xy.y >= destination.get_height()) return;
        float fullW = float(sourceSize.x), fullH = float(sourceSize.y);
        float aspect = fullW / max(fullH, 1.f);
        float nx = (float(xy.x + cropOrigin.x) / max(1.f, fullW-1.f) - 0.5f) * aspect;
        float ny = float(xy.y + cropOrigin.y) / max(1.f, fullH-1.f) - 0.5f;
        float3 coord = float3(nx, ny, 1.f);
        float denominator = dot(row2.xyz, coord);
        if (abs(denominator) < 1e-9f) { destination.write(float4(0,0,0,1), xy); return; }
        float su = dot(row0.xyz, coord) / denominator / aspect + 0.5f;
        float sv = dot(row1.xyz, coord) / denominator + 0.5f;
        float sx = su * (fullW-1.f), sy = sv * (fullH-1.f);
        if (sx < 0.f || sy < 0.f || sx > fullW-1.f || sy > fullH-1.f) {
            destination.write(float4(0,0,0,1), xy); return;
        }
        uint x0=uint(floor(sx)), y0=uint(floor(sy));
        uint x1=min(sourceSize.x-1,x0+1), y1=min(sourceSize.y-1,y0+1);
        float tx=fract(sx), ty=fract(sy);
        float4 p00=source[y0*sourceSize.x+x0], p10=source[y0*sourceSize.x+x1];
        float4 p01=source[y1*sourceSize.x+x0], p11=source[y1*sourceSize.x+x1];
        float4 px0=mix(p00,p10,tx), px1=mix(p01,p11,tx);
        destination.write(mix(px0,px1,ty),xy);
    }
    """#
}
