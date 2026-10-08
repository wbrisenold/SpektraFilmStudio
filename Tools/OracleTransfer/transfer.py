#!/usr/bin/env python3
"""Resumable streaming HTTPS originals -> an rclone remote (Oracle VM -> iCloud Drive).

No third-party Python dependencies. Signed links and OAuth tokens must be supplied by
an authorized Adobe source. This program does NOT invent a Lightroom download endpoint.
"""
from __future__ import annotations
import argparse
import hashlib
import io
import ipaddress
import json
import os
from pathlib import Path, PurePosixPath
import re
import sqlite3
import subprocess
import sys
import time
from urllib.parse import urlsplit
from urllib.request import HTTPSHandler, HTTPRedirectHandler, Request, build_opener

DEFAULT_ALLOWED = ("adobe.com", "adobe.io", "adobe.net")
CHUNK = 1024 * 1024

class TransferError(Exception):
    pass

def host_is_allowed(host: str, approved: tuple[str, ...]) -> bool:
    host = host.lower().strip(".")
    if not host or host in ("localhost", "localhost.localdomain"):
        return False
    try:
        if ipaddress.ip_address(host):
            return False
    except ValueError:
        pass
    return any(host == suffix or host.endswith("." + suffix) for suffix in approved)

def check_url(url: str, approved: tuple[str, ...]):
    u = urlsplit(url)
    if (u.scheme != "https" or not u.hostname or u.username or u.password or
            not host_is_allowed(u.hostname, approved) or u.port not in (None, 443)):
        raise TransferError("The original's download URL is not an approved HTTPS host")

class RestrictedRedirects(HTTPRedirectHandler):
    def __init__(self, approved):
        self.approved = approved
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        check_url(newurl, self.approved)
        next_req = super().redirect_request(req, fp, code, msg, headers, newurl)
        if next_req is not None:
            orig = urlsplit(req.full_url).hostname
            new = urlsplit(newurl).hostname
            if orig != new:
                # No Adobe OAuth token may leak to a different CDN origin.
                next_req.remove_header("Authorization")
        return next_req

def safe_relpath(raw: str) -> str:
    if not isinstance(raw, str) or not raw or raw.startswith("/") or "\\" in raw:
        raise TransferError("Invalid destination path")
    parts = PurePosixPath(raw).parts
    if any(p in (".", "..", "") for p in raw.split("/")) or any(ord(c) < 32 for c in raw):
        raise TransferError("Invalid destination path")
    if len(raw) > 800 or not parts or raw.endswith("/"):
        raise TransferError("Invalid destination path")
    return "/".join(parts)

def parse_manifest(filename: Path, hosts: tuple[str, ...]):
    raw = json.loads(filename.read_text(encoding="utf-8"))
    if not isinstance(raw, dict) or not isinstance(raw.get("items"), list):
        raise TransferError("Manifest requires an items array")
    found_ids = set(); found_paths = set(); items = []
    for i, item in enumerate(raw["items"]):
        if not isinstance(item, dict):
            raise TransferError(f"Item {i} must be an object")
        ident = item.get("id")
        if not isinstance(ident, str) or not re.fullmatch(r"[A-Za-z0-9._-]{1,160}", ident):
            raise TransferError(f"Invalid ID at item {i}")
        name = safe_relpath(item.get("path", ""))
        url = item.get("url", "")
        check_url(url, hosts)
        size = item.get("size")
        if size is not None and (isinstance(size, bool) or not isinstance(size, int) or size <= 0):
            raise TransferError(f"Invalid size for {ident}")
        digest = item.get("sha256")
        if digest is not None and (not isinstance(digest, str) or not re.fullmatch(r"[a-fA-F0-9]{64}", digest)):
            raise TransferError(f"Invalid sha256 for {ident}")
        if ident in found_ids or name in found_paths:
            raise TransferError("Duplicate asset ID or destination in manifest")
        found_ids.add(ident); found_paths.add(name)
        items.append({"id": ident, "path": name, "url": url, "size": size,
                      "sha256": digest.lower() if digest else None})
    if not items:
        raise TransferError("Manifest has no items")
    return items

