import Foundation
import Metal

/// Stage 5 production lens engine.
///
/// - Metal is the preferred path for both 1080 px previews and full-resolution export.
/// - The CPU reference implementation is retained as a deterministic fallback only.
/// - The compute grid is dispatched in fixed 16x16 tiles so memory pressure scales with
///   the source image rather than with temporary per-pixel Swift allocations.
enum LensCharacterEngine {
    static func apply(_ input: PixelBufferF32, settings optional: LensEffectsSettings?) -> PixelBufferF32 {
        guard let s = optional, s.enabled, !s.isIdentity, input.width > 2, input.height > 2 else { return input }
        if let gpu = LensCharacterMetalEngine.shared.apply(input, settings: s.resolved) {
            return gpu
        }
        return applyCPU(input, settings: s.resolved)
    }

    private static func applyCPU(_ input: PixelBufferF32, settings preset: LensEffectsResolved) -> PixelBufferF32 {
        let w = input.width, h = input.height
        var out = [Float](repeating: 0, count: input.pixels.count)
        let aspect = Float(w) / Float(max(1, h))
        let maxRadius = sqrt(aspect * aspect + 1)
        let k1 = Float(preset.distortion)
        let ca = Float(preset.chromaticAberration) / Float(max(w, h))
        let highlightCA = Float(preset.highlightChromaticAberration) / Float(max(w, h))
        let swirl = Float(preset.petzvalSwirl) * 0.035
        let edgeSoft = Float(preset.edgeSoftness)
        let spherical = Float(preset.sphericalAberration)
        let vignette = Float(preset.vignette)

        @inline(__always) func sample(_ x: Float, _ y: Float, _ channel: Int) -> Float {
            let fx = max(0, min(Float(w - 1), x * Float(w - 1)))
            let fy = max(0, min(Float(h - 1), y * Float(h - 1)))
            let x0 = Int(floor(fx)), y0 = Int(floor(fy)); let x1 = min(w - 1, x0 + 1), y1 = min(h - 1, y0 + 1)
            let tx = fx - Float(x0), ty = fy - Float(y0)
            let a = input.pixels[(y0*w+x0)*4+channel] * (1-tx) + input.pixels[(y0*w+x1)*4+channel] * tx
            let b = input.pixels[(y1*w+x0)*4+channel] * (1-tx) + input.pixels[(y1*w+x1)*4+channel] * tx
            return a * (1-ty) + b * ty
        }

        for y in 0..<h {
            let ny0 = (Float(y) / Float(max(1,h-1))) * 2 - 1
            for x in 0..<w {
                let nx0 = ((Float(x) / Float(max(1,w-1))) * 2 - 1) * aspect
                let r2 = nx0*nx0 + ny0*ny0
                let rn = min(1, sqrt(r2) / maxRadius)
                let distortionScale = 1 + k1*r2 + spherical * 0.018 * r2*r2
                var nx = nx0 * distortionScale, ny = ny0 * distortionScale
                if abs(swirl) > 0.00001 {
                    let angle = swirl * rn * rn
                    let c = cos(angle), ss = sin(angle)
                    let rx = nx*c - ny*ss; ny = nx*ss + ny*c; nx = rx
                }
                let u = nx / aspect * 0.5 + 0.5, v = ny * 0.5 + 0.5
                let radialX = nx / max(0.0001, aspect), radialY = ny
                var rr = sample(u + radialX*ca, v + radialY*ca, 0)
                let gg = sample(u, v, 1)
                var bb = sample(u - radialX*ca, v - radialY*ca, 2)
                let luma = max(0, 0.2126*rr + 0.7152*gg + 0.0722*bb)
                let hca = highlightCA * min(1, luma)
                if hca > 0 {
                    rr = sample(u + radialX*hca, v + radialY*hca, 0)
                    bb = sample(u-radialX*hca,v-radialY*hca,2)
                }
                if spherical > 0.001 {
                    let blur = spherical * (0.25 + 0.75*rn*rn) / Float(max(w,h)) * 5
                    rr = rr*(1-spherical*0.18) + sample(u+blur,v,0)*(spherical*0.09) + sample(u-blur,v,0)*(spherical*0.09)
                    bb = bb*(1-spherical*0.18) + sample(u,v+blur,2)*(spherical*0.09) + sample(u,v-blur,2)*(spherical*0.09)
                }
                let p=(y*w+x)*4
                let vignetteGain = max(0, 1 - vignette * pow(rn, 2.2))
                let softnessGain = max(0.72, 1 - edgeSoft * rn*rn * 0.16)
                out[p]=rr*vignetteGain*softnessGain; out[p+1]=gg*vignetteGain*softnessGain; out[p+2]=bb*vignetteGain*softnessGain; out[p+3]=input.pixels[p+3]
            }
        }
        return PixelBufferF32(width:w,height:h,pixels:out)
    }
}

