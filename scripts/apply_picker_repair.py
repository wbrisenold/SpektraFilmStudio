#!/usr/bin/env python3
"""Preflight a reviewed repair bundle; three-way merge without touching Git's index.

Usage: apply_picker_repair.py --bundle BUNDLE [--check] REPOSITORY
The bundle contains repair.json, target/ and reviewed base states under bases/.
"""
import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


class Conflict(RuntimeError):
    pass


def merge(current, bases, target):
    if current == target:
        return current
    if current in bases:
        return target
    # Reapplying over a complete target plus unrelated inserted lines is a no-op.
    # Do not treat missing or replaced target lines as already applied.
    additions = difflib.SequenceMatcher(None, target.splitlines(keepends=True), current.splitlines(keepends=True), autojunk=False)
    if target and all(tag in ('equal', 'insert') for tag, *_ in additions.get_opcodes()):
        return current
    # A reviewed intermediate state is also a valid merge ancestor. Never force
    # an overlapping edit, accept conflict markers, or replace an unknown file.
    with tempfile.TemporaryDirectory(prefix='spektra-merge-') as temp:
        paths = [Path(temp) / x for x in ('current', 'base', 'target')]
        paths[0].write_bytes(current)
        paths[2].write_bytes(target)
        candidates = set()
        # Pick the nearest reviewed ancestor before merging. Trying every ancestor
        # can produce distinct, clean merges that resurrect old implementation code.
        def distance(base):
            matcher = difflib.SequenceMatcher(None, base.splitlines(keepends=True), current.splitlines(keepends=True), autojunk=False)
            return sum((b - a) + (d - c) for tag, a, b, c, d in matcher.get_opcodes() if tag != 'equal')
        ranked = [(distance(base), base) for base in bases]
        nearest = min((score for score, _ in ranked), default=None)
        for score, base in ranked:
            if score != nearest:
                continue
            paths[1].write_bytes(base)
            result = subprocess.run(['git', 'merge-file', '-p', *map(str, paths)], capture_output=True)
            if result.returncode == 0:
                candidates.add(result.stdout)
        if len(candidates) == 1:
            return candidates.pop()
    raise Conflict('overlapping or ambiguous local changes; no files changed')


def package_files(root):
    excluded = {'.build', 'dist', '.git', 'Vendor'}
    for parent, dirs, files in os.walk(root):
        rel = Path(parent).relative_to(root)
        dirs[:] = [d for d in dirs if d not in excluded and not d.startswith('.batch-edit-backup-')
                   and not (rel.as_posix() == 'Resources' and d == 'AIModels')]
        for name in files:
            if name not in {'.DS_Store', 'SOURCE_MANIFEST.sha256'}:
                yield (rel / name).as_posix()


def load_payload(bundle, path, expected):
    data = (bundle / path).read_bytes()
    if hashlib.sha256(data).hexdigest() != expected:
        raise Conflict(f'Corrupt bundle payload: {path}')
    return data


def apply(root, bundle, check=False):
    root, bundle = root.resolve(), bundle.resolve()
    spec = json.loads((bundle / 'repair.json').read_text())
    ancestor = subprocess.run(['git', '-C', str(root), 'merge-base', '--is-ancestor', spec['base_commit'], 'HEAD'], capture_output=True)
    if ancestor.returncode:
        raise Conflict('Checkout does not descend from the reviewed base commit')
    originals, changes = {}, {}
    for relative, item in spec['files'].items():
        rel = Path(relative)
        if rel.is_absolute() or '..' in rel.parts or '.git' in rel.parts:
            raise Conflict(f'Unsafe bundle path: {relative}')
        path = root / rel
        if path.is_symlink() or root not in path.resolve().parents:
            raise Conflict(f'Symlink/outside checkout: {relative}')
        current = path.read_bytes() if path.exists() else b''
        originals[relative] = current if path.exists() else None
        bases = [load_payload(bundle, b['path'], b['sha256']) for b in item['bases']]
        if item['target'] is None:
            # Cleanup deletes only reviewed, unchanged files. Preserve unknown edits.
            if not path.exists():
                continue
            if current not in bases:
                raise Conflict(f'{relative}: local edits prevent reviewed deletion; no files changed')
            changes[relative] = None
            continue
        target = load_payload(bundle, item['target']['path'], item['target']['sha256'])
        try:
            result = merge(current, bases, target)
        except Conflict as error:
            raise Conflict(f'{relative}: {error}') from error
        if result != current:
            changes[relative] = result
    # Hash new files without reading them from disk before they exist.
    names = sorted((set(package_files(root)) | set(changes)) - {p for p, value in changes.items() if value is None})
    generated = ''.join(hashlib.sha256(changes[p] if p in changes else (root/p).read_bytes()).hexdigest()
                        + '  ' + p + '\n' for p in names).encode()
    original_manifest = (root/'SOURCE_MANIFEST.sha256').read_bytes() if (root/'SOURCE_MANIFEST.sha256').exists() else None
    if generated != original_manifest:
        originals['SOURCE_MANIFEST.sha256'] = original_manifest
        changes['SOURCE_MANIFEST.sha256'] = generated
    print(f'CHECK PASS: {len(changes)} file(s) need updating')
    if check or not changes:
        return len(changes)
    # Recheck all source inputs immediately before writing, not just changed ones.
    for rel, content in originals.items():
        path = root/rel
        if (path.read_bytes() if path.exists() else None) != content:
            raise Conflict(f'{rel}: changed during preflight; retry after the other editor finishes')
    backup = Path(tempfile.mkdtemp(prefix='SpektraPicker-backup-', dir=root.parent))
    for rel in changes:
        old = originals.get(rel)
        if old is not None:
            dest = backup/rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(root/rel, dest)
    (backup/'new-files.json').write_text(json.dumps([p for p in changes if originals.get(p) is None]))
    written = []
    try:
        for rel, data in changes.items():
            path = root/rel
            if data is None:
                path.unlink()
                written.append(rel)
                continue
            path.parent.mkdir(parents=True, exist_ok=True)
            fd, name = tempfile.mkstemp(prefix='.spektra-write-', dir=path.parent)
            try:
                with os.fdopen(fd, 'wb') as stream:
                    stream.write(data)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.chmod(name, path.stat().st_mode & 0o777 if path.exists() else 0o644)
                os.replace(name, path)
                written.append(rel)
            finally:
                if os.path.exists(name): os.unlink(name)
    except BaseException:
        for rel in reversed(written):
            if originals.get(rel) is None: (root/rel).unlink()
            else: shutil.copy2(backup/rel, root/rel)
        raise
    print(f'APPLIED: {len(changes)} files; backup: {backup}; Git index unchanged')
    return len(changes)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('repository', type=Path)
    parser.add_argument('--bundle', type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    try:
        apply(args.repository.resolve(), args.bundle.resolve(), args.check)
    except (Conflict, OSError, ValueError) as error:
        parser.exit(1, f'REPAIR STOPPED: {error}\n')


if __name__ == '__main__':
    main()
