#!/usr/bin/env python3
"""Validate ART's CLF contains the expected Matrix -> Log -> 3D LUT.
Does not silently reinterpret the ACES input domain as Rec2020 or sRGB.
"""
import argparse, json, math, pathlib, xml.etree.ElementTree as ET


def inspect(path):
    root = ET.parse(path).getroot()
    if root.tag != 'ProcessList': raise ValueError('Expected OpenColorIO CLF ProcessList')
    ops = [e.tag for e in root]
    if 'LUT3D' not in ops or 'Matrix' not in ops or 'Log' not in ops:
        raise ValueError('ART spectral CLF must preserve its color matrix, log shaper and 3D LUT')
    lut = root.find('LUT3D')
    dims = [int(x) for x in lut.find('Array').attrib['dim'].split()]
    if len(dims) != 4 or dims[-1] != 3 or dims[:3] != [33,33,33]:
        raise ValueError(f'Expected ART Spectral Film LUT 33^3 RGB table, got {dims}')
    vals = lut.find('Array').text.split()
    if len(vals) != 33**3*3: raise ValueError('LUT array length mismatch')
    for v in vals:
        if not math.isfinite(float(v)): raise ValueError('Nonfinite LUT value')
    return dict(format='CLF3', operations=ops, dimensions=dims, samples=33**3, finite=True,
                file_bytes=path.stat().st_size, mode='ART Spectral Film LUT (separate film model)',
                encoding='ART Matrix + cameraLinToLog; do NOT apply as plain linear Rec.2020 cube')


def main():
    p=argparse.ArgumentParser(); p.add_argument('path', type=pathlib.Path)
    p.add_argument('--seconds',type=int,default=None);p.add_argument('--source',default='');p.add_argument('--art',default='')
    a=p.parse_args()
    data=inspect(a.path)
    data.update(generation_seconds=a.seconds,spectral_film_lut_commit=a.source,art_commit=a.art)
    out=a.path.with_suffix('.validation.json')
    out.write_text(json.dumps(data,indent=2)+'\n')
    print(json.dumps(data,indent=2))

if __name__=='__main__': main()
