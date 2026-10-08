#!/usr/bin/env python3
"""Adobe bulk Lightroom export ZIPs -> iCloud Drive, staged ONE archive at a time on Oracle.

Uses official Adobe export downloads only when an authorized direct ZIP URL is supplied.
The Mac never receives the archives. Archives are deleted from Oracle after success.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import time
import zipfile
from transfer import (
    CHUNK, DEFAULT_ALLOWED, TransferError, check_url, ensure_tables,
    is_known_good, note_success, open_original, remote_path, run_cmd,
    safe_relpath, stat_remote,
)


def parse_archives(manifest: Path, hosts: tuple[str,...]):
    data = json.loads(manifest.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or not isinstance(data.get("archives"), list) or not data["archives"]:
        raise TransferError("ZIP manifest requires a nonempty archives list")
    archives = []
    known = set()
    for raw in data["archives"]:
        if not isinstance(raw, dict):
            raise TransferError("Each archive must be an object")
        ident = raw.get("id")
        if not isinstance(ident, str) or not ident or len(ident)>100 or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-" for c in ident):
            raise TransferError("Archive IDs must use letters, numbers, underscore or hyphen")
        if ident in known:
            raise TransferError("Duplicate archive ID")
        known.add(ident)
        url = raw.get("url")
        check_url(url, hosts)
        size = raw.get("size")
        if size is not None and (not isinstance(size,int) or isinstance(size,bool) or size<=0):
            raise TransferError("Invalid ZIP archive byte count")
        digest = raw.get("sha256")
        if digest is not None and (not isinstance(digest,str) or len(digest)!=64 or any(c not in "0123456789abcdefABCDEF" for c in digest)):
            raise TransferError("Invalid archive SHA-256")
        archives.append({"id":ident,"url":url,"size":size,"sha256":digest.lower() if digest else None})
    return archives


def stage_archive(archive, stage: Path, hosts: tuple[str,...]):
    path = stage / (archive["id"] + ".partial.zip")
    hasher = hashlib.sha256()
    length = 0
    # A previous interrupted download is removed, never misidentified as a verified ZIP.
    path.unlink(missing_ok=True)
    with open_original(archive["url"], hosts) as incoming:
        if incoming.status != 200:
            raise TransferError("ZIP URL did not return 200 OK")
        supplied_size = incoming.headers.get("Content-Length")
        if supplied_size and supplied_size.isdecimal() and archive["size"] is not None and int(supplied_size) != archive["size"]:
            raise TransferError("ZIP manifest Content-Length mismatch")
        if supplied_size and supplied_size.isdecimal():
            available = shutil.disk_usage(stage).free
            if available < int(supplied_size) + 512*1024*1024:
                raise TransferError("Oracle stage disk has insufficient free space for this ZIP")
        try:
            with open(path,"wb") as output:
                while True:
                    block = incoming.read(CHUNK)
                    if not block:break
                    output.write(block)
                    length += len(block); hasher.update(block)
        except Exception:
            path.unlink(missing_ok=True)
            raise
    if archive["size"] is not None and length != archive["size"]:
        path.unlink(missing_ok=True)
        raise TransferError("Downloaded ZIP size mismatch")
    if archive["sha256"] is not None and hasher.hexdigest() != archive["sha256"]:
        path.unlink(missing_ok=True)
        raise TransferError("Downloaded ZIP hash mismatch")
    if not zipfile.is_zipfile(path):
        path.unlink(missing_ok=True)
        raise TransferError("Adobe bulk export URL did not return a valid ZIP")
    return path


def transfer_entry(zf, info, archive, remote, db):
    # Never extract an untrusted ZIP entry to the VM filesystem.
    relative = safe_relpath(info.filename)
    if relative.startswith("__MACOSX/") or relative.split("/")[-1] in (".DS_Store",):
        return "ignored"
    dest = remote_path(remote, relative)
    existing = stat_remote(dest)
    if is_known_good(existing, info.file_size):
        note_success(db,{"id": archive["id"]+":"+str(info.CRC)+":"+relative,"path":relative},info.file_size,"")
        return "exists"
    if existing is not None:
        raise TransferError("Refusing to overwrite a nonmatching existing iCloud Drive file: " + relative)
    command = ["rclone","rcat",dest,"--size",str(info.file_size),"--retries","1","--low-level-retries","1"]
    hasher = hashlib.sha256()
    length = 0
    with zf.open(info,"r") as original:
        proc = subprocess.Popen(command, stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
        try:
            while True:
                block=original.read(CHUNK)  # ZipExtFile validates CRC at end of stream.
                if not block:break
                hasher.update(block); length+=len(block)
                assert proc.stdin is not None
                proc.stdin.write(block)
            proc.stdin.close()
            if proc.stderr: proc.stderr.read(3000)
            rc = proc.wait(timeout=300)
            if rc:
                raise TransferError("rclone failed (exit "+str(rc)+") for "+relative)
        except Exception:
            try:
                if proc.stdin and not proc.stdin.closed:proc.stdin.close()
            except BrokenPipeError:pass
            if proc.poll() is None:
                proc.kill();proc.wait(timeout=10)
            raise
    if length != info.file_size:
        raise TransferError("Uncompressed original byte count mismatch: "+relative)
    verification = stat_remote(dest)
    if not verification or verification.get("Size") != length:
        raise TransferError("Remote size does not match extracted original: "+relative)
    note_success(db,{"id":archive["id"]+":"+str(info.CRC)+":"+relative,"path":relative},length,hasher.hexdigest())
    return "uploaded"


def main():
    parser=argparse.ArgumentParser(description="Stream Lightroom full-library export ZIPs from Oracle to iCloud Drive")
    parser.add_argument("action", choices=["validate","pilot","migrate"])
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--remote", default="icloud:SpektraFilm-Library/AdobeExport")
    parser.add_argument("--stage-dir",type=Path,default=Path.home()/"spektrafilm-zip-stage")
    parser.add_argument("--state",type=Path,default=Path.home()/".local/state/spektrafilm/zip-transfers.sqlite")
    parser.add_argument("--allowed-host",action="append",default=[])
    parser.add_argument("--max-archive-expanded-gb",type=int,default=16)
    args=parser.parse_args()
    extras=tuple(x.lower().lstrip(".") for x in args.allowed_host)
    if any(len(x.split(".")) < 2 or "*" in x or ":" in x for x in extras):
        raise TransferError("--allowed-host must be a reviewed multi-label domain suffix")
    hosts=tuple(DEFAULT_ALLOWED)+extras
    archives=parse_archives(args.manifest,hosts)
    if args.action=="validate":
        print("Validated",len(archives),"ZIP download URLs (credentials not displayed).")
        return 0
    remote_path(args.remote,"pilot.txt")
    args.stage_dir.mkdir(parents=True,exist_ok=True)
    os.chmod(args.stage_dir,0o700)
    args.state.parent.mkdir(parents=True,exist_ok=True)
    os.chmod(args.state.parent,0o700)
    selected=archives[:1] if args.action=="pilot" else archives
    with sqlite3.connect(args.state) as db:
        ensure_tables(db)
        for count,archive in enumerate(selected,1):
            print(f"[{count}/{len(selected)}] staging {archive['id']} on Oracle server",flush=True)
            path=stage_archive(archive,args.stage_dir,hosts)
            try:
                with zipfile.ZipFile(path,"r") as zf:
                    entries=[item for item in zf.infolist() if not item.is_dir()]
                    if sum(v.file_size for v in entries)>args.max_archive_expanded_gb*(1024**3):
                        raise TransferError("ZIP expanded size exceeds safety limit")
                    if args.action=="pilot":entries=entries[:3]
                    for i,info in enumerate(entries,1):
                        result=transfer_entry(zf,info,archive,args.remote,db)
                        print(f"  [{i}/{len(entries)}] {info.filename}: {result}",flush=True)
            finally:
                # Never silently retain originals on Oracle after interruption.
                path.unlink(missing_ok=True)
    print("Requested ZIP files processed. Verify iCloud Drive and Lightroom edits before deleting Adobe source.")
    return 0

if __name__=="__main__":
    try:sys.exit(main())
    except Exception as exc:
        print("ZIP migration failed:",type(exc).__name__,str(exc),file=sys.stderr)
        sys.exit(2)
