#!/usr/bin/env python3
"""Dependency-free CIEDE2000 parity evaluator for two matched linear Rec.2020 RGB CSVs.

Native reference/candidate data MUST be exported from the SAME scene-linear stage,
resolution, pixel order, native settings and deterministic grain seed. Never mix
transfer-encoded Rec.2020 or an sRGB curve with this metric input.
"""
import argparse
import csv
import json
import math
from pathlib import Path
import statistics
import struct
import zlib

# ITU-R BT.2020 RGB (D65), relative linear-light to XYZ (D65).
M = ((.6369580483,.1446169036,.1688809752),
     (.2627002120,.6779980715,.0593017165),
     (.0000000000,.0280726930,1.0609850577))
D65=(.95047,1.0,1.08883)

def rec2020_linear_to_lab(rgb):
    xyz=[sum(a*b for a,b in zip(row,rgb))/w for row,w in zip(M,D65)]
    d=6/29
    f=lambda t: math.cbrt(t) if t>d**3 else t/(3*d*d)+4/29
    x,y,z=map(f,xyz)
    return 116*y-16,500*(x-y),200*(y-z)

def ciede2000(lab1,lab2):
    l1,a1,b1=lab1;l2,a2,b2=lab2
    c1=math.hypot(a1,b1);c2=math.hypot(a2,b2);cm=(c1+c2)/2
    g=.5*(1-math.sqrt(cm**7/(cm**7+25**7)))
    aa1=(1+g)*a1;aa2=(1+g)*a2
    cp1=math.hypot(aa1,b1);cp2=math.hypot(aa2,b2)
    def hue(a,b):return math.degrees(math.atan2(b,a))%360
    h1=hue(aa1,b1) if cp1>1e-15 else 0.
    h2=hue(aa2,b2) if cp2>1e-15 else 0.
    dl=l2-l1;dc=cp2-cp1
    if cp1*cp2<=1e-15:dh=0.
    else:
        dh=h2-h1
        if dh>180:dh-=360
        if dh< -180:dh+=360
    dH=2*math.sqrt(cp1*cp2)*math.sin(math.radians(dh/2))
    meanL=(l1+l2)/2;meanC=(cp1+cp2)/2
    if cp1*cp2<=1e-15:meanh=h1+h2
    elif abs(h1-h2)>180:
        meanh=(h1+h2+360)/2 if h1+h2<360 else (h1+h2-360)/2
    else:meanh=(h1+h2)/2
    t=1-.17*math.cos(math.radians(meanh-30))+.24*math.cos(math.radians(2*meanh))+.32*math.cos(math.radians(3*meanh+6))-.20*math.cos(math.radians(4*meanh-63))
    dt=30*math.exp(-((meanh-275)/25)**2)
    rc=2*math.sqrt(meanC**7/(meanC**7+25**7))
    sl=1+.015*(meanL-50)**2/math.sqrt(20+(meanL-50)**2)
    sc=1+.045*meanC;sh=1+.015*meanC*t
    rt=-math.sin(math.radians(2*dt))*rc
    x=dl/sl;y=dc/sc;z=dH/sh
    return math.sqrt(max(0,x*x+y*y+z*z+rt*y*z))

def load(path):
    with path.open(newline='',encoding='utf-8-sig') as f:
        r=csv.DictReader(f)
        if not {'r','g','b'}.issubset(r.fieldnames or []): raise ValueError(f'{path}: require r,g,b column headers')
        out=[]
        for i,row in enumerate(r,2):
            try:pix=tuple(float(row[c]) for c in ('r','g','b'))
            except (ValueError,TypeError) as e:raise ValueError(f'{path}:{i}: {e}')
            if not all(math.isfinite(z) for z in pix):raise ValueError(f'{path}:{i}: nonfinite pixel')
            out.append(pix)
        if not out: raise ValueError(f'{path}: empty pixel set')
        return out

