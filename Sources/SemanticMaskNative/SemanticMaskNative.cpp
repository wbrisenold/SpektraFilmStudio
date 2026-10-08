#include "SemanticMaskNative.h"
#include <onnxruntime_cxx_api.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <memory>
#include <limits>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>
namespace {
std::mutex g_mutex; Ort::Env g_env(ORT_LOGGING_LEVEL_WARNING,"SpektraSemantic");
std::unordered_map<std::string,std::shared_ptr<Ort::Session>> g_sessions; std::string g_version=OrtGetApiBase()->GetVersionString();
void err(char*b,int n,const std::string&s){if(b&&n>0)std::snprintf(b,(size_t)n,"%s",s.c_str());}
std::shared_ptr<Ort::Session> sess(const char*p){if(!p||!*p)throw std::runtime_error("Missing model path");std::lock_guard<std::mutex>l(g_mutex);auto i=g_sessions.find(p);if(i!=g_sessions.end())return i->second;Ort::SessionOptions o;o.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);o.SetIntraOpNumThreads((int)std::max(1u,std::thread::hardware_concurrency()/2));auto s=std::make_shared<Ort::Session>(g_env,p,o);g_sessions.emplace(p,s);return s;}
float px(const uint8_t*r,int w,int h,float x,float y,int c){x=std::clamp(x,0.f,float(w-1));y=std::clamp(y,0.f,float(h-1));int x0=(int)floor(x),y0=(int)floor(y),x1=std::min(w-1,x0+1),y1=std::min(h-1,y0+1);float fx=x-x0,fy=y-y0;auto v=[&](int X,int Y){return float(r[(Y*w+X)*4+c])/255.f;};return (v(x0,y0)*(1-fx)+v(x1,y0)*fx)*(1-fy)+(v(x0,y1)*(1-fx)+v(x1,y1)*fx)*fy;}
std::vector<float> input(const uint8_t*r,int w,int h,int tw,int th,int profile){std::vector<float>o((size_t)3*tw*th);std::array<float,3>m,s;if(profile==SF_SEMANTIC_FACE19||profile==SF_SEMANTIC_BIREFNET){m={.485f,.456f,.406f};s={.229f,.224f,.225f};}else if(profile==SF_SEMANTIC_SCHP_LIP20){m={.406f,.456f,.485f};s={.225f,.224f,.229f};}else{m={.5f,.5f,.5f};s={.5f,.5f,.5f};}for(int y=0;y<th;y++)for(int x=0;x<tw;x++){float sx=(x+.5f)*w/tw-.5f,sy=(y+.5f)*h/th-.5f;for(int c=0;c<3;c++)o[((size_t)c*th+y)*tw+x]=(px(r,w,h,sx,sy,c)-m[c])/s[c];}return o;}
std::vector<Ort::Value> run(const char*path,int profile,const uint8_t*r,int w,int h,int&oh,int&ow,int&ch){auto se=sess(path);Ort::AllocatorWithDefaultOptions a;auto n=se->GetInputNameAllocated(0,a);auto sh=se->GetInputTypeInfo(0).GetTensorTypeAndShapeInfo().GetShape();int th=profile==SF_SEMANTIC_BIREFNET?1024:(profile==SF_SEMANTIC_FACE19?512:(profile==SF_SEMANTIC_SCHP_LIP20?473:512)),tw=th;if(sh.size()>=4&&sh[2]>0&&sh[3]>0){if(sh[2]>4096||sh[3]>4096)throw std::runtime_error("Semantic input too large");th=(int)sh[2];tw=(int)sh[3];}if(sh.size()!=4||sh[0]>1||sh[1]!=3||tw<=0||th<=0||tw>4096||th>4096)throw std::runtime_error("Unsupported semantic input shape");auto in=input(r,w,h,tw,th,profile);std::array<int64_t,4>d={1,3,th,tw};auto mi=Ort::MemoryInfo::CreateCpu(OrtArenaAllocator,OrtMemTypeDefault);auto t=Ort::Value::CreateTensor<float>(mi,in.data(),in.size(),d.data(),d.size());auto on=se->GetOutputNameAllocated(0,a);const char*ins[]={n.get()};const char*outs[]={on.get()};auto o=se->Run(Ort::RunOptions{nullptr},ins,&t,1,outs,1);auto os=o[0].GetTensorTypeAndShapeInfo().GetShape();if(os.size()!=4||os[0]!=1||os[1]<1||os[1]>256||os[2]<1||os[2]>4096||os[3]<1||os[3]>4096)throw std::runtime_error("semantic output must be bounded rank-4 NCHW");ch=(int)os[1];oh=(int)os[2];ow=(int)os[3];return o;}
}
extern "C" const char*sf_semantic_runtime_version(void){return g_version.c_str();}
extern "C" int sf_semantic_labels_run(const char* path,int profile,const uint8_t*rgba,int w,int h,uint8_t*out,char*e,int en){
    try {
        if(profile==SF_SEMANTIC_MODNET)throw std::runtime_error("MODNet is a matte model");
        if(!path||!rgba||!out||w<=0||h<=0||w>16384||h>16384)throw std::runtime_error("Invalid segmentation input");
        int oh=0,ow=0,ch=0;
        auto values=run(path,profile,rgba,w,h,oh,ow,ch);
        if(ow<1||oh<1||ch<2)throw std::runtime_error("Invalid semantic output shape");
        const float*d=values[0].GetTensorMutableData<float>();
        // Bilinear interpolation of class logits BEFORE argmax, rather than
        // enlarging coarse hard-label IDs with nearest-neighbor resampling.
        for(int y=0;y<h;++y){
            const float sy=(y+.5f)*oh/float(h)-.5f;
            const int y0=std::clamp(int(std::floor(sy)),0,oh-1),y1=std::min(oh-1,y0+1);
            const float fy=std::clamp(sy-float(y0),0.f,1.f);
            for(int x=0;x<w;++x){
                const float sx=(x+.5f)*ow/float(w)-.5f;
                const int x0=std::clamp(int(std::floor(sx)),0,ow-1),x1=std::min(ow-1,x0+1);
                const float fx=std::clamp(sx-float(x0),0.f,1.f);
                int best=0;float bestScore=-std::numeric_limits<float>::infinity();
                for(int c=0;c<ch;++c){
                    const size_t plane=size_t(c)*size_t(oh)*size_t(ow);
                    const float a=d[plane+size_t(y0)*ow+x0],bb=d[plane+size_t(y0)*ow+x1];
                    const float cc=d[plane+size_t(y1)*ow+x0],dd=d[plane+size_t(y1)*ow+x1];
                    const float score=(1.f-fy)*((1.f-fx)*a+fx*bb)+fy*((1.f-fx)*cc+fx*dd);
                    if(score>bestScore){bestScore=score;best=c;}
                }
                out[size_t(y)*w+x]=uint8_t(std::min(best,255));
            }
        }
        return 0;
    }catch(const std::exception&x){err(e,en,x.what());return 1;}
}
extern "C" int sf_semantic_matte_run(const char*path,const uint8_t*r,int w,int h,uint8_t*out,char*e,int en){
  try{
    if(!path||!r||!out||w<=0||h<=0||w>16384||h>16384)throw std::runtime_error("Invalid matte input");
    const bool isBiRef = std::string(path).find("birefnet-lite")!=std::string::npos;
    int oh=0,ow=0,ch=0;
    auto o=run(path,isBiRef?SF_SEMANTIC_BIREFNET:SF_SEMANTIC_MODNET,r,w,h,oh,ow,ch);
    if(ch!=1 || ow<1 || oh<1)throw std::runtime_error("subject matte expected one output channel");
    float*d=o[0].GetTensorMutableData<float>();
    for(int y=0;y<h;y++)for(int x=0;x<w;x++){
      const float px0=(x+.5f)*ow/float(w)-.5f,py0=(y+.5f)*oh/float(h)-.5f;
      int x0=std::clamp(int(std::floor(px0)),0,ow-1), y0=std::clamp(int(std::floor(py0)),0,oh-1);
      int x1=std::min(ow-1,x0+1),y1=std::min(oh-1,y0+1);
      float fx=std::clamp(px0-float(x0),0.f,1.f),fy=std::clamp(py0-float(y0),0.f,1.f);
      float v=(1-fy)*((1-fx)*d[y0*ow+x0]+fx*d[y0*ow+x1])
                +fy*((1-fx)*d[y1*ow+x0]+fx*d[y1*ow+x1]);
      if(!std::isfinite(v)) v=0.f;
      if(isBiRef) v=1.f/(1.f+std::exp(-std::clamp(v,-40.f,40.f)));
      out[y*w+x]=uint8_t(std::lround(std::clamp(v,0.f,1.f)*255.f));
    }
    return 0;
  }catch(const std::exception&x){err(e,en,x.what());return 1;}
}

