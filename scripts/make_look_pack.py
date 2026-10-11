#!/usr/bin/env python3
"""Convert an EXISTING, explicitly linear-Rec.2020-output 65³ CUBE to a Look pack.
No guessing about the LUT's input and output. Does not bake native film physics.
"""
import argparse, hashlib, json, re, struct
from pathlib import Path

def convert(source: Path, destination: Path, *, name: str, category: str,
            pack_id: str, core_hash: str, film: str, paper: str):
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,96}', pack_id):
        raise ValueError('Pack id must be 1-96 letters/numbers/_/-')
    side = Path(str(source) + '.lut.json')
    if not side.is_file(): raise ValueError('Missing .cube.lut.json; refusing to guess color contract')
    contract = json.loads(side.read_text())
    if (contract.get('input') != 'linear-rec2020'
        or contract.get('output') != 'linear-rec2020'
        or contract.get('shaper') not in ('domain-linear', 'signed-log2-v1')):
        raise ValueError('Look requires linear-rec2020 input, linear-rec2020 OUTPUT, valid shaper; rerun exporter with linear output')
    if contract.get('role') != 'full-film-print':
        raise ValueError('This converter only accepts full-film-print cubes; stage intermediates are not Looks')
    n=0; domain_min=[0.,0.,0.]; domain_max=[1.,1.,1.]; count=0
    out=bytearray()
    for line_no,line in enumerate(source.read_text(encoding='utf8').splitlines(),1):
        tokens=line.split('#',1)[0].strip().split()
        if not tokens:continue
        op=tokens[0].upper()
        if op=='TITLE':continue
        if op=='LUT_3D_SIZE':
            if n or len(tokens)!=2 or int(tokens[1])!=65:raise ValueError('Look cube must be exactly 65^3')
            n=65;continue
        if op in ('DOMAIN_MIN','DOMAIN_MAX'):
            if len(tokens)!=4:raise ValueError(f'Bad domain at {line_no}')
            vals=list(map(float,tokens[1:]))
            if op=='DOMAIN_MIN':domain_min=vals
            else:domain_max=vals
            continue
        if op=='LUT_1D_SIZE':raise ValueError('Combined 1D+3D LUTs cannot be converted safely')
        if n!=65 or len(tokens)!=3:raise ValueError(f'Unexpected LUT item at {line_no}')
        xyz=list(map(float,tokens))
        if not all(__import__('math').isfinite(v) for v in xyz):raise ValueError('Nonfinite LUT sample')
        out.extend(struct.pack('<4f',*xyz,1.))
        count+=1
    if count!=65**3:raise ValueError(f'Expected {65**3} entries, got {count}')
    if contract['shaper']=='signed-log2-v1' and (domain_min != [0.,0.,0.] or domain_max != [1.,1.,1.]):
        raise ValueError('Signed log must have 0..1 encoded-domain coordinates')
    import math
    if not all(math.isfinite(x) for x in domain_min+domain_max) or not all(a<b for a,b in zip(domain_min,domain_max)):
        raise ValueError('Invalid domain')
    target=destination/pack_id
    if target.exists():raise ValueError('Refusing to overwrite existing pack')
    target.mkdir(parents=True)
    try:
        (target/'cube.bin').write_bytes(out)
        manifest={
          'version':1,'id':pack_id,'name':name,'category':category,
          'source':{'filmStock':film,'printStock':paper,'scannerProfile':None,
                    'coreHash':core_hash,'bakeSchema':int(contract.get('version',1))},
          'input':{'space':contract['input'],'shaper':contract['shaper'],
                   'domainMin':domain_min,'domainMax':domain_max},
          'output':{'space':'linear-rec2020'},
          'cube':{'file':'cube.bin','size':65,'format':'rgba32f-le',
                  'sha256':hashlib.sha256(out).hexdigest()},
          'defaults':{'strength':1.,'exposure':0.,'contrast':0.}}
        (target/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
        return target
    except BaseException:
        import shutil
        shutil.rmtree(target)
        raise

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('cube',type=Path)
    p.add_argument('output_dir',type=Path)
    p.add_argument('--id',required=True)
    p.add_argument('--name',required=True)
    p.add_argument('--category',default='Film')
    p.add_argument('--film',required=True)
    p.add_argument('--paper',required=True)
    p.add_argument('--core-hash',required=True)
    o=p.parse_args()
    print(convert(o.cube,o.output_dir,name=o.name,category=o.category,
        pack_id=o.id,core_hash=o.core_hash,film=o.film,paper=o.paper))