def remote_path(remote: str, name: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9_-]+:[^\n\r]*", remote):
        raise TransferError("Remote must look like icloud:SpektraFilm-Library/Originals")
    if ".." in remote.split(":",1)[1].split("/"):
        raise TransferError("Invalid remote prefix")
    return remote.rstrip("/") + "/" + name

def run_cmd(args, **kwargs):
    return subprocess.run(args, capture_output=True, text=True, **kwargs)

def stat_remote(destination: str):
    command = run_cmd(["rclone", "lsjson", "--stat", destination], timeout=45)
    if command.returncode != 0:
        # Do not interpret permission/auth/network failures as "file absent": rcat
        # overwrites remote files. Only a specific missing-object error is safe.
        error = (command.stderr or "").lower()
        missing = ("not found", "doesn't exist", "does not exist", "404", "directory not found", "file not found")
        if any(term in error for term in missing):
            return None
        raise TransferError("Cannot verify whether remote target exists; check rclone connectivity/authentication")
    try:
        output = json.loads(command.stdout)
    except json.JSONDecodeError as exc:
        raise TransferError("Unparseable rclone remote metadata") from exc
    return output if isinstance(output, dict) and not output.get("IsDir") else None

def is_known_good(remote_item, expected_size):
    return remote_item is not None and expected_size is not None and remote_item.get("Size") == expected_size

def open_original(url: str, hosts: tuple[str,...]):
    check_url(url, hosts)
    token = os.environ.get("ADOBE_ACCESS_TOKEN", "").strip()
    # Only send OAuth tokens directly to the Adobe API host; never to third-party signed URLs.
    req = Request(url, headers={"User-Agent": "SpektraFilmOracleTransfer/0.1"})
    host = urlsplit(url).hostname or ""
    if token and (host == "lr.adobe.io" or host.endswith(".lr.adobe.io")):
        req.add_header("Authorization", "Bearer " + token)
    opener = build_opener(HTTPSHandler(), RestrictedRedirects(hosts))
    try:
        return opener.open(req, timeout=120)
    except Exception as exc:
        # urllib exceptions may contain signed URLs. Never print them to logs.
        raise TransferError("Unable to retrieve authorized Adobe original; check expiring links and entitlement") from exc

def ensure_tables(db):
    db.execute("CREATE TABLE IF NOT EXISTS progress (asset_id TEXT PRIMARY KEY, path TEXT NOT NULL, bytes INTEGER, sha256 TEXT, completed_at INTEGER)")
    db.commit()

def note_success(db, item, size, digest):
    db.execute("INSERT OR REPLACE INTO progress VALUES (?, ?, ?, ?, ?)",
               (item["id"], item["path"], size, digest, int(time.time())))
    db.commit()

