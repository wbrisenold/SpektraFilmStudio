#!/usr/bin/env python3
from pathlib import Path
import sys
ROOT=Path(__file__).resolve().parents[1]
errors=[]
def req(v,m):
    if not v: errors.append(m)
def txt(p):
    f=ROOT/p; req(f.is_file(),f'missing {p}'); return f.read_text(errors='replace') if f.is_file() else ''
app=txt('Sources/SpektraFilmFast/AppModel.swift')
lens=txt('Sources/SpektraFilmFast/LensCharacterEngine.swift')
raw=txt('Sources/SpektraFilmFast/RawForgeDenoise.swift')
support=txt('Sources/SpektraFilmFast/Stage5ProductionSupport.swift')
sem=txt('Sources/SpektraFilmFast/SemanticMaskEngine.swift')
qa=txt('scripts/qa_production.py')
build=txt('scripts/build_app.sh')
req('lens_character_kernel' in lens and 'dispatchThreads' in lens and 'MTLSize(width: 16, height: 16' in lens,'tiled Metal lens kernel missing')
req('applyCPU' in lens,'CPU fallback must remain for safe degradation')
req(app.count('LensCharacterEngine.apply') >= 2,'preview/export must both apply LensCharacterEngine')
req('prewarm(_ images:' in raw and 'maxConcurrent: Int = 2' in raw,'bounded RawForge batch prewarm missing')
req('cacheHits' in raw and 'elapsed' in raw,'RawForge warm/cold timing instrumentation missing')
req('prewarmRawDenoiseForLibrarySelection' in support and 'prewarmRawDenoiseForExportSet' in support,'batch prewarm entry points missing')
req('refreshStage5CacheAccounting' in support and 'AI models' in support,'separate RawForge/AI cache accounting missing')
req('func invalidate(imageURL:' in sem,'semantic cache invalidation missing')
req('semanticMasks = nil' in app and 'semanticMaskEngine.invalidate' in app,'lens/denoise changes must invalidate canonical semantic masks')
req('PRODUCTION STATIC QA PASS' in qa,'base production QA missing')
req('--arch x86_64' in build and '--arch arm64' not in build,'Intel-only build contract changed')
req((ROOT/'STAGE_5_PRODUCTION_HARDENING.md').is_file(),'Stage 5 handoff doc missing')
if errors:
    for e in errors: print('FAIL:',e)
    sys.exit(1)
print('STAGE 5 STATIC REGRESSION PASS')
print('Lens: tiled Metal + CPU fallback')
print('RawForge: bounded prewarm + cache timing')
print('Caches: RawForge / AI models / semantic RAM / render separated')
print('Note: final x86_64 app compile + Metal execution still requires macOS/Xcode.')
