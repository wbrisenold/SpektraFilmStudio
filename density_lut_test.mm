// GPL-3.0. Actual native GPU reference/LUT comparison and cache invalidation.
#include "SpektraAppBridge.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <vector>
#include <chrono>
#include <cstdlib>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <cstring>

int main(int argc, char **argv) {
  auto renderer = SpektraRendererCreate();
  if (!renderer || !SpektraRendererIsAvailable(renderer)) return 2;
  int w = argc > 1 ? std::atoi(argv[1]) : 192, h = w*2/3;
  std::vector<float> input(w*h*4), reference(input.size()), accelerated(input.size());
  unsigned rng=73;
  for (size_t i=0;i<input.size();i+=4) {
    for(int c=0;c<3;c++) { rng=1664525*rng+1013904223; float u=float(rng>>8)/16777216.f; input[i+c]=std::pow(u,3.f)*8.f-.015f; }
    input[i+3]=float((i/4)%17)/16.f;
  }
  if(argc>3) {
    CFURLRef url=CFURLCreateFromFileSystemRepresentation(nullptr,(const UInt8*)argv[3],std::strlen(argv[3]),false);
    CGImageSourceRef source=CGImageSourceCreateWithURL(url,nullptr);
    CGImageRef image=source?CGImageSourceCreateImageAtIndex(source,0,nullptr):nullptr;
    if(!image)return 8;
    std::vector<unsigned char> bytes(w*h*4);
    CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context=CGBitmapContextCreate(bytes.data(),w,h,8,w*4,space,kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(context,CGRectMake(0,0,w,h),image);
    for(size_t i=0;i<input.size();i+=4) {
      float rgb[3];for(int c=0;c<3;c++){float v=bytes[i+c]/255.f;rgb[c]=v<=.04045f?v/12.92f:std::pow((v+.055f)/1.055f,2.4f);}
      input[i]=.627404f*rgb[0]+.329283f*rgb[1]+.043313f*rgb[2];
      input[i+1]=.069097f*rgb[0]+.91954f*rgb[1]+.011362f*rgb[2];
      input[i+2]=.016391f*rgb[0]+.088013f*rgb[1]+.895595f*rgb[2];input[i+3]=1;
    }
    CGContextRelease(context);CGColorSpaceRelease(space);CGImageRelease(image);CFRelease(source);CFRelease(url);
  }
  SpektraImageBuffer src{input.data(),w,h,w*16,4,4};
  auto render = [&](SpektraAppRenderParams p, bool lut, std::vector<float>& output) {
    SpektraImageBuffer dst{output.data(),w,h,w*16,4,4};
    SpektraRendererSetDensityLutsEnabled(renderer,lut);
    auto start=std::chrono::steady_clock::now();
    if(!SpektraRendererRender(renderer,&src,&dst,&p,0)) {
      fprintf(stderr,"RENDER FAIL: %s\n",SpektraRendererLastError(renderer)); std::exit(3);
    }
    if(argc>2) {
      auto d=SpektraRendererLastDiagnostics(renderer);
      printf("timing lut=%d setup=%.2f copyIn=%.2f command=%.2f copyOut=%.2f passes=%u\n",lut,d.cpuSetupMs,d.sourceCopyMs,d.commandBufferMs,d.outputCopyMs,d.passCount);
    }
    return std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
  };
  double worst=0, sum=0; size_t samples=0;
  int cases=argc>2?1:std::max(25, int(SpektraAppFilmCount()));
  for(int test=0;test<cases;test++) {
    auto p=SpektraAppMakeDefaultRenderParams();
    p.inputColorSpace=SpektraAppLinearRec2020ColorSpace();
    if(std::getenv("SPEKTRAFILM_TEST_FAST_DIR")) {
      p.dirCouplersDiffusionUm=0;
      p.dirCouplersDiffusionTailUm=0;
    }
    if(test>0) {p.film=(test*3)%SpektraAppFilmCount();p.paper=test%SpektraAppPaperCount();}
    if(test==2) {p.printExposureEv=1.5f;p.filterMShift=25;p.filterYShift=-10;p.preflashExposure=.03f;}
    if(test==3) {p.negativeBleachBypassAmount=.7f;p.printBleachBypassAmount=.5f;}
    if(test==4) {p.printDiffusionEnabled=1;p.printDiffusionStrength=.3f;p.printDiffusionSpatialScale=1;}
    if(test==5) {p.scannerEnabled=1;p.scannerMtf50LpMm=30;p.scannerUnsharpRadiusUm=15;p.scannerUnsharpAmount=.5f;}
    if(test==6) {p.outputColorSpace=14; p.glarePercent=.1f;}
    if(test==7) {p.outputRole=1;}
    if(test==8) {p.film=0;p.paper=0;p.printExposureEv=-2;}
    if(test==9) {p.grainEnabled=1;p.grainModel=0;}
    if(test==10) {p.grainEnabled=1;p.grainModel=1;}
    if(test==11) {p.grainEnabled=1;p.grainModel=2;}
    if(test==12) p.process=1;
    if(test==13) p.process=2;
    if(test==14) {p.outputRole=2;p.hdrTransfer=0;}
    if(test>=20) {
      p.film=2;p.paper=4;
      if(test==20) p.printExposureEv=-1;
      if(test==21) p.outputColorSpace=17;
      if(test==22) p.filterMShift=20;
      if(test==23) p.preflashExposure=.05f;
      if(test==24) p.printGamma=.8f;
    }
    double refMs=render(p,false,reference), cold=render(p,true,accelerated);
    auto coldPasses=SpektraRendererLastDiagnostics(renderer).passCount;
    double hot=render(p,true,accelerated);
    auto hotPasses=SpektraRendererLastDiagnostics(renderer).passCount;
    if(test==0 && coldPasses!=hotPasses+5) {fprintf(stderr,"LUT cache reuse failed\n");return 7;}
    if(argc>2) {
      std::vector<double> refTimes, lutTimes;
      for(int repeat=0;repeat<3;repeat++) {refTimes.push_back(render(p,false,reference));lutTimes.push_back(render(p,true,accelerated));}
      std::sort(refTimes.begin(),refTimes.end());std::sort(lutTimes.begin(),lutTimes.end());
      refMs=refTimes[1];hot=lutTimes[1];
    }
    double maxError=0, rms=0; size_t n=0;
    for(size_t i=0;i<reference.size();i++) {
      if(!std::isfinite(reference[i]) || !std::isfinite(accelerated[i])) return 4;
      if(i%4==3) {if(reference[i]!=accelerated[i]) return 5;continue;}
      double error=std::abs(double(reference[i])-accelerated[i])/std::max(1.,std::abs(double(reference[i])));
      if(error>maxError){ maxError=error; if(error>.001) printf("peak pixel=%zu channel=%zu in=%g,%g,%g ref=%g lut=%g\n",i/4,i%4,input[(i/4)*4],input[(i/4)*4+1],input[(i/4)*4+2],reference[i],accelerated[i]); }rms+=error*error;n++;
    }
    worst=std::max(worst,maxError);sum+=rms;samples+=n;
    printf("LUT case %d film=%d paper=%d reference=%.2fms cold=%.2fms warm=%.2fms max=%.8f rms=%.8f\n",test,p.film,p.paper,refMs,cold,hot,maxError,std::sqrt(rms/n));fflush(stdout);
    if(maxError>0.002 || std::sqrt(rms/n)>0.0001) return 6;
  }
  SpektraRendererDestroy(renderer);
  printf("DENSITY_LUT_PASS max=%.8f rms=%.8f\n",worst,std::sqrt(sum/samples));
}
