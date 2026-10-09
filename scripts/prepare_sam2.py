#!/usr/bin/env python3
"""Fetch Apple's pinned SAM 2.1 Tiny conversion; verify every byte before compiling."""
from pathlib import Path
import hashlib, json, os, subprocess, tempfile, urllib.request, argparse
ROOT = Path(__file__).resolve().parents[1]

def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''): h.update(chunk)
    return h.hexdigest()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--check-only', action='store_true')
    args = parser.parse_args()
    manifest = json.loads((ROOT / 'Resources/SAM2TinyManifest.json').read_text())
    root = ROOT / 'Resources/AIModels/SAM2Tiny'
    for item in manifest['files']:
        path = root / item['path']
        valid = path.is_file() and path.stat().st_size == item['bytes'] and digest(path) == item['sha256']
        if valid: continue
        if args.check_only: raise RuntimeError('Missing or damaged SAM 2.1 model: ' + item['path'])
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, name = tempfile.mkstemp(prefix='.download-', dir=path.parent)
        try:
            with os.fdopen(fd, 'wb') as out, urllib.request.urlopen(manifest['source'] + item['path'], timeout=120) as response:
                total = 0
                while chunk := response.read(1024 * 1024):
                    total += len(chunk)
                    if total > item['bytes']: raise RuntimeError('Oversized model download')
                    out.write(chunk)
            temporary = Path(name)
            if total != item['bytes'] or digest(temporary) != item['sha256']: raise RuntimeError('SAM model integrity check failed')
            temporary.replace(path)
        finally:
            Path(name).unlink(missing_ok=True)
    print('SAM 2.1 Tiny: all 9 pinned files verified', flush=True)
    if args.check_only: return
    output = ROOT / '.build/sam2-tiny' / manifest['revision']
    output.mkdir(parents=True, exist_ok=True)
    subprocess.run(['swift', str(ROOT / 'scripts/compile_sam2.swift'), str(root), str(output)], check=True)
    print('SAM2_COMPILED_ROOT=' + str(output))

if __name__ == '__main__': main()
