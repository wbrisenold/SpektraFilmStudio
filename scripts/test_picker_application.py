#!/usr/bin/env python3
"""Mixed-state and preservation regression tests for the repair applicator."""
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('repair', Path(__file__).with_name('apply_picker_repair.py'))
repair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repair)


class RepairTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)/'repo'
        self.bundle = Path(self.temp.name)/'bundle'
        self.repo.mkdir(); self.bundle.mkdir()
        self.base = b'alpha\nold picker\nomega\n' + b'context\n'*12
        self.target = self.base.replace(b'old picker', b'new picker')
        for f in ['a.swift', 'b.swift']: (self.repo/f).write_bytes(self.base)
        def git(*args): return subprocess.check_output(['git', '-C', str(self.repo), *args], stderr=subprocess.DEVNULL)
        git('init'); git('add', '.')
        git('-c','user.name=Test','-c','user.email=test@example.invalid','commit','-m','base')
        commit = git('rev-parse', 'HEAD').decode().strip()
        files = {}
        for f in ['a.swift', 'b.swift']:
            records = []
            for name, value in [('base',self.base), ('target',self.target)]:
                p = f'{name}-{f}'; (self.bundle/p).write_bytes(value)
                records.append({'path':p, 'sha256':hashlib.sha256(value).hexdigest()})
            files[f] = {'bases':[records[0]], 'target':records[1]}
        (self.bundle/'repair.json').write_text(json.dumps({'base_commit':commit, 'files':files}))

    def test_mixed_idempotent_and_unrelated(self):
        (self.repo/'a.swift').write_bytes(self.target)
        (self.repo/'b.swift').write_bytes(self.base+b'local addition\n')
        (self.repo/'notes.txt').write_text('keep me')
        index = (self.repo/'.git/index').read_bytes()
        repair.apply(self.repo, self.bundle, check=True)
        self.assertEqual((self.repo/'b.swift').read_bytes(),self.base+b'local addition\n')
        repair.apply(self.repo,self.bundle)
        self.assertEqual((self.repo/'b.swift').read_bytes(),self.target+b'local addition\n')
        self.assertEqual((self.repo/'notes.txt').read_text(),'keep me')
        self.assertEqual((self.repo/'.git/index').read_bytes(),index)
        self.assertEqual(repair.apply(self.repo,self.bundle),0)

    def test_nearest_reviewed_state_and_repeat_addition(self):
        intermediate = self.base.replace(b'alpha', b'alpha intermediate')
        current = intermediate + b'unrelated note\n'
        merged = repair.merge(current, [self.base, intermediate], self.target)
        self.assertEqual(merged, self.target + b'unrelated note\n')
        self.assertEqual(repair.merge(merged, [self.base, intermediate], self.target), merged)

    def test_conflict_is_all_or_nothing(self):
        (self.repo/'b.swift').write_bytes(self.base.replace(b'old picker',b'users different picker'))
        with self.assertRaises(repair.Conflict): repair.apply(self.repo,self.bundle)
        self.assertEqual((self.repo/'a.swift').read_bytes(),self.base)
        self.assertFalse((self.repo/'SOURCE_MANIFEST.sha256').exists())

    def test_corrupt_payload_is_rejected(self):
        (self.bundle/'target-b.swift').write_text('corrupt')
        with self.assertRaises(repair.Conflict): repair.apply(self.repo,self.bundle)
        self.assertEqual((self.repo/'a.swift').read_bytes(),self.base)

    def mark_deletion(self):
        spec = json.loads((self.bundle/'repair.json').read_text())
        spec['files']['b.swift']['target'] = None
        (self.bundle/'repair.json').write_text(json.dumps(spec))

    def test_reviewed_deletion_is_backed_up_and_idempotent(self):
        self.mark_deletion()
        repair.apply(self.repo, self.bundle, check=True)
        self.assertTrue((self.repo/'b.swift').exists())
        repair.apply(self.repo, self.bundle)
        self.assertFalse((self.repo/'b.swift').exists())
        backups = list(self.repo.parent.glob('SpektraPicker-backup-*/b.swift'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), self.base)
        self.assertNotIn('b.swift', (self.repo/'SOURCE_MANIFEST.sha256').read_text())
        self.assertEqual(repair.apply(self.repo, self.bundle), 0)

    def test_deletion_conflict_preserves_every_file(self):
        self.mark_deletion()
        (self.repo/'b.swift').write_bytes(self.base+b'user note\n')
        with self.assertRaises(repair.Conflict): repair.apply(self.repo, self.bundle)
        self.assertEqual((self.repo/'a.swift').read_bytes(), self.base)
        self.assertEqual((self.repo/'b.swift').read_bytes(), self.base+b'user note\n')

    def test_symlink_is_rejected(self):
        (self.repo/'b.swift').unlink()
        (self.repo/'b.swift').symlink_to(self.bundle/'base-b.swift')
        with self.assertRaises(repair.Conflict): repair.apply(self.repo,self.bundle)
        self.assertEqual((self.repo/'a.swift').read_bytes(),self.base)

if __name__ == '__main__': unittest.main()
