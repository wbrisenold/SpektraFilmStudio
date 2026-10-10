#!/usr/bin/env python3
"""Generate a COLOR-MANAGEMENT TEST LUT, not a film simulation.

This .cube encodes the signed-log Rec.2020 shaper contract and converts
unshaped linear Rec.2020 values to encoded sRGB. It is only for validating
the importer and GPU color-space conversions. The real spectral LUT must be
baked by the physical generator on the identical inverse-shaper grid.
"""
import argparse, json, math, pathlib

def decode_signed_log(u):
    if u < 0.2:
        return -(2 ** (((0.2-u)/0.2)*math.log2(17)) - 1)/8
    return (2 ** (((u-0.2)/0.8)*math.log2(513)) - 1)/8

def encode_signed_log(x):
    if x < 0:
        return .2 * (1 - math.log2(1+min(-x,2)*8)/math.log2(17))
    return .2 + .8*math.log2(1+min(x,64)*8)/math.log2(513)

def to_srgb(x):
    if x <= 0: return 0.0
    if x <= 0.0031308: return 12.92*x
    return 1.055*pow(x,1/2.4)-0.055

def linear2020_to_srgb(rgb):
    r,g,b=rgb
    return tuple(to_srgb(x) for x in (
        1.660227*r-0.587547*g-0.072839*b,
       -0.124554*r+1.132926*g-0.008349*b,
       -0.018155*r-0.100603*g+1.118998*b))

def main():
    p=argparse.ArgumentParser()
    p.add_argument('output',type=pathlib.Path)
    p.add_argument('--size',type=int,default=17,choices=[17,33,65])
    args=p.parse_args()
    args.output.parent.mkdir(parents=True,exist_ok=True)
    with args.output.open('w',encoding='utf-8') as f:
        f.write('# TEST REFERENCE ONLY: NOT A SPEKTRAFILM PHYSICAL FILM LUT\n')
        f.write(f'TITLE "Rec2020 Signed Log Shaper Test"\nLUT_3D_SIZE {args.size}\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n')
        for b in range(args.size):
            for g in range(args.size):
                for r in range(args.size):
                    rgb=tuple(decode_signed_log(i/(args.size-1)) for i in (r,g,b))
                    out=linear2020_to_srgb(rgb)
                    f.write(' '.join(f'{v:.9f}' for v in out)+'\n')
    meta={'version':1,'input':'linear-rec2020','output':'srgb',
          'shaper':'signed-log2-v1','role':'full-film-print'}
    pathlib.Path(str(args.output)+'.lut.json').write_text(json.dumps(meta,indent=2)+'\n')
    print(args.output)
    print('This is a color-management test, NOT a generated film look.')

if __name__=='__main__': main()
