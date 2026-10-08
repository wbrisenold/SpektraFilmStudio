import hashlib
import io
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import transfer
import bulk_zip_migrate

HOSTS = transfer.DEFAULT_ALLOWED

class FakeResponse:
    def __init__(self, data):
        self.data = io.BytesIO(data)
        self.headers = {"Content-Length": str(len(data))}
        self.status = 200
    def __enter__(self): return self
    def __exit__(self, *args): pass
    def read(self, n): return self.data.read(n)

class CaptureIO(io.BytesIO):
    def close(self):
        self.captured = self.getvalue()
        super().close()

class FakeRclone:
    def __init__(self, *args, **kwargs):
        self.argv=args[0]
        self.stdin=CaptureIO()
        self.stderr=io.BytesIO()
        self.stdout=io.BytesIO()
    def poll(self): return 0
    def wait(self, timeout=None):return 0

class TransferTests(unittest.TestCase):
    def test_host_restrictions(self):
        for url in ["http://lr.adobe.io/a","https://127.0.0.1/a","https://lr.adobe.io.evil.com/x","file:///etc/passwd","https://user:pass@lr.adobe.io/x"]:
            with self.assertRaises(transfer.TransferError, msg=url): transfer.check_url(url,HOSTS)
        transfer.check_url("https://lr.adobe.io/v2/test",HOSTS)
        with self.assertRaises(transfer.TransferError):transfer.check_url("https://trusted.download.example/file",HOSTS)
        transfer.check_url("https://trusted.download.example/file",HOSTS+("trusted.download.example",))

    def test_path_restrictions(self):
        for x in ["../secrets.txt","./x.ARW","a//b.ARW","/etc/x","a\\b","a/../x","a/","x\nfoo"]:
            with self.assertRaises(transfer.TransferError):transfer.safe_relpath(x)
        self.assertEqual(transfer.safe_relpath("Wedding/IMG_001.ARW"),"Wedding/IMG_001.ARW")

    def test_manifest_no_duplicate(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/"manifest.json"
            obj={"items":[{"id":"1","url":"https://lr.adobe.io/original","path":"Wedding/a.ARW","size":1024}]}
            p.write_text(json.dumps(obj))
            self.assertEqual(len(transfer.parse_manifest(p,HOSTS)),1)
            obj["items"].append(obj["items"][0])
            p.write_text(json.dumps(obj))
            with self.assertRaises(transfer.TransferError):transfer.parse_manifest(p,HOSTS)

    def test_upload_has_same_masking_policy_as_skip(self):
        data=b"RAWTEST"*67
        item={"id":"photo-1","path":"photos/img.arw","url":"https://lr.adobe.io/original","size":len(data),"sha256":hashlib.sha256(data).hexdigest()}
        calls=[]
        def fake_popen(cmd, **kwargs):
            obj=FakeRclone(cmd,**kwargs)
            calls.append(obj)
            return obj
        with sqlite3.connect(":memory:") as db:
            transfer.ensure_tables(db)
            with patch.object(transfer,"stat_remote",side_effect=[None,{"Size":len(data)}]), \
                 patch.object(transfer,"remote_sha256",return_value=hashlib.sha256(data).hexdigest()), \
                 patch.object(transfer,"open_original",return_value=FakeResponse(data)), \
                 patch.object(transfer.subprocess,"Popen",side_effect=fake_popen):
                actual=transfer.transfer_one(item,"icloud:Originals",HOSTS,db)
            self.assertEqual(actual,"uploaded")
            self.assertEqual(len(calls),1)
            self.assertIn("--size",calls[0].argv)
            self.assertEqual(calls[0].stdin.captured,data)
            self.assertEqual(db.execute("SELECT bytes FROM progress").fetchone()[0],len(data))

    def test_refuses_to_overwrite_existing(self):
        item={"id":"photo-1","path":"photos/img.arw","url":"https://lr.adobe.io/original","size":100,"sha256":None}
        with sqlite3.connect(":memory:") as db:
            transfer.ensure_tables(db)
            with patch.object(transfer,"stat_remote",return_value={"Size":99}):
                with self.assertRaises(transfer.TransferError):transfer.transfer_one(item,"icloud:Originals",HOSTS,db)

    def test_equal_size_is_not_integrity(self):
        with patch.object(transfer, "remote_sha256", return_value="b"*64):
            self.assertFalse(transfer.is_known_good({"Size":100},100,"a"*64,"icloud:x"))
            self.assertFalse(transfer.is_known_good({"Size":100},100))
            self.assertTrue(transfer.is_known_good({"Size":100},100,"b"*64,"icloud:x"))

    def test_failed_upload_cannot_be_resumed_by_size(self):
        item={"id":"photo-1","path":"a.arw","url":"https://lr.adobe.io/x","size":100,"sha256":"a"*64}
        with sqlite3.connect(":memory:") as db:
            transfer.ensure_tables(db)
            with patch.object(transfer,"stat_remote",return_value={"Size":100}), \
                 patch.object(transfer,"remote_sha256",return_value="b"*64):
                with self.assertRaises(transfer.TransferError):
                    transfer.transfer_one(item,"icloud:Originals",HOSTS,db)
            self.assertEqual(db.execute("SELECT count(*) FROM progress").fetchone()[0],0)

    def test_archive_manifest(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/"archives.json"
            p.write_text(json.dumps({"archives":[{"id":"00001","url":"https://example.adobe.com/download","size":4096}]}))
            self.assertEqual(len(bulk_zip_migrate.parse_archives(p,HOSTS)),1)

if __name__=="__main__": unittest.main()
