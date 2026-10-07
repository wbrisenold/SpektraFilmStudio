import Foundation
import Metal

/// Spatial optical character. Applied after the exact film engine and before geometry.
/// The CPU implementation mirrors the Metal equations and is used only if Metal fails.
/// Inspired by the RapidGrade lens study (protected center, elliptical arc blur,
/// independently shaped vignette, per-channel CA); not copied from a proprietary shader.
enum LensCharacterEngine {
    static func apply(_ input: PixelBufferF32, settings optional: LensEffectsSettings?) -> PixelBufferF32 {
        guard let s = optional, s.enabled, !s.isIdentity,
              input.width > 2, input.height > 2 else { return input }
        let parameters = s.resolvedWithCenter
        if let metal = LensOpticalMetal.shared.apply(input, parameters: parameters) { return metal }
        return applyCPU(input, parameters: parameters)
    }

    private static func applyCPU(_ input: PixelBufferF32, parameters p: LensEffectsResolved) -> PixelBufferF32 {
        let w = input.width, h = input.height
        let invW = 1 / Float(max(1, w - 1)), invH = 1 / Float(max(1, h - 1))
        let a = Float(w) / Float(h), shape = Float(max(0.5, min(2, p.lensShape)))
        let protect = Float(max(0.02, min(0.94, p.swirlRadius)))
        let thickness = Float(max(0.1, min(3, p.blurThickness)))
        let size = Float(max(w, h))
        let outputCount = w * h * 4
        var pixels = [Float](repeating: 0, count: outputCount)

        @inline(__always) func smooth(_ t: Float) -> Float {
            let q = max(0, min(1, t)); return q * q * (3 - 2 * q)
        }
        @inline(__always) func sample(_ u: Float, _ v: Float, _ channel: Int) -> Float {
            let x = max(0, min(Float(w - 1), u * Float(w - 1)))
            let y = max(0, min(Float(h - 1), v * Float(h - 1)))
            let x0 = Int(x), y0 = Int(y), x1 = min(w - 1, x0 + 1), y1 = min(h - 1, y0 + 1)
            let fx = x - Float(x0), fy = y - Float(y0)
            let top = input.pixels[(y0 * w + x0) * 4 + channel] * (1 - fx) + input.pixels[(y0 * w + x1) * 4 + channel] * fx
            let bottom = input.pixels[(y1 * w + x0) * 4 + channel] * (1 - fx) + input.pixels[(y1 * w + x1) * 4 + channel] * fx
            return top * (1 - fy) + bottom * fy
        }
        for y in 0..<h {
            for x in 0..<w {
                let xu = Float(x) * invW * 2 - 1
                let yu = Float(y) * invH * 2 - 1
                let cx = Float(p.centerX * 2 - 1), cy = Float(p.centerY * 2 - 1)
                let lx = xu - cx, ly = yu - cy
                let dx = lx * a / shape, dy = ly * shape
                let radius = min(1, sqrt(dx * dx + dy * dy) / sqrt(a * a / (shape * shape) + shape * shape))
                let edge = smooth((radius - protect) / max(0.02, 1 - protect))
                let r2 = dx * dx + dy * dy
                let warp = 1 + Float(p.distortion) * r2 + Float(p.sphericalAberration) * 0.012 * r2 * r2
                var wx = lx * warp, wy = ly * warp
                let angle = Float(p.petzvalSwirl) * 0.33 * edge * edge
                let ca = cos(angle), sa = sin(angle)
                let ox = wx * ca - wy * sa; wy = wx * sa + wy * ca; wx = ox
                wx += cx; wy += cy
                let u = wx * 0.5 + 0.5, v = wy * 0.5 + 0.5
                let caShift = Float(p.chromaticAberration) / size
                let bright = max(0, 0.2126 * sample(u,v,0) + 0.7152 * sample(u,v,1) + 0.0722 * sample(u,v,2))
                let high = smooth((bright - 0.55) / 0.8)
                let shift = edge * (caShift + Float(p.highlightChromaticAberration) * high / size)
                let directionX = lx, directionY = ly
                let blur = edge * (Float(p.edgeSoftness) * 0.005 + Float(p.sphericalAberration) * 0.002) * thickness
                let tangentX = -ly / max(0.001, a), tangentY = lx * a
                let curve = Float(p.petzvalSwirl) * 0.16 * edge
                let start = (y * w + x) * 4
                for channel in 0..<3 {
                    let offset: Float
                    if p.caChannel == .red && channel != 0 { offset = 0 }
                    else if p.caChannel == .blue && channel != 2 { offset = 0 }
                    else { offset = channel == 0 ? shift : (channel == 2 ? -shift : 0) }
                    let cu = u + directionX * offset, cv = v + directionY * offset
                    var result = sample(cu, cv, channel)
                    if blur > 0.000001 {
                        var weighted = Float(0), weights = Float(0)
                        for i in -3...3 {
                            let t = Float(i) / 3
                            let arcX = tangentX * t + lx * curve * t * t
                            let arcY = tangentY * t + ly * curve * t * t
                            let weight = 1 - 0.55 * abs(t)
                            weighted += sample(cu + arcX * blur, cv + arcY * blur, channel) * weight
                            weights += weight
                        }
                        let amount = smooth(min(1, blur * 210))
                        result = result * (1 - amount) + (weighted / weights) * amount
                    }
                    let vignetteRadius = Float(max(0.10, min(0.98, p.vignetteRadius)))
                    let falloff = Float(max(0.4, min(5, p.vignetteFalloff)))
                    let vig = 1 - Float(p.vignette) * pow(smooth((radius - vignetteRadius) / max(0.02, 1 - vignetteRadius)), falloff)
                    pixels[start + channel] = result * max(0, vig)
                }
                pixels[start + 3] = input.pixels[start + 3]
            }
        }
        return PixelBufferF32(width: w, height: h, pixels: pixels)
    }
}