private final class LensCharacterMetalEngine: @unchecked Sendable {
    static let shared = LensCharacterMetalEngine()

    private struct Params {
        var width: UInt32
        var height: UInt32
        var distortion: Float
        var chromaticAberration: Float
        var highlightChromaticAberration: Float
        var sphericalAberration: Float
        var petzvalSwirl: Float
        var edgeSoftness: Float
        var vignette: Float
        var reserved: Float = 0
    }

    private let queue: MTLCommandQueue?
    private let pipeline: MTLComputePipelineState?
    private let lock = NSLock()

    private init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            self.queue = nil; self.pipeline = nil; return
        }
        let library = try? device.makeLibrary(source: Self.metalSource, options: nil)
        let function = library?.makeFunction(name: "lens_character_kernel")
        guard let function, let queue = device.makeCommandQueue(),
              let pipeline = try? device.makeComputePipelineState(function: function) else {
            self.queue = nil; self.pipeline = nil; return
        }
        self.queue = queue
        self.pipeline = pipeline
    }

    func apply(_ input: PixelBufferF32, settings: LensEffectsResolved) -> PixelBufferF32? {
        guard let queue, let pipeline else { return nil }
        let device = queue.device
        let byteCount = input.pixels.count * MemoryLayout<Float>.stride
        guard byteCount > 0,
              let inputBuffer = device.makeBuffer(bytes: input.pixels, length: byteCount, options: .storageModeShared),
              let outputBuffer = device.makeBuffer(length: byteCount, options: .storageModeShared),
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        var params = Params(
            width: UInt32(input.width), height: UInt32(input.height),
            distortion: Float(settings.distortion),
            chromaticAberration: Float(settings.chromaticAberration),
            highlightChromaticAberration: Float(settings.highlightChromaticAberration),
            sphericalAberration: Float(settings.sphericalAberration),
            petzvalSwirl: Float(settings.petzvalSwirl),
            edgeSoftness: Float(settings.edgeSoftness),
            vignette: Float(settings.vignette)
        )
        guard let paramBuffer = device.makeBuffer(bytes: &params, length: MemoryLayout<Params>.stride, options: .storageModeShared) else { return nil }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(inputBuffer, offset: 0, index: 0)
        encoder.setBuffer(outputBuffer, offset: 0, index: 1)
        encoder.setBuffer(paramBuffer, offset: 0, index: 2)
        let tile = MTLSize(width: 16, height: 16, depth: 1)
        let grid = MTLSize(width: input.width, height: input.height, depth: 1)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: tile)
        encoder.endEncoding()

        // Queue/pipeline are shared by preview and export. Serialize only the actual Metal submit
        // so simultaneous exports cannot mutate shared driver state on older Intel GPUs.
        lock.lock(); commandBuffer.commit(); lock.unlock()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }

        let ptr = outputBuffer.contents().bindMemory(to: Float.self, capacity: input.pixels.count)
        let pixels = Array(UnsafeBufferPointer(start: ptr, count: input.pixels.count))
        return PixelBufferF32(width: input.width, height: input.height, pixels: pixels)
    }

    private static let metalSource = #"""
    #include <metal_stdlib>
    using namespace metal;
    struct Params { uint width; uint height; float distortion; float ca; float highlightCA; float spherical; float swirl; float edgeSoft; float vignette; float reserved; };

    inline float sample_channel(device const float *src, uint w, uint h, float u, float v, uint c) {
        float fx = clamp(u * float(w-1), 0.0f, float(w-1));
        float fy = clamp(v * float(h-1), 0.0f, float(h-1));
        uint x0 = uint(floor(fx)), y0 = uint(floor(fy)); uint x1=min(w-1,x0+1), y1=min(h-1,y0+1);
        float tx=fx-float(x0), ty=fy-float(y0);
        float a=mix(src[(y0*w+x0)*4+c],src[(y0*w+x1)*4+c],tx);
        float b=mix(src[(y1*w+x0)*4+c],src[(y1*w+x1)*4+c],tx);
        return mix(a,b,ty);
    }

    kernel void lens_character_kernel(device const float *src [[buffer(0)]], device float *dst [[buffer(1)]], constant Params &p [[buffer(2)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x>=p.width || gid.y>=p.height) return;
        float w=float(p.width), h=float(p.height), aspect=w/max(1.0f,h), maxRadius=sqrt(aspect*aspect+1.0f);
        float ny0=(float(gid.y)/max(1.0f,h-1.0f))*2.0f-1.0f;
        float nx0=((float(gid.x)/max(1.0f,w-1.0f))*2.0f-1.0f)*aspect;
        float r2=nx0*nx0+ny0*ny0, rn=min(1.0f,sqrt(r2)/maxRadius);
        float distortionScale=1.0f+p.distortion*r2+p.spherical*0.018f*r2*r2;
        float nx=nx0*distortionScale, ny=ny0*distortionScale;
        float swirlAmount=p.swirl*0.035f;
        if (fabs(swirlAmount)>0.00001f) { float a=swirlAmount*rn*rn; float c=cos(a), s=sin(a); float rx=nx*c-ny*s; ny=nx*s+ny*c; nx=rx; }
        float u=nx/aspect*0.5f+0.5f, v=ny*0.5f+0.5f, radialX=nx/max(0.0001f,aspect), radialY=ny;
        float ca=p.ca/max(w,h), hcaBase=p.highlightCA/max(w,h);
        float rr=sample_channel(src,p.width,p.height,u+radialX*ca,v+radialY*ca,0);
        float gg=sample_channel(src,p.width,p.height,u,v,1);
        float bb=sample_channel(src,p.width,p.height,u-radialX*ca,v-radialY*ca,2);
        float luma=max(0.0f,0.2126f*rr+0.7152f*gg+0.0722f*bb), hca=hcaBase*min(1.0f,luma);
        if (hca>0.0f) { rr=sample_channel(src,p.width,p.height,u+radialX*hca,v+radialY*hca,0); bb=sample_channel(src,p.width,p.height,u-radialX*hca,v-radialY*hca,2); }
        if (p.spherical>0.001f) { float blur=p.spherical*(0.25f+0.75f*rn*rn)/max(w,h)*5.0f; rr=rr*(1.0f-p.spherical*0.18f)+sample_channel(src,p.width,p.height,u+blur,v,0)*(p.spherical*0.09f)+sample_channel(src,p.width,p.height,u-blur,v,0)*(p.spherical*0.09f); bb=bb*(1.0f-p.spherical*0.18f)+sample_channel(src,p.width,p.height,u,v+blur,2)*(p.spherical*0.09f)+sample_channel(src,p.width,p.height,u,v-blur,2)*(p.spherical*0.09f); }
        uint o=(gid.y*p.width+gid.x)*4; float vg=max(0.0f,1.0f-p.vignette*pow(rn,2.2f)); float sg=max(0.72f,1.0f-p.edgeSoft*rn*rn*0.16f);
        dst[o]=rr*vg*sg; dst[o+1]=gg*vg*sg; dst[o+2]=bb*vg*sg; dst[o+3]=src[o+3];
    }
    """#
}
