import Foundation
@preconcurrency import Metal

// GPL-3.0-or-later. Algorithmic references:
// darktable src/iop/exposure.c: _compute_deflicker_correction (percentile metering)
// darktable src/iop/channelmixerrgb.c: _auto_detect_WB (grey edges), CAT16 adaptation.
// Our statistic is taken from DEVELOPED linear Rec.2020, not from darktable's
// raw-sensor histogram, and the adaptation reference is Rec.2020's D65, not D50.
// This is a separate reversible per-image import adjustment, not a spectral bake.
struct StudioImportCalibration: Codable, Equatable, Hashable, Sendable {
    var version: Int = 1
    var exposureEV: Double
    // Row-major 3x3 scene-linear Rec.2020 transform; identity on uncertainty.
    var rgbMatrix: [Double]
    var illuminantConfidence: Double
    var enabled: Bool = true
    // When the photographer changes camera-space RAW development, an old
    // illuminant estimate must never be applied to a different decode.
    var sourceRaw: RawSettings? = nil

    func applies(to raw: RawSettings) -> Bool {
        enabled && isUsable && (sourceRaw == nil || sourceRaw == raw)
    }

    var isUsable: Bool {
        version == 1 && exposureEV.isFinite && abs(exposureEV) <= 2.0 &&
        rgbMatrix.count == 9 && rgbMatrix.allSatisfy { $0.isFinite && abs($0) <= 4.0 } &&
        illuminantConfidence.isFinite && (0...1).contains(illuminantConfidence)
    }
}