def transfer_one(item, destination, hosts, db, dry_run=False):
    where = remote_path(destination, item["path"])
    known = stat_remote(where)
    if is_known_good(known, item["size"]):
        note_success(db, item, item["size"], item["sha256"])
        return "exists"
    if known is not None:
        raise TransferError(f"Refusing to overwrite existing remote object for {item['id']} (size mismatch or unverified)")
    if dry_run:
        return "planned"
    digest = hashlib.sha256()
    length = 0
    with open_original(item["url"], hosts) as source:
        header_size = source.headers.get("Content-Length")
        if header_size and header_size.isdecimal():
            actual_length = int(header_size)
            if item["size"] is not None and actual_length != item["size"]:
                raise TransferError(f"HTTP Content-Length mismatch for {item['id']}")
        else:
            actual_length = item["size"]
        if source.status != 200:
            raise TransferError(f"HTTP status {source.status} for {item['id']}")
        cmd = ["rclone", "rcat", where, "--retries", "1", "--low-level-retries", "1"]
        if actual_length is not None:
            cmd.extend(["--size", str(actual_length)])
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            while True:
                chunk = source.read(CHUNK)
                if not chunk: break
                digest.update(chunk); length += len(chunk)
                assert proc.stdin is not None
                proc.stdin.write(chunk)
            proc.stdin.close()
            # The command is local; no signed source URL or credentials appear in arguments.
            err = proc.stderr.read(3000) if proc.stderr is not None else b""
            rc = proc.wait(timeout=300)
            if rc != 0:
                raise TransferError(f"rclone upload failed for {item['id']} (exit {rc}); see server logs")
        except Exception:
            try:
                if proc.stdin and not proc.stdin.closed: proc.stdin.close()
            except BrokenPipeError:
                pass
            if proc.poll() is None:
                proc.kill(); proc.wait(timeout=10)
            raise
    sha = digest.hexdigest()
    if (item["size"] is not None and length != item["size"]) or (header_size and header_size.isdecimal() and length != int(header_size)):
        raise TransferError(f"Transferred byte count differs from manifest for {item['id']}")
    if item["sha256"] is not None and item["sha256"] != sha:
        raise TransferError(f"Source SHA-256 mismatch for {item['id']}")
    verified = stat_remote(where)
    if not verified or verified.get("Size") != length:
        raise TransferError(f"iCloud remote size verification failed for {item['id']}")
    note_success(db, item, length, sha)
    return "uploaded"

def main(argv=None):
    ap = argparse.ArgumentParser(description="Direct Oracle HTTPS original -> iCloud Drive transfer (via rclone)")
    ap.add_argument("action", choices=("validate", "pilot", "migrate"))
    ap.add_argument("--manifest", required=True, type=Path)
    ap.add_argument("--remote", default="icloud:SpektraFilm-Library/Originals")
    ap.add_argument("--state", type=Path, default=Path.home()/".local/state/spektrafilm/transfers.sqlite")
    ap.add_argument("--allowed-host", action="append", default=[], help="additional reviewed CDN domain suffix")
    ap.add_argument("--retries", type=int, default=2)
    ap.add_argument("--max-files", type=int, default=0)
    args = ap.parse_args(argv)
    extras = tuple(x.lower().lstrip(".") for x in args.allowed_host)
    if any(len(x.split(".")) < 2 or "*" in x or ":" in x for x in extras):
        raise TransferError("--allowed-host must be a reviewed multi-label domain suffix")
    hosts = tuple(DEFAULT_ALLOWED) + extras
    items = parse_manifest(args.manifest, hosts)
    if args.action == "validate":
        print(f"Manifest valid: {len(items)} originals. URLs and tokens not printed.")
        return 0
    remote_path(args.remote, items[0]["path"])
    if args.action == "pilot":
        items = items[:min(len(items), args.max_files or 3)]
    elif args.max_files > 0:
        items = items[:args.max_files]
    args.state.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(args.state.parent, 0o700)
    with sqlite3.connect(args.state) as db:
        ensure_tables(db)
        for index, item in enumerate(items, 1):
            for attempt in range(max(1, args.retries + 1)):
                try:
                    result = transfer_one(item, args.remote, hosts, db)
                    print(f"[{index}/{len(items)}] {item['id']}: {result}", flush=True)
                    break
                except Exception as exc:
                    print(f"[{index}/{len(items)}] {item['id']}: {type(exc).__name__}: {exc}", file=sys.stderr, flush=True)
                    if attempt >= args.retries:
                        print("Stopped at first unverified transfer. No next asset started.", file=sys.stderr)
                        return 1
                    time.sleep(min(30, 2 ** attempt))
    print("Finished requested items; remote size checks passed. Verify pilot in iCloud Drive before a bulk run.")
    return 0

if __name__ == "__main__":
    try: sys.exit(main())
    except (TransferError, OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"Transfer setup error: {type(exc).__name__}: {exc}", file=sys.stderr)
        sys.exit(2)
