// Local GPU resampling and exact stage-copy helpers. GPL-3.0.
#pragma once
static const char *kSpatialMetalSource = R"MSL(
#include <metal_stdlib>
using namespace metal;
kernel void spatial_down(device const float4* src [[buffer(0)]], device float4* dst [[buffer(1)]], constant uint2& dims [[buffer(2)]], uint2 p [[thread_position_in_grid]]) {
 uint2 small=(dims+1)/2;if(any(p>=small))return;
 uint2 a=p*2,b=min(a+1,dims-1);
 dst[p.y*small.x+p.x]=(src[a.y*dims.x+a.x]+src[a.y*dims.x+b.x]+src[b.y*dims.x+a.x]+src[b.y*dims.x+b.x])*.25f;
}
kernel void spatial_up(device const float4* src [[buffer(0)]], device float4* dst [[buffer(1)]], device const float4* original [[buffer(2)]], constant uint2& dims [[buffer(3)]], constant uint& accumulate [[buffer(4)]], uint2 p [[thread_position_in_grid]]) {
 if(any(p>=dims))return;uint2 small=(dims+1)/2;
 float2 uv=clamp((float2(p)+.5f)*.5f-.5f,float2(0),float2(small-1));uint2 a=uint2(floor(uv)),b=min(a+1,small-1);float2 f=fract(uv);
 float3 v=mix(mix(src[a.y*small.x+a.x].rgb,src[a.y*small.x+b.x].rgb,f.x),mix(src[b.y*small.x+a.x].rgb,src[b.y*small.x+b.x].rgb,f.x),f.y);
 uint i=p.y*dims.x+p.x;dst[i]=float4(v+(accumulate?dst[i].rgb:float3(0)),original[i].a);
}
kernel void spatial_copy(device const float4* src [[buffer(0)]], device float4* dst [[buffer(1)]], constant uint2& dims [[buffer(2)]], uint2 p [[thread_position_in_grid]]) {
 if(all(p<dims)){uint i=p.y*dims.x+p.x;dst[i]=src[i];}
}
)MSL";