enum StudioImportCalibrationEstimator {
    // D65 extended-linear Rec.2020 -> CIE XYZ; IEC / BT.2020 D65 primaries.
    private static let xyz: [[Double]] = [
        [0.6369580483, 0.1446169036, 0.1688809752],
        [0.2627002120, 0.6779980715, 0.0593017165],
        [0.0, 0.0280726930, 1.0609850577]
    ]
    private static let xyzToRGB: [[Double]] = [
        [1.7166511880, -0.3556707838, -0.2533662814],
        [-0.6666843518, 1.6164812366, 0.0157685458],
        [0.0176398574, -0.0427706133, 0.9421031212]
    ]
    private static let cat16: [[Double]] = [
        [0.401288, 0.650173, -0.051461],
        [-0.250268, 1.204414, 0.045854],
        [-0.002079, 0.048952, 0.953127]
    ]
    private static let invCAT16: [[Double]] = [
        [1.86206786, -1.01125463, 0.14918677],
        [0.38752654, 0.62144744, -0.00897398],
        [-0.01584150, -0.03412294, 1.04996444]
    ]
    private static let neutral = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]
    private static func matmul(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
        (0..<3).map { i in (0..<3).map { j in (0..<3).reduce(0.0) { $0 + a[i][$1] * b[$1][j] } } }
    }
    private static func mul(_ m: [[Double]], _ v: [Double]) -> [Double] {
        (0..<3).map { i in (0..<3).reduce(0.0) { $0 + m[i][$1] * v[$1] } }
    }
    private static func chromaticity(_ rgb: [Double]) -> (Double,Double,Double)? {
        let xyzValue = mul(xyz, rgb.map { max(0.0,$0) })
        let sum = xyzValue.reduce(0,+)
        guard sum > 1e-8, sum.isFinite else { return nil }
        let x = xyzValue[0] / sum, y = xyzValue[1] / sum
        guard x.isFinite, y.isFinite, y > 0.05, x > 0.04, x+y < 0.96 else { return nil }
        return (x,y,xyzValue[1])
    }
    private static func neutralMatrix(illuminantX: Double, illuminantY: Double,
                                      strength: Double) -> [Double] {
        let sourceXYZ = [illuminantX/illuminantY,1.0,(1.0-illuminantX-illuminantY)/illuminantY]
        let targetXYZ = [0.3127/0.3290,1.0,(1.0-0.3127-0.3290)/0.3290]
        let sourceLMS = mul(cat16,sourceXYZ), targetLMS = mul(cat16,targetXYZ)
        var d = [[Double]](repeating: [0,0,0],count:3)
        for i in 0..<3 {
            let gain = targetLMS[i] / max(1e-5,sourceLMS[i])
            guard gain.isFinite, gain > 0 else { return neutral }
            d[i][i] = exp2(min(0.45,max(-0.45,log2(gain))) * strength)
        }
        let transform = matmul(xyzToRGB,matmul(invCAT16,matmul(d,matmul(cat16,xyz))))
        let entries = transform.flatMap { $0 }
        return entries.allSatisfy({$0.isFinite && abs($0)<4.0}) ? entries : neutral
    }

    // Pixel inputs must already be tagged/converted as scene-linear Rec.2020.
    // Rather than forcing a gray-world guess on a portrait, skip WB if edge
    // chromaticity evidence is sparse or contradicts neutral-pixel estimates.
    static func estimate(width: Int, height: Int, pixels: [Float]) -> StudioImportCalibration {
        let fallback = StudioImportCalibration(exposureEV:0,rgbMatrix:neutral,illuminantConfidence:0)
        guard width >= 16, height >= 16, pixels.count == width*height*4 else { return fallback }
        let strideXY = max(1,max(width,height)/320)
        var lum = [Double](), edges = [(Double,Double)](), neutrals = [(Double,Double)]()
        lum.reserveCapacity(150000)
        for y in stride(from:0,to:height,by:strideXY) {
            for x in stride(from:0,to:width,by:strideXY) {
                let p = (y*width+x)*4
                let rgb = (0..<3).map { Double(pixels[p+$0]) }
                guard rgb.allSatisfy({$0.isFinite}), pixels[p+3]>0.1 else { continue }
                let yLum = max(0.0, 0.2627002120*rgb[0] + 0.6779980715*rgb[1] + 0.0593017165*rgb[2])
                guard yLum.isFinite, yLum > 0.0001, yLum < 8.0 else {continue}
                lum.append(yLum)
                if yLum < 0.02 || yLum > 0.9 {continue}
                if let c = chromaticity(rgb) {
                    let diff = hypot(c.0-0.3127,c.1-0.3290)
                    if diff < 0.075 {neutrals.append((c.0,c.1))}
                    if x>=strideXY && y>=strideXY && x+strideXY<width && y+strideXY<height {
                        // Darktable channelmixerrgb _auto_detect_WB uses a local
                        // B-spline blur and gray-edge chromaticity deviations.
                        // The sample lattice is deliberately bounded to 320px.
                        let o = strideXY
                        let neighbor = [(x-o,y,2.0),(x+o,y,2.0),(x,y-o,2.0),(x,y+o,2.0),
                                        (x-o,y-o,1.0),(x+o,y-o,1.0),(x-o,y+o,1.0),(x+o,y+o,1.0)]
                        var accumX=4*c.0, accumY=4*c.1, total=4.0
                        for (xx,yy,w) in neighbor {
                            let q=(yy*width+xx)*4
                            let r=(0..<3).map{ Double(pixels[q+$0]) }
                            if let cc=chromaticity(r),r.allSatisfy({$0.isFinite}) {
                                accumX += w*cc.0;accumY += w*cc.1;total += w
                            }
                        }
                        let dx=c.0-accumX/total,dy=c.1-accumY/total
                        let norm=pow(pow(abs(dx),8)+pow(abs(dy),8),1.0/8.0)
                        if norm>0.001 && norm.isFinite {
                            // Darktable's signed edge-displacement estimator.
                            let strength=min(1.0, yLum/0.08)
                            edges.append((-dx/norm*strength,-dy/norm*strength))
                        }
                    }
                }
            }
        }
        guard lum.count>48 else {return fallback}
        lum.sort()
        func percentile(_ p:Double)->Double {lum[min(lum.count-1,max(0,Int(Double(lum.count-1)*p)))]}
        // Percentile meter is the reference from darktable exposure.c. That
        // implementation meters camera RAW codes. Here we meter developed
        // scene-linear Rec.2020, so a shadow/highlight safety limit is required.
        let median=percentile(0.50), upper=percentile(0.995)
        let targetEV=log2(0.18/max(1e-5,median))
        let guardEV=log2(0.95/max(0.01,upper))
        let ev=min(1.50,max(-1.50,min(targetEV,guardEV)))
        var matrix=neutral,confidence=0.0
        if edges.count>=96 && neutrals.count>=32 {
            let edgeX=edges.reduce(0){$0+$1.0}/Double(edges.count)
            let edgeY=edges.reduce(0){$0+$1.1}/Double(edges.count)
            let nx=neutrals.reduce(0){$0+$1.0}/Double(neutrals.count)
            let ny=neutrals.reduce(0){$0+$1.1}/Double(neutrals.count)
            // The two independent estimates must agree within a conservative
            // tolerance; otherwise leave the camera's white balance intact.
            let ex=0.3127+edgeX*0.012,ey=0.3290+edgeY*0.012
            let drift=hypot(nx-ex,ny-ey)
            if drift < 0.065 && ex > 0.22 && ex < 0.43 && ey > 0.23 && ey < 0.43 {
                confidence=min(1.0,Double(min(edges.count,neutrals.count))/512.0) * max(0,1-drift/0.065)
                if confidence>0.08 {matrix=neutralMatrix(illuminantX:nx,illuminantY:ny,strength:confidence)}
            }
        }
        return StudioImportCalibration(exposureEV:ev.isFinite ? ev : 0.0,
                                       rgbMatrix:matrix,illuminantConfidence:confidence)
    }

    static func estimate(_ image: PixelBufferF32) -> StudioImportCalibration {
        estimate(width:image.width,height:image.height,pixels:image.pixels)
    }
}

