#!/usr/bin/env python3
"""Fetch the exact Redlamp optional model versions, with size/hash verification.

Developer/test helper. Normal users install models from Settings > Models.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import urllib.request


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def install(manifest, destination):
    root = destination / f"{manifest['id']}-v{manifest['version']}"
    root.mkdir(parents=True, exist_ok=True)
    for item in manifest['files']:
        relative = Path(item['path'])
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('Invalid model path')
        target = root / relative
        if target.exists() and target.stat().st_size == item['bytes'] and digest(target) == item['sha256']:
            continue
        source = manifest['source'].rstrip('/') + '/'
        source += item['path'].replace('/', '__') if 'github.com/' in source and '/releases/download/' in source else item['path']
        target.parent.mkdir(parents=True, exist_ok=True)
        print(f"Downloading {manifest['id']}: {item['path']} ({item['bytes']} bytes)", flush=True)
        with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as stream:
            temporary = Path(stream.name)
            try:
                with urllib.request.urlopen(source, timeout=90) as response:
                    shutil.copyfileobj(response, stream, 1024 * 1024)
                stream.close()
                if temporary.stat().st_size != item['bytes'] or digest(temporary) != item['sha256']:
                    raise ValueError(f"Size/hash mismatch: {item['path']}")
                temporary.replace(target)
            finally:
                temporary.unlink(missing_ok=True)
    marker = root / 'verified.json'
    marker.write_text(json.dumps(manifest, indent=2) + '\n')
    print(f"MODEL_VERIFIED {manifest['id']} {sum(x['bytes'] for x in manifest['files'])}", flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', type=Path, required=True)
    parser.add_argument('--models', nargs='+', default=['depth-anything-v2-small', 'depth-anything-3-mono-large', 'vitmatte-base', 'sam3'])
    args = parser.parse_args()
    catalog = Path(__file__).resolve().parents[1] / 'Resources' / 'MaskModels'
    for model in args.models:
        install(json.loads((catalog / f'{model}.json').read_text()), args.destination)
