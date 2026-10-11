#!/usr/bin/env python3
"""Compare paired *encoded sRGB* native/fast samples with CIEDE2000.

Input CSV: ref_r,ref_g,ref_b,fast_r,fast_g,fast_b, plus optional id.
Both triples must be sRGB-encoded numbers, normally in [0,1]. Negative / extended
values are accepted and processed without clipping; pairs MUST be pixel-aligned.
This is a measurement reader, NOT a native-renderer or GPU stage comparison.
"""
import argparse
import csv
import json
import math
import statistics
from pathlib import Path


def srgb_to_linear(x):
    return x / 12.92 if x <= 0.04045 else ((x+0.055)/1.055)**2.4


def encoded_srgb_to_lab(v):
    r,g,b=[srgb_to_linear(c) for c in v]
    x=(0.4124564*r + 0.3575761*g + 0.1804375*b)/0.95047
    y=0.2126729*r + 0.7151522*g + 0.0721750*b
    z=(0.0193339*r + 0.1191920*g + 0.9503041*b)/1.08883
    def f(t):return t**(1/3) if t>216/24389 else (24389/27*t+16)/116
    X,Y,Z=map(f,(x,y,z))
    return 116*Y-16,500*(X-Y),200*(Y-Z)


def ciede2000(lab1,lab2):
    L1,a1,b1=lab1;L2,a2,b2=lab2
    C1=math.hypot(a1,b1);C2=math.hypot(a2,b2)
    Cbar=(C1+C2)/2
    G=0.5*(1-math.sqrt(Cbar**7/(Cbar**7+25**7)))
    a1p=(1+G)*a1;a2p=(1+G)*a2
    C1p=math.hypot(a1p,b1);C2p=math.hypot(a2p,b2)
    h1=math.degrees(math.atan2(b1,a1p))%360
    h2=math.degrees(math.atan2(b2,a2p))%360
    dLp=L2-L1;dCp=C2p-C1p
    if C1p*C2p==0:dh=0
    elif abs(h2-h1)<=180:dh=h2-h1
    elif h2<=h1:dh=h2-h1+360
    else:dh=h2-h1-360
    dHp=2*math.sqrt(C1p*C2p)*math.sin(math.radians(dh/2))
    Lbar=(L1+L2)/2;Cbarp=(C1p+C2p)/2
    if C1p*C2p==0:hbar=h1+h2
    elif abs(h1-h2)<=180:hbar=(h1+h2)/2
    elif h1+h2<360:hbar=(h1+h2+360)/2
    else:hbar=(h1+h2-360)/2
    T=(1-0.17*math.cos(math.radians(hbar-30))
       +0.24*math.cos(math.radians(2*hbar))
       +0.32*math.cos(math.radians(3*hbar+6))
       -0.20*math.cos(math.radians(4*hbar-63)))
    dtheta=30*math.exp(-((hbar-275)/25)**2)
    RC=2*math.sqrt(Cbarp**7/(Cbarp**7+25**7))
    SL=1+0.015*(Lbar-50)**2/math.sqrt(20+(Lbar-50)**2)
    SC=1+0.045*Cbarp;SH=1+0.015*Cbarp*T
    RT=-math.sin(math.radians(2*dtheta))*RC
    al=dLp/SL;ac=dCp/SC;ah=dHp/SH
    return math.sqrt(max(0,al*al+ac*ac+ah*ah+RT*ac*ah))


def percentile(xs,p):
    if not xs:return None
    s=sorted(xs);ix=(len(s)-1)*p;lo=int(ix);hi=min(len(s)-1,lo+1)
    return s[lo]+(s[hi]-s[lo])*(ix-lo)


def summarize(xs):
    return {'count':len(xs),'mean':statistics.fmean(xs) if xs else None,
            'median':percentile(xs,.5),'p95':percentile(xs,.95),
            'p99':percentile(xs,.99),'max':max(xs) if xs else None}


def compare(path):
    items=[];shadows=[];neutrals=[]
    with path.open(newline='',encoding='utf-8-sig') as f:
        reader=csv.DictReader(f)
        if reader.fieldnames is None:raise ValueError('Missing header')
        required=('ref_r','ref_g','ref_b','fast_r','fast_g','fast_b')
        missing=set(required)-set(reader.fieldnames)
        if missing:raise ValueError('Missing columns: '+','.join(sorted(missing)))
        for i,row in enumerate(reader):
            a=tuple(float(row[f'ref_{c}']) for c in 'rgb')
            b=tuple(float(row[f'fast_{c}']) for c in 'rgb')
            if not all(math.isfinite(x) for x in a+b):raise ValueError(f'Non-finite sample on row {i+2}')
            ref=encoded_srgb_to_lab(a);fast=encoded_srgb_to_lab(b)
            de=ciede2000(ref,fast)
            detail={'id':row.get('id',str(i)), 'deltaE00':de, 'L_ref':ref[0],
                    'max_code_error_8bit':max(abs(x-y) for x,y in zip(a,b))*255}
            items.append(detail)
            if ref[0]<10:shadows.append(de)
            if math.hypot(ref[1],ref[2])<.2:neutrals.append(math.hypot(fast[1]-ref[1],fast[2]-ref[2]))
    if not items:raise ValueError('No samples; this is NOT a passed fidelity test')
    overall=summarize([x['deltaE00'] for x in items]);shadow=summarize(shadows)
    neutral=max(neutrals) if neutrals else None
    threshold_checks={'p95_under_0_5':overall['p95']<=.5,
                      'p99_under_1':overall['p99']<=1.,
                      'max_under_2':overall['max']<=2.,
                      'shadows_p95_under_1':shadow['p95'] is None or shadow['p95']<=1.,
                      'neutral_chroma_error_under_0_3':neutral is None or neutral<=.3}
    return {'schema':'SFS_PHOTO_SRGB_DELTAE00_V1',
            'status':'PASS_SAMPLE_THRESHOLDS' if all(threshold_checks.values()) else 'FAIL_SAMPLE_THRESHOLDS',
            'input':'two paired, pixel-aligned, encoded-sRGB sample triples; native vs accelerated renderer',
            'native_gpu_proven':False, 'sharma_reference_pairs_tested':6,
            'NOTE':'Not a native render or stage split; threshold success alone does not validate pipeline or 34-pair requirement.',
            'overall':overall,'shadows':shadow,'max_neutral_chroma_difference':neutral,
            'checks':threshold_checks, 'worst_samples':sorted(items,key=lambda x:x['deltaE00'],reverse=True)[:20]}


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('paired_csv',type=Path)
    ap.add_argument('--json',type=Path,required=True)
    opts=ap.parse_args()
    try:result=compare(opts.paired_csv)
    except (ValueError,OSError) as e:ap.error(str(e))
    opts.json.parent.mkdir(parents=True,exist_ok=True)
    opts.json.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({'status':result['status'],'samples':result['overall']['count'],
        'p95':result['overall']['p95'],'p99':result['overall']['p99'],'max':result['overall']['max']},indent=2))
    raise SystemExit(0 if result['status']=='PASS_SAMPLE_THRESHOLDS' else 2)
if __name__=='__main__':main()