// Zero full-frame CPU color loops; the same stage is encoded in live Metal and
// in native/Looks export. Stored per photo, independent of UI slider position.
final class StudioImportCalibrationMetal {
    private let device: any MTLDevice
    private let pipeline: any MTLComputePipelineState
    init(device: any MTLDevice) throws {
        self.device=device
        let lib=try device.makeLibrary(source:Self.shader,options:nil)
        guard let f=lib.makeFunction(name:"spektraImportCAT16") else {
            throw GPULiveError.unavailable("Import calibration Metal kernel unavailable")
        }
        pipeline=try device.makeComputePipelineState(function:f)
    }
    func encode(buffer: any MTLBuffer, width:Int,height:Int,
                calibration:StudioImportCalibration,
                on command:any MTLCommandBuffer) throws {
        guard calibration.enabled,calibration.isUsable else {return}
        guard let encoder=command.makeComputeCommandEncoder() else {
            throw GPULiveError.unavailable("Import calibration Metal encoder unavailable")
        }
        var dims=SIMD2<UInt32>(UInt32(width),UInt32(height))
        var rows=[SIMD4<Float>]()
        for row in 0..<3 {
            rows.append(SIMD4(Float(calibration.rgbMatrix[row*3]),
                              Float(calibration.rgbMatrix[row*3+1]),
                              Float(calibration.rgbMatrix[row*3+2]),0))
        }
        rows.append(SIMD4(Float(calibration.exposureEV),0,0,0))
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(buffer,offset:0,index:0)
        encoder.setBytes(&dims,length:MemoryLayout<SIMD2<UInt32>>.stride,index:1)
        rows.withUnsafeBytes {encoder.setBytes($0.baseAddress!,length:$0.count,index:2)}
        encoder.dispatchThreads(MTLSize(width:width,height:height,depth:1),
            threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1))
        encoder.endEncoding()
    }
    private static let shader = #"""
    #include <metal_stdlib>
    using namespace metal;
    kernel void spektraImportCAT16(device float4* frame [[buffer(0)]],
                                   constant uint2& dims [[buffer(1)]],
                                   constant float4* rows [[buffer(2)]],
                                   uint2 at [[thread_position_in_grid]]) {
        if(at.x>=dims.x || at.y>=dims.y)return;
        uint index=at.y*dims.x+at.x;
        float4 src=frame[index];
        float3 out=float3(dot(rows[0].xyz,src.rgb),dot(rows[1].xyz,src.rgb),
                          dot(rows[2].xyz,src.rgb));
        frame[index]=float4(out*exp2(rows[3].x),src.a);
    }
    """#
}

actor StudioImportCalibrationOffline {
    static let shared=StudioImportCalibrationOffline()
    private var gpu:GPULiveDevice?
    private var kernel:StudioImportCalibrationMetal?

    func render(_ input:PixelBufferF32,calibration:StudioImportCalibration?,
                raw:RawSettings) async throws -> PixelBufferF32 {
        guard let calibration,calibration.applies(to:raw) else {return input}
        if gpu == nil {
            guard let device=StudioGPUDevice.shared else {
                throw GPULiveError.unavailable("Import calibration requires Metal GPU")
            }
            gpu=try GPULiveDevice(device:device)
        }
        guard let gpu else {throw GPULiveError.unavailable("Import calibration GPU missing")}
        if kernel==nil {kernel=try StudioImportCalibrationMetal(device:gpu.device)}
        let count=input.pixels.count
        guard input.width>0,input.height>0,count==input.width*input.height*4 else {
            throw GPULiveError.unavailable("Import calibration buffer shape mismatch")
        }
        let byteCount=count*MemoryLayout<Float>.stride
        guard let buffer=input.pixels.withUnsafeBytes({gpu.device.makeBuffer(bytes:$0.baseAddress!,length:byteCount,options:.storageModeShared)}),
              let cmd=gpu.queue.makeCommandBuffer() else {
            throw GPULiveError.unavailable("Import calibration upload allocation failed")
        }
        try kernel?.encode(buffer:buffer,width:input.width,height:input.height,
                           calibration:calibration,on:cmd)
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
            cmd.addCompletedHandler { finished in
                withExtendedLifetime(buffer) {
                    if finished.status == .completed {continuation.resume()}
                    else {continuation.resume(throwing:GPULiveError.unavailable("Import calibration command failed"))}
                }
            }
            cmd.commit()
        }
        let copied=Array(UnsafeBufferPointer(start:buffer.contents().assumingMemoryBound(to:Float.self),count:count))
        return PixelBufferF32(width:input.width,height:input.height,pixels:copied)
    }
}
