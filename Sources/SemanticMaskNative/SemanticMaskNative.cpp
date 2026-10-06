#include "SemanticMaskNative.h"
#include <onnxruntime_cxx_api.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>
namespace {
std::mutex g_mutex; Ort::Env g_env(ORT_LOGGING_LEVEL_WARNING,"SpektraSemantic");
std::unordered_map<std::string,std::shared_ptr<Ort::Session>> g_sessions; std::string g_version=OrtGetApiBase()->GetVersionString();
void err(char*b,int n,const std::string&s){if(b&&n>0)std::snprintf(b,(size_t)n,"%s",s.c_str());}
std::shared_ptr<Ort::Session> sess(const char*p){std::lock_guard<std::mutex>l(g_mutex);auto i=g_sessions.find(p);if(i!=g_sessions.end())return i->second;Ort::SessionOptions o;o.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);o.SetIntraOpNumThreads((int)std::max(1u,std::thread::hardware_concurrency()/2));auto s=std::make_shared<Ort::Session>(g_env,p,o);g_sessions.emplace(p,s);return s;}
float px(const uint8_t*r,int w,int h,float x,float y,int c){x=std::clamp(x,0.f,float(w-1));y=std::clamp(y,0.f,float(h-1));int x0=(int)floor(x),y0=(int)floor(y),x1=std::min(w-1,x0+1),y1=std::min(h-1,y0+1);float fx=x-x0,fy=y-y0;auto v=[&](int X,int Y){return float(r[(Y*w+X)*4+c])/255.f;};return (v(x0,y0)*(1-fx)+v(x1,y0)*fx)*(1-fy)+(v(x0,y1)*(1-fx)+v(x1,y1)*fx)*fy;}
std::vector<float> input(const uint8_t*r,int w,int h,int tw,int th,int profile){std::vector<float>o((size_t)3*tw*th);std::array<float,3>m,s;if(profile==SF_SEMANTIC_FACE19){m={.485f,.456f,.406f};s={.229f,.224f,.225f};}else if(profile==SF_SEMANTIC_SCHP_LIP20){m={.406f,.456f,.485f};s={.225f,.224f,.229f};}else{m={.5f,.5f,.5f};s={.5f,.5f,.5f};}for(int y=0;y<th;y++)for(int x=0;x<tw;x++){float sx=(x+.5f)*w/tw-.5f,sy=(y+.5f)*h/th-.5f;for(int c=0;c<3;c++)o[((size_t)c*th+y)*tw+x]=(px(r,w,h,sx,sy,c)-m[c])/s[c];}return o;}
std::vector<Ort::Value> run(const char*path,int profile,const uint8_t*r,int w,int h,int&oh,int&ow,int&ch){auto se=sess(path);Ort::AllocatorWithDefaultOptions a;auto n=se->GetInputNameAllocated(0,a);auto sh=se->GetInputTypeInfo(0).GetTensorTypeAndShapeInfo().GetShape();int th=profile==SF_SEMANTIC_FACE19?512:(profile==SF_SEMANTIC_SCHP_LIP20?473:512),tw=th;if(sh.size()>=4&&sh[2]>0&&sh[3]>0){th=(int)sh[2];tw=(int)sh[3];}auto in=input(r,w,h,tw,th,profile);std::array<int64_t,4>d={1,3,th,tw};auto mi=Ort::MemoryInfo::CreateCpu(OrtArenaAllocator,OrtMemTypeDefault);auto t=Ort::Value::CreateTensor<float>(mi,in.data(),in.size(),d.data(),d.size());auto on=se->GetOutputNameAllocated(0,a);const char*ins[]={n.get()};const char*outs[]={on.get()};auto o=se->Run(Ort::RunOptions{nullptr},ins,&t,1,outs,1);auto os=o[0].GetTensorTypeAndShapeInfo().GetShape();if(os.size()!=4)throw std::runtime_error("semantic output must be rank-4 NCHW");ch=(int)os[1];oh=(int)os[2];ow=(int)os[3];return o;}
}
extern "C" const char*sf_semantic_runtime_version(void){return g_version.c_str();}
extern "C" int sf_semantic_labels_run(const char*path,int profile,const uint8_t*r,int w,int h,uint8_t*out,char*e,int en){try{if(profile==SF_SEMANTIC_MODNET)throw std::runtime_error("MODNet is a matte model");int oh=0,ow=0,ch=0;auto o=run(path,profile,r,w,h,oh,ow,ch);float*d=o[0].GetTensorMutableData<float>();for(int y=0;y<h;y++)for(int x=0;x<w;x++){int sy=std::clamp(int((y+.5f)*oh/h),0,oh-1),sx=std::clamp(int((x+.5f)*ow/w),0,ow-1),best=0;float bv=d[sy*ow+sx];for(int c=1;c<ch;c++){float v=d[((size_t)c*oh+sy)*ow+sx];if(v>bv){bv=v;best=c;}}out[y*w+x]=(uint8_t)best;}return 0;}catch(const std::exception&x){err(e,en,x.what());return 1;}}
extern "C" int sf_semantic_matte_run(const char*path,const uint8_t*r,int w,int h,uint8_t*out,char*e,int en){try{int oh=0,ow=0,ch=0;auto o=run(path,SF_SEMANTIC_MODNET,r,w,h,oh,ow,ch);if(ch!=1)throw std::runtime_error("MODNet output must have one channel");float*d=o[0].GetTensorMutableData<float>();for(int y=0;y<h;y++)for(int x=0;x<w;x++){int sy=std::clamp(int((y+.5f)*oh/h),0,oh-1),sx=std::clamp(int((x+.5f)*ow/w),0,ow-1);out[y*w+x]=(uint8_t)std::lround(std::clamp(d[sy*ow+sx],0.f,1.f)*255.f);}return 0;}catch(const std::exception&x){err(e,en,x.what());return 1;}}