private final class LensOpticalMetal: @unchecked Sendable {
    static let shared = LensOpticalMetal()
    private struct Params {
        var width: UInt32; var height: UInt32; var caChannel: UInt32; var pad: UInt32 = 0
        var distortion: Float; var ca: Float; var highlightCA: Float; var spherical: Float
        var swirl: Float; var edgeSoft: Float; var vignette: Float; var lensShape: Float
        var blurThickness: Float; var swirlRadius: Float; var vignetteRadius: Float; var vignetteFalloff: Float
        var centerX: Float; var centerY: Float
    }
    private let queue: MTLCommandQueue?
    private let pipeline: MTLComputePipelineState?
    private init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = try? device.makeLibrary(source: Self.source, options: nil),
              let function = library.makeFunction(name: "lens_optical_kernel"),
              let queue = device.makeCommandQueue(),
              let pipeline = try? device.makeComputePipelineState(function: function) else {
            self.queue = nil; self.pipeline = nil; return
        }
        self.queue = queue; self.pipeline = pipeline
    }
    func apply(_ input: PixelBufferF32, parameters p: LensEffectsResolved) -> PixelBufferF32? {
        guard let queue, let pipeline else { return nil }
        let count = input.pixels.count
        guard count > 0, count <= Int.max / MemoryLayout<Float>.stride else { return nil }
        let bytes = count * MemoryLayout<Float>.stride
        let device = queue.device
        guard let src = device.makeBuffer(bytes: input.pixels, length: bytes, options: .storageModeShared),
              let dst = device.makeBuffer(length: bytes, options: .storageModeShared),
              let command = queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else { return nil }
        var params = Params(width: UInt32(input.width), height: UInt32(input.height), caChannel: p.caChannel == .red ? 1 : (p.caChannel == .blue ? 2 : 0),
                            distortion: Float(p.distortion), ca: Float(p.chromaticAberration), highlightCA: Float(p.highlightChromaticAberration),
                            spherical: Float(p.sphericalAberration), swirl: Float(p.petzvalSwirl), edgeSoft: Float(p.edgeSoftness),
                            vignette: Float(p.vignette), lensShape: Float(p.lensShape), blurThickness: Float(p.blurThickness),
                            swirlRadius: Float(p.swirlRadius), vignetteRadius: Float(p.vignetteRadius), vignetteFalloff: Float(p.vignetteFalloff),
                            centerX: Float(p.centerX), centerY: Float(p.centerY))
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(src, offset: 0, index: 0); encoder.setBuffer(dst, offset: 0, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 2)
        encoder.dispatchThreads(MTLSize(width: input.width, height: input.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { return nil }
        let ptr = dst.contents().bindMemory(to: Float.self, capacity: count)
        return PixelBufferF32(width: input.width, height: input.height, pixels: Array(UnsafeBufferPointer(start: ptr, count: count)))
    }

    private static let source = #"""
    #include <metal_stdlib>
    using namespace metal;
    struct P { uint width;uint height;uint caChannel;uint pad;float distortion;float ca;float highlightCA;float spherical;float swirl;float edgeSoft;float vignette;float lensShape;float blurThickness;float swirlRadius;float vignetteRadius;float vignetteFalloff;float centerX;float centerY; };
    inline float smooth(float t) { t=clamp(t,0.0f,1.0f);return t*t*(3.0f-2.0f*t); }
    inline float get(device const float *src,uint w,uint h,float u,float v,uint c) {
        float px=clamp(u*float(w-1),0.0f,float(w-1)),py=clamp(v*float(h-1),0.0f,float(h-1));
        uint x0=uint(px),y0=uint(py),x1=min(w-1,x0+1),y1=min(h-1,y0+1);
        float fx=px-float(x0),fy=py-float(y0);
        return mix(mix(src[(y0*w+x0)*4+c],src[(y0*w+x1)*4+c],fx),mix(src[(y1*w+x0)*4+c],src[(y1*w+x1)*4+c],fx),fy);
    }
    kernel void lens_optical_kernel(device const float *src [[buffer(0)]],device float *dst [[buffer(1)]],constant P &p [[buffer(2)]],uint2 gid [[thread_position_in_grid]]) {
        if(gid.x>=p.width || gid.y>=p.height) return;
        float a=float(p.width)/float(p.height),shape=clamp(p.lensShape,0.5f,2.0f);
        float xu=float(gid.x)/max(1.0f,float(p.width-1))*2.0f-1.0f, yu=float(gid.y)/max(1.0f,float(p.height-1))*2.0f-1.0f;
        float cx=p.centerX*2.0f-1.0f,cy=p.centerY*2.0f-1.0f,lx=xu-cx,ly=yu-cy;
        float dx=lx*a/shape,dy=ly*shape, r2=dx*dx+dy*dy;
        float radius=min(1.0f,sqrt(r2)/sqrt(a*a/(shape*shape)+shape*shape));
        float protect=clamp(p.swirlRadius,0.02f,0.94f);
        float edge=smooth((radius-protect)/max(0.02f,1.0f-protect));
        float warp=1.0f+p.distortion*r2+p.spherical*0.012f*r2*r2;
        float wx=lx*warp,wy=ly*warp;
        float angle=p.swirl*0.33f*edge*edge;
        float ox=wx*cos(angle)-wy*sin(angle);wy=wx*sin(angle)+wy*cos(angle);wx=ox;
        wx+=cx;wy+=cy;
        float u=wx*0.5f+0.5f,v=wy*0.5f+0.5f;
        float bright=max(0.0f,0.2126f*get(src,p.width,p.height,u,v,0)+0.7152f*get(src,p.width,p.height,u,v,1)+0.0722f*get(src,p.width,p.height,u,v,2));
        float high=smooth((bright-0.55f)/0.8f),size=max(float(p.width),float(p.height));
        float shift=edge*(p.ca+high*p.highlightCA)/size;
        float blur=edge*(p.edgeSoft*0.005f+p.spherical*0.002f)*clamp(p.blurThickness,0.1f,3.0f);
        float tangentX=-ly/max(0.001f,a),tangentY=lx*a,curve=p.swirl*0.16f*edge;
        float vig=1.0f-p.vignette*pow(smooth((radius-clamp(p.vignetteRadius,0.10f,0.98f))/max(0.02f,1.0f-clamp(p.vignetteRadius,0.10f,0.98f))),clamp(p.vignetteFalloff,0.4f,5.0f));
        uint o=(gid.y*p.width+gid.x)*4;
        for(uint c=0;c<3;c++) {
            float offset=(p.caChannel==1 && c!=0)||(p.caChannel==2 && c!=2)?0.0f:(c==0?shift:(c==2?-shift:0.0f));
            float cu=u+lx*offset,cv=v+ly*offset;
            float result=get(src,p.width,p.height,cu,cv,c);
            if(blur>0.000001f) {
                float weighted=0.0f,weights=0.0f;
                for(int i=-3;i<=3;i++) {
                    float t=float(i)/3.0f,arcX=tangentX*t+lx*curve*t*t,arcY=tangentY*t+ly*curve*t*t;
                    float weight=1.0f-0.55f*abs(t);
                    weighted+=get(src,p.width,p.height,cu+arcX*blur,cv+arcY*blur,c)*weight;weights+=weight;
                }
                float amount=smooth(min(1.0f,blur*210.0f));result=mix(result,weighted/weights,amount);
            }
            dst[o+c]=result*max(0.0f,vig);
        }
        dst[o+3]=src[o+3];
    }
    """#
}
