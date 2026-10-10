import Foundation
import Metal

/// Analytical tone/color-density/film-input math on Metal. The spectral film kernel stays intact.
final class GPUHostGradeEngine: @unchecked Sendable {
    static let shared = GPUHostGradeEngine()
    private let device: (any MTLDevice)?
    private let lock = NSLock()
    private var pipeline: MTLComputePipelineState?
    private var queue: MTLCommandQueue?
    private convenience init() { self.init(device: StudioGPUDevice.shared) }
    init(device: (any MTLDevice)?) {
        self.device = device
        guard let device else { return }
        queue = device.makeCommandQueue()
        let options = MTLCompileOptions(); options.mathMode = .safe
        do {
            let library = try device.makeLibrary(source: Self.shader, options: options)
            if let function = library.makeFunction(name: "hostGrade") { pipeline = try device.makeComputePipelineState(function: function) }
        } catch { GPUProcessingFailure.report("GPU tone shader: \(error.localizedDescription)") }
    }
    /// Enqueue the EXACT existing hostGrade Metal shader on caller-owned buffers.
    /// No CPU copies/readback and no waitUntilCompleted. The caller serializes
    /// submission on the same queue as the native spectral film renderer.
    func encode(source: any MTLBuffer, destination: any MTLBuffer,
                on command: any MTLCommandBuffer, width: Int, height: Int,
                tone: ToneSettings?, density: ColorDensitySettings?, film: ToneSettings?) throws {
        let t = tone ?? ToneSettings(), f = film ?? ToneSettings(), d = density ?? ColorDensitySettings()
        guard !t.autoContrast && !f.autoContrast else {
            throw GPULiveError.unavailable("Auto Contrast needs quantile analysis")
        }
        guard let device, let pipeline, source.device.registryID == device.registryID,
              destination.device.registryID == device.registryID else {
            throw GPULiveError.unavailable("host grade GPU device/pipeline mismatch")
        }
        let points = ToneCurveMath.normalize(t.curvePoints)
        let curve = ToneCurveMath.buildCache(points)
        let identity = points.count == 2 && points[0] == ToneCurvePoint(x: 0, y: 0)
                    && points[1] == ToneCurvePoint(x: 1, y: 1)
        let p: [Float] = [
            Float(t.exposureEV), Float(t.brightness), Float(t.midtones), Float(t.contrast),
            Float(t.shadows), Float(t.highlights), Float(t.highlightRecovery), Float(t.shadowRecovery),
            Float(t.blacks), Float(t.whites), Float(t.blackPoint), Float(t.whitePoint),
            0, 0, identity ? 0 : Float(points.count), d.isIdentity ? 0 : 1,
            Float(d.master), Float(d.red), Float(d.yellow), Float(d.green),
            Float(d.cyan), Float(d.blue), Float(d.magenta), film == nil ? 0 : 1,
            Float(f.blacks), Float(f.shadows), Float(f.brightness), Float(f.highlights),
            Float(f.whites), Float(f.highlightRecovery), Float(f.shadowRecovery),
            Float(f.contrast), 0, 0, tone != nil || !d.isIdentity ? 1 : 0
        ]
        let knots = points.indices.map {
            SIMD4<Float>(Float(points[$0].x), Float(points[$0].y), Float(curve.m[$0]), 0)
        }
        guard let pb = p.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!,
                            length: $0.count, options: .storageModeShared) }),
              let kb = knots.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!,
                            length: $0.count, options: .storageModeShared) }),
              let encoder = command.makeComputeCommandEncoder() else {
            throw GPULiveError.unavailable("host grade parameter buffer allocation failed")
        }
        var count = UInt32(width * height)
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(source, offset: 0, index: 0)
        encoder.setBuffer(destination, offset: 0, index: 1)
        encoder.setBuffer(pb, offset: 0, index: 2)
        encoder.setBuffer(kb, offset: 0, index: 3)
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 4)
        encoder.dispatchThreads(MTLSize(width: width * height, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: min(256, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        encoder.endEncoding()
    }

    func apply(_ input: PixelBufferF32, tone: ToneSettings?, density: ColorDensitySettings?, film: ToneSettings?) -> PixelBufferF32 {
        let t = tone ?? ToneSettings(), f = film ?? ToneSettings(), d = density ?? ColorDensitySettings()
        if t == ToneSettings() && d.isIdentity && f == ToneSettings() { return input }
        lock.lock(); defer { lock.unlock() }
        guard let device, let queue, let pipeline, input.width > 0, input.height > 0,
              input.pixels.count == input.width * input.height * 4 else {
            GPUProcessingFailure.report("GPU tone processing unavailable"); return input
        }
        let points = ToneCurveMath.normalize(t.curvePoints), curve = ToneCurveMath.buildCache(points)
        let identity = points.count == 2 && points[0] == ToneCurvePoint(x: 0, y: 0) && points[1] == ToneCurvePoint(x: 1, y: 1)
        let bounds = t.autoContrast ? AutoContrastMath.bounds(input.pixels) : nil
        var p: [Float] = [Float(t.exposureEV),Float(t.brightness),Float(t.midtones),Float(t.contrast),Float(t.shadows),Float(t.highlights),Float(t.highlightRecovery),Float(t.shadowRecovery),Float(t.blacks),Float(t.whites),Float(t.blackPoint),Float(t.whitePoint),Float(bounds?.black ?? 0),Float(bounds?.white ?? 0),identity ? 0 : Float(points.count),d.isIdentity ? 0 : 1,Float(d.master),Float(d.red),Float(d.yellow),Float(d.green),Float(d.cyan),Float(d.blue),Float(d.magenta),film == nil ? 0 : 1,Float(f.blacks),Float(f.shadows),Float(f.brightness),Float(f.highlights),Float(f.whites),Float(f.highlightRecovery),Float(f.shadowRecovery),Float(f.contrast),0,0,tone != nil || !d.isIdentity ? 1 : 0]
        if f.autoContrast {
            var samples: [Double] = []
            let step = max(1, Int(sqrt(Double(max(1,input.width * input.height / 4096)))))
            for y in stride(from: 0,to: input.height,by: step) { for x in stride(from: 0,to: input.width,by: step) {
                let i = (y * input.width + x) * 4
                samples.append(log2(max(1e-8,0.2126 * Double(input.pixels[i]) + 0.7152 * Double(input.pixels[i+1]) + 0.0722 * Double(input.pixels[i+2]))))
            } }
            if samples.count >= 16 {
                samples.sort(); let lo = samples[Int(Double(samples.count-1)*0.02)], hi = samples[Int(Double(samples.count-1)*0.98)]
                if hi-lo > 0.5 { p[32] = Float(lo); p[33] = Float(hi) }
            }
        }
        let control = points.indices.map { SIMD4<Float>(Float(points[$0].x),Float(points[$0].y),Float(curve.m[$0]),0) }
        let length = input.pixels.count * MemoryLayout<Float>.size
        guard let source = input.pixels.withUnsafeBytes({ device.makeBuffer(bytes:$0.baseAddress!,length:length,options:.storageModeShared) }),
              let destination = device.makeBuffer(length:length,options:.storageModeShared),
              let parameters = p.withUnsafeBytes({ device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared) }),
              let knots = control.withUnsafeBytes({ device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared) }),
              let command = queue.makeCommandBuffer(),let encoder = command.makeComputeCommandEncoder() else {
            GPUProcessingFailure.report("GPU tone allocation failed"); return input
        }
        var count = UInt32(input.width * input.height)
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(source,offset:0,index:0);encoder.setBuffer(destination,offset:0,index:1)
        encoder.setBuffer(parameters,offset:0,index:2);encoder.setBuffer(knots,offset:0,index:3)
        encoder.setBytes(&count,length:4,index:4)
        encoder.dispatchThreads(MTLSize(width:Int(count),height:1,depth:1),threadsPerThreadgroup:MTLSize(width:min(256,pipeline.maxTotalThreadsPerThreadgroup),height:1,depth:1))
        encoder.endEncoding();command.commit();command.waitUntilCompleted()
        guard command.status == .completed else { GPUProcessingFailure.report("GPU tone execution failed");return input }
        let pixels = Array(UnsafeBufferPointer(start:destination.contents().assumingMemoryBound(to:Float.self),count:input.pixels.count))
        return PixelBufferF32(width:input.width,height:input.height,pixels:pixels)
    }
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    float luma(float3 c) { return dot(c,float3(0.2126f,0.7152f,0.0722f)); }
    float unit(float x) { return clamp(x/100.0f,-1.0f,1.0f); }
    float enc(float x) { if(x<0) return (-16.0f+9.72f)/17.52f+x; return (log2(x<0.000030517578125f?0.0000152587890625f+x*0.5f:x)+9.72f)/17.52f; }
    float dec(float x) { if(x<(-16.0f+9.72f)/17.52f) return x-(-16.0f+9.72f)/17.52f;float a=exp2(x*17.52f-9.72f);return x<=(-15.0f+9.72f)/17.52f?(a-0.0000152587890625f)*2.0f:a; }
    float3 shadows(float3 c,float amount) {
      float y=max(0.0f,luma(c));if(y<=1e-6f||abs(amount)<1e-12f)return c;
      float t=pow(y,1.0f/2.2f),v=pow(max(t+amount*t*pow(max(1.0f-t,0.0f),4.5f),0.0f),2.2f),ratio=v/max(y,1e-12f);
      float3 out=c*ratio;return mix(out,float3(v),clamp((ratio-1.0f)*0.15f,0.0f,0.4f));
    }
    float3 highlights(float3 c,float amount) {
      float y=max(0.0f,luma(c));if(y<=0.1f||abs(amount)<1e-12f)return c;
      float delta=y-0.1f;
      float target=0.1f+(amount<0?delta/(1.0f-amount*2.2f*(delta/(1.0f+delta*0.35f))):delta*(1.0f+amount*0.7f/(1.0f+delta*0.25f)));
      float v=mix(y,target,smoothstep(0.1f,0.45f,y));float3 out=c*(v/max(y,1e-12f));
      return amount<0&&y>1?mix(out,float3(v),smoothstep(1.0f,3.5f,y)*(-amount)*0.4f):out;
    }
    float3 brightness(float3 c,float a) {
      float y=luma(c);if(abs(a)<1e-12f||abs(y)<=1e-5f)return c;
      float k=exp2(-a*1.2f),v=abs(y),shaped=v<=1?v/max(v+(1-v)*k,1e-12f):1+(v-1)*k;
      float exponent=mix(0.95f,0.65f,clamp(shaped,0.0f,2.0f)*0.5f);
      float scale=pow(max(shaped/max(v,1e-12f),1e-12f),exponent)*mix(1.0f,clamp((1.05f-shaped)/max(1.05f-y,1e-4f),0.0f,1.0f),min(1.0f,abs(a)));
      return copysign(shaped,y)+(c-y)*scale;
    }
    float curve(float x,constant float4 *knots,uint n) {
      if(n<2)return x;
      uint i=0;
      if(x<=knots[0].x) return knots[0].y+(x-knots[0].x)*(knots[1].y-knots[0].y)/max(knots[1].x-knots[0].x,1e-6f);
      if(x>=knots[n-1].x) { i=n-2;return knots[i].y+(x-knots[i].x)*(knots[i+1].y-knots[i].y)/max(knots[i+1].x-knots[i].x,1e-6f); }
      while(i<n-2&&x>=knots[i+1].x)++i;
      float h=knots[i+1].x-knots[i].x,t=(x-knots[i].x)/h,t2=t*t,t3=t2*t;
      return (2*t3-3*t2+1)*knots[i].y+(t3-2*t2+t)*h*knots[i].z+(-2*t3+3*t2)*knots[i+1].y+(t3-t2)*h*knots[i+1].z;
    }
    float satmag(float theta,float phi) {
      float base=0.61547971f,corner=0.78539816f,pi=3.141592653589793f;
      float coef=1/(2-corner/base),sector=fmod(theta,pi/3),h2=2*phi*sin(2*pi/3-sector)/1.7320508075688f;
      return sin((acos(clamp(cos(3*theta+pi),-1.0f,1.0f))/(pi*coef)+(corner/base-1))*h2+base);
    }
    float3 density(float3 c,constant float *p) {
      if(p[15]==0)return c;
      float3 rotated=float3(dot(c,float3(0.81649658f,-0.40824829f,-0.40824829f)),dot(c,float3(0,0.70710678f,-0.70710678f)),dot(c,float3(0.57735027f)));
      float theta=atan2(rotated.y,rotated.x);if(theta<0)theta+=6.283185307179586f;
      float phi=atan2(length(rotated.xy),rotated.z),sat=satmag(theta,phi),radius=length(rotated)*sat,hue=theta*0.15915494309189535f,polar=phi*1.0467733744265997f;
      float factor=1+clamp(p[16],-1.0f,0.0f)*polar;
      float centers[6]={0,0.1666f,0.3330f,0.4999f,0.6660f,0.8333f};
      for(uint i=0;i<6;i++){float delta=abs(hue-centers[i]);if(i==0)delta=min(delta,1-delta);if(delta<=0.1666f)factor*=1+clamp(p[17+i],-1.0f,0.0f)*(1-delta/0.1666f)*polar;}
      float safe=abs(sat)<1e-12f?copysign(1e-12f,sat):sat;
      float r=radius*factor/safe;
      float3 q=float3(r*sin(phi)*cos(theta),r*sin(phi)*sin(theta),r*cos(phi));
      return float3(q.x*0.81649658f+q.z*0.57735027f,q.x*-0.40824829f+q.y*0.70710678f+q.z*0.57735027f,q.x*-0.40824829f+q.y*-0.70710678f+q.z*0.57735027f);
    }
    float gauss(float x,float center,float sigma){float d=(x-center)/sigma;return exp(-0.5f*d*d);}
    kernel void hostGrade(device const float4 *input [[buffer(0)]],device float4 *output [[buffer(1)]],constant float *p [[buffer(2)]],constant float4 *knots [[buffer(3)]],constant uint &count [[buffer(4)]],uint i [[thread_position_in_grid]]) {
      if(i>=count)return;float4 pixel=input[i];float3 c=pixel.xyz;
      if(p[34]!=0) {
      if(p[13]>p[12]) {float y=dot(c,float3(0.2627f,0.6780f,0.0593f)),target=(y-p[12])/(p[13]-p[12]);c=y>1e-9f?c*(target/y):(target<=0?float3(0):c);}
      c*=exp2(clamp(p[0],-10.0f,10.0f));c=brightness(c,unit(p[1]));
      float y=max(0.0f,luma(c)),mid=max(0.0f,smoothstep(-0.1f,0.3f,y)-smoothstep(0.3f,0.7f,y));c+=y*(exp2(unit(p[2])*1.25f*mid)-1);
      if(abs(p[3])>1e-9f){y=dot(c,float3(0.2627f,0.6780f,0.0593f));if(y>1e-9f){float slope=exp2(unit(p[3])),gain=exp2((slope-1)*2.5f*tanh(log2(y/0.18f)/2.5f));c=y*gain+(c-y)*sqrt(slope)*min(gain,1.0f);}}
      c=shadows(c,unit(p[4]));c=highlights(c,unit(p[5]));c=highlights(c,-clamp(p[6]/100.0f,0.0f,1.0f));c=shadows(c,clamp(p[7]/100.0f,0.0f,1.0f));
      float3 cc=float3(enc(c.x),enc(c.y),enc(c.z));float black=clamp(p[10]*0.0008f,-0.08f,0.08f),white=1-clamp(p[11]*0.0008f,-0.08f,0.08f);
      cc=(cc-black)/max(0.1f,white-black);float w=clamp(p[9],-100.0f,100.0f);cc*=w>=0?1+w*0.005f:1/(1-w*0.005f);cc+=clamp(p[8],-100.0f,100.0f)*0.001f;
      cc=float3(curve(cc.x,knots,uint(p[14])),curve(cc.y,knots,uint(p[14])),curve(cc.z,knots,uint(p[14])));cc=density(cc,p);c=float3(dec(cc.x),dec(cc.y),dec(cc.z));
      }
      if(p[23]!=0){float ev=clamp(log2(max(1e-8f,luma(c))),-12.0f,4.0f);float correction=gauss(ev,-7,1.10f)*unit(p[24])*2+gauss(ev,-4.5f,1.35f)*unit(p[25])*2+gauss(ev,-2.5f,2.20f)*unit(p[26])*1.5f+gauss(ev,-1.25f,1.25f)*unit(p[27])*2+gauss(ev,-0.20f,0.85f)*unit(p[28])*2;
        correction-=gauss(ev,-0.65f,1.05f)*clamp(p[29]/100.0f,0.0f,1.0f)*2.25f;correction+=gauss(ev,-5.7f,1.25f)*clamp(p[30]/100.0f,0.0f,1.0f)*2.25f;
        correction+=clamp((ev+2.5f)/3.25f,-1.0f,1.0f)*unit(p[31])*1.35f;
        if(p[33]>p[32]) correction+=clamp(-7+clamp((ev-p[32])/(p[33]-p[32]),0.0f,1.0f)*6.8f-ev,-2.0f,2.0f);
        c*=exp2(clamp(correction,-2.5f,2.5f));}
      output[i]=float4(c,pixel.w);
    }
    """
}

extension PixelBufferF32 {
    func applyingHostAndFilmGrade(tone: ToneSettings?, density: ColorDensitySettings?, film: ToneSettings?) -> PixelBufferF32 {
        if film?.autoContrast == true {
            return applyingHostGrade(tone: tone, density: density).applyingFilmExposureShape(film)
        }
        return GPUHostGradeEngine.shared.apply(self, tone: tone, density: density, film: film)
    }

    func applyingHostGrade(tone: ToneSettings?, density: ColorDensitySettings?) -> PixelBufferF32 {
        GPUHostGradeEngine.shared.apply(self,tone:tone,density:density,film:nil)
    }
    func applyingFilmExposureShape(_ settings: ToneSettings?) -> PixelBufferF32 {
        guard let settings else { return self }
        return GPUHostGradeEngine.shared.apply(self,tone:nil,density:nil,film:settings)
    }
}