def quantile(s,p):
    x=(len(s)-1)*p;i=int(x);f=x-i
    return s[i]*(1-f)+s[min(len(s)-1,i+1)]*f

def png_heatmap(values,width,path):
    # PNG, no pillow dependency. Scale to p99=4 deltaE unless explicit greater.
    height=len(values)//width
    denom=max(2.,quantile(sorted(values),.99))
    data=bytearray()
    for j in range(height):
        data.append(0)
        for i in range(width):
            v=max(0,min(1,values[j*width+i]/denom))
            data.extend((round(255*v),round(255*(1-v)),0))
    def chunk(tag,payload):return struct.pack('>I',len(payload))+tag+payload+struct.pack('>I',zlib.crc32(tag+payload)&0xffffffff)
    png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>2I5B',width,height,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(bytes(data),9))+chunk(b'IEND',b'')
    path.write_bytes(png)

def compare(reference,candidate,outdir,width=None,p95_gate=.5,p99_gate=1.,max_gate=2.):
    if len(reference)!=len(candidate):raise ValueError('Pixel counts differ: '+str((len(reference),len(candidate))))
    if width is not None and (width<1 or len(reference)%width):raise ValueError('Width must divide pixel count')
    errors=[];groups={'shadows':[],'midtones':[],'highlights':[]}
    rows=[]
    for i,(ref,cand) in enumerate(zip(reference,candidate)):
        lab1=rec2020_linear_to_lab(ref)
        lab2=rec2020_linear_to_lab(cand)
        e=ciede2000(lab1,lab2)
        errors.append(e);rows.append((i,e,*[abs(ref[j]-cand[j]) for j in range(3)]))
        group='shadows' if lab1[0]<10 else ('highlights' if lab1[0]>90 else 'midtones')
        groups[group].append(e)
    sorted_errors=sorted(errors)
    metric=lambda arr:{'count':len(arr),'mean':statistics.fmean(arr),'median':quantile(sorted(arr),.5),'p95':quantile(sorted(arr),.95),'p99':quantile(sorted(arr),.99),'max':max(arr)} if arr else {'count':0}
    summary=metric(errors)
    gate={'p95':p95_gate,'p99':p99_gate,'max':max_gate}
    passed=all(summary[k]<=v for k,v in gate.items())
    result={'schema':'SFS_REC2020_LINEAR_DELTA_E_V1','input':'linear-rec2020-unclamped-D65',
            'reference_and_candidate_generated':False,'native_reference_verified':False,
            'summary':summary,'by_luminance':{k:metric(v) for k,v in groups.items()},
            'thresholds':gate,'passes_thresholds_for_supplied_samples':passed,
            'note':'This evaluator cannot prove the supplied files came from the exact pinned native GPU or correct stage.'}
    outdir.mkdir(parents=True,exist_ok=True)
    (outdir/'report.json').write_text(json.dumps(result,indent=2)+'\n')
    with (outdir/'pixel_errors.csv').open('w',newline='') as f:
        w=csv.writer(f);w.writerow(('index','deltaE2000','absR','absG','absB'));w.writerows(rows)
    if width:png_heatmap(errors,width,outdir/'deltaE_heatmap.png')
    return result

if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('reference_csv',type=Path);ap.add_argument('lut_csv',type=Path)
    ap.add_argument('--outdir',type=Path,required=True)
    ap.add_argument('--width',type=int,help='Image width, for PNG heatmap in raster order')
    ap.add_argument('--fail-on-gate',action='store_true')
    opts=ap.parse_args()
    try:result=compare(load(opts.reference_csv),load(opts.lut_csv),opts.outdir,opts.width)
    except (ValueError,OSError) as e:ap.error(str(e))
    print(json.dumps(result['summary'],indent=2),'passes:',result['passes_thresholds_for_supplied_samples'])
    if opts.fail_on_gate and not result['passes_thresholds_for_supplied_samples']:raise SystemExit(1)