// MobileSAM ONNX encoder + mask decoder, CPUExecutionProvider through shared ORT sessions.
// Uses SAM resize-longest-side to 1024, ImageNet normalization, padded square embedding,
// positive/negative point labels, and decoder logits postprocessing.
extern "C" int sf_semantic_point_run(const char* encPath,const char* decPath,
    const uint8_t* rgb,int w,int h,float nx,float ny,uint8_t* alpha,char* e,int en){
  try {
    if(!encPath||!decPath||!rgb||!alpha||!std::isfinite(nx)||!std::isfinite(ny)||w<=0||h<=0||w>16384||h>16384)throw std::runtime_error("invalid MobileSAM image dimensions");
    auto encoder=sess(encPath), decoder=sess(decPath);
    const float scale=1024.f/float(std::max(w,h));
    const int rw=std::min(1024,std::max(1,int(std::round(w*scale))));
    const int rh=std::min(1024,std::max(1,int(std::round(h*scale))));
    std::vector<float> input(3*1024*1024,0.f);
    const float mean[3]={.485f,.456f,.406f}, stdev[3]={.229f,.224f,.225f};
    for(int y=0;y<rh;y++)for(int x=0;x<rw;x++) {
      const float sx=(x+.5f)*w/float(rw)-.5f,sy=(y+.5f)*h/float(rh)-.5f;
      for(int ch=0;ch<3;ch++)input[ch*1024*1024+y*1024+x]=(px(rgb,w,h,sx,sy,ch)-mean[ch])/stdev[ch];
    }
    Ort::MemoryInfo memory=Ort::MemoryInfo::CreateCpu(OrtArenaAllocator,OrtMemTypeDefault);
    std::array<int64_t,4> inputShape={1,3,1024,1024};
    auto tensor=Ort::Value::CreateTensor<float>(memory,input.data(),input.size(),inputShape.data(),inputShape.size());
    Ort::AllocatorWithDefaultOptions allocator;
    auto inputName=encoder->GetInputNameAllocated(0,allocator);
    auto outputName=encoder->GetOutputNameAllocated(0,allocator);
    const char* inputNames[]={inputName.get()}, *outputNames[]={outputName.get()};
    auto encoded=encoder->Run(Ort::RunOptions{nullptr},inputNames,&tensor,1,outputNames,1);
    if(encoded.empty())throw std::runtime_error("MobileSAM encoder returned no embedding");
    auto embedShape=encoded[0].GetTensorTypeAndShapeInfo().GetShape();
    if(embedShape.size()!=4||embedShape[1]!=256||embedShape[2]!=64||embedShape[3]!=64)
      throw std::runtime_error("MobileSAM encoder output incompatible with SAM decoder");
    std::array<float,4> points={std::clamp(nx,0.f,1.f)*rw, std::clamp(ny,0.f,1.f)*rh,0.f,0.f};
    std::array<float,2> labels={1.f,-1.f};
    std::vector<float> previous(256*256,0.f);
    std::array<float,1> hasPrevious={0.f};
    std::array<float,2> origSize={float(h),float(w)};
    std::array<int64_t,3> pointShape={1,2,2};
    std::array<int64_t,2> labelShape={1,2};
    std::array<int64_t,1> origSizeShape={2};
    std::array<int64_t,4> prevShape={1,1,256,256};
    std::array<int64_t,1> hasShape={1};
    std::vector<Ort::Value> values;
    std::vector<std::string> names;
    values.reserve(decoder->GetInputCount());names.reserve(decoder->GetInputCount());
    bool usedEmbedding=false;
    for(size_t i=0;i<decoder->GetInputCount();++i){
      auto n=decoder->GetInputNameAllocated(i,allocator);
      std::string label=n.get();names.push_back(label);
      if(label=="image_embeddings") {values.push_back(std::move(encoded[0]));usedEmbedding=true;}
      else if(label=="point_coords") values.push_back(Ort::Value::CreateTensor<float>(memory,points.data(),points.size(),pointShape.data(),pointShape.size()));
      else if(label=="point_labels") values.push_back(Ort::Value::CreateTensor<float>(memory,labels.data(),labels.size(),labelShape.data(),labelShape.size()));
      else if(label=="mask_input") values.push_back(Ort::Value::CreateTensor<float>(memory,previous.data(),previous.size(),prevShape.data(),prevShape.size()));
      else if(label=="has_mask_input") values.push_back(Ort::Value::CreateTensor<float>(memory,hasPrevious.data(),hasPrevious.size(),hasShape.data(),hasShape.size()));
      else if(label=="orig_im_size") values.push_back(Ort::Value::CreateTensor<float>(memory,origSize.data(),origSize.size(),origSizeShape.data(),origSizeShape.size()));
      else throw std::runtime_error(std::string("MobileSAM unsupported decoder input: ")+label);
    }
    if(!usedEmbedding)throw std::runtime_error("MobileSAM decoder missing embedding input");
    std::vector<const char*> inputKeys;inputKeys.reserve(names.size());
    for(auto& name:names)inputKeys.push_back(name.c_str());
    auto decName=decoder->GetOutputNameAllocated(0,allocator);
    const char* decNames[]={decName.get()};
    auto result=decoder->Run(Ort::RunOptions{nullptr},inputKeys.data(),values.data(),values.size(),decNames,1);
    if(result.empty())throw std::runtime_error("MobileSAM decoder returned empty masks");
    auto sh=result[0].GetTensorTypeAndShapeInfo().GetShape();
    if(sh.size()!=4||sh[0]!=1||sh[1]<1||sh[2]<=0||sh[3]<=0||sh[2]>4096||sh[3]>4096)throw std::runtime_error("MobileSAM invalid mask output shape");
    const int mh=int(sh[2]),mw=int(sh[3]);
    const float*matte=result[0].GetTensorData<float>();
    for(int y=0;y<h;++y)for(int x=0;x<w;++x){
      float ix=(x+.5f)*mw/float(w)-.5f,iy=(y+.5f)*mh/float(h)-.5f;
      int x0=std::clamp(int(std::floor(ix)),0,mw-1),y0=std::clamp(int(std::floor(iy)),0,mh-1);
      int x1=std::min(mw-1,x0+1),y1=std::min(mh-1,y0+1);
      float tx=std::clamp(ix-float(x0),0.f,1.f),ty=std::clamp(iy-float(y0),0.f,1.f);
      float v=(1-ty)*((1-tx)*matte[y0*mw+x0]+tx*matte[y0*mw+x1])
                +ty*((1-tx)*matte[y1*mw+x0]+tx*matte[y1*mw+x1]);
      if(!std::isfinite(v)) v=0.f;
      alpha[y*w+x]=uint8_t(std::lround(255.f/(1.f+std::exp(-std::clamp(v,-35.f,35.f)))));
    }
    return 0;
  }catch(const std::exception&x){err(e,en,x.what());return 1;}
}
