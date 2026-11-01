#!/usr/bin/env python3
"""Mirror a local directory to a folder of a Bunny Storage zone and purge the pull zone cache.

Only files whose SHA-256 differs from the copy in storage are uploaded. Uploads go in
an order that keeps the F-Droid repository consistent for clients reading it mid-sync:
APKs, icons and other files first, then the index files, then entry.jar/entry.json
(which point at the index), then inputs.sha256. Remote files that no longer exist
locally are deleted after all uploads finish.

Environment:
  BUNNY_STORAGE_ZONE      storage zone name (required)
  BUNNY_STORAGE_PASSWORD  storage zone password, from FTP & API Access (required)
  BUNNY_STORAGE_HOST      region endpoint, default storage.bunnycdn.com (Falkenstein); a URL
                          like http://localhost:8080 also works, for tests
  BUNNY_API_KEY           account API key, only needed to purge the cache
  BUNNY_PULLZONE_ID       pull zone id, only needed to purge the cache

Usage: bunny-sync.py [--dry-run] <directory> <remote folder>
"""

import hashlib
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from itertools import groupby
from pathlib import Path

WORKERS = 4


def env(name, default=None, required=False):
    value = os.environ.get(name, default)
    if required and not value:
        sys.exit(f"error: {name} is not set")
    return value


ZONE = env("BUNNY_STORAGE_ZONE", required=True)
PASSWORD = env("BUNNY_STORAGE_PASSWORD", required=True)
HOST = env("BUNNY_STORAGE_HOST", "storage.bunnycdn.com")
API_KEY = env("BUNNY_API_KEY")
PULLZONE_ID = env("BUNNY_PULLZONE_ID")


def storage_url(path):
    base = HOST if "://" in HOST else f"https://{HOST}"
    return f"{base}/{urllib.parse.quote(ZONE)}/{urllib.parse.quote(path)}"


def request(method, url, data=None, headers=None, key=PASSWORD, retries=3):
    for attempt in range(retries):
        body = data() if callable(data) else data
        req = urllib.request.Request(url, data=body, method=method, headers={"AccessKey": key, **(headers or {})})
        try:
            with urllib.request.urlopen(req, timeout=600) as resp:
                return resp.read()
        except urllib.error.HTTPError as e:
            if e.code == 404 and method == "GET":
                return None
            if e.code < 500 or attempt == retries - 1:
                raise RuntimeError(f"{method} {url}: HTTP {e.code} {e.read()[:200]!r}") from None
        except urllib.error.URLError as e:
            if attempt == retries - 1:
                raise RuntimeError(f"{method} {url}: {e.reason}") from None
        finally:
            if hasattr(body, "close"):
                body.close()


def list_remote(prefix):
    """Return {path: sha256} for every file under prefix (which ends with /)."""
    files = {}
    listing = request("GET", storage_url(prefix), headers={"Accept": "application/json"})
    for entry in json.loads(listing or "[]"):
        path = prefix + entry["ObjectName"]
        if entry["IsDirectory"]:
            files.update(list_remote(path + "/"))
        else:
            files[path] = (entry.get("Checksum") or "").upper()
    return files


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest().upper()


def upload_order(path):
    name = path.rsplit("/", 1)[-1]
    if name == "inputs.sha256":
        return 3
    if name.startswith("entry."):
        return 2
    if name.startswith("index") and path.split("/")[-2] == "repo":
        return 1
    return 0


def main():
    args = sys.argv[1:]
    dry_run = "--dry-run" in args
    args = [a for a in args if a != "--dry-run"]
    if len(args) != 2 or not Path(args[0]).is_dir():
        sys.exit(__doc__)
    root, prefix = Path(args[0]), args[1].strip("/") + "/"

    local = {f"{prefix}{p.relative_to(root).as_posix()}": p for p in sorted(root.rglob("*")) if p.is_file()}
    checksums = {path: sha256(file) for path, file in local.items()}
    remote = list_remote(prefix)

    to_upload = sorted((p for p in local if remote.get(p) != checksums[p]), key=lambda p: (upload_order(p), p))
    to_delete = sorted(p for p in remote if p not in local)
    print(f"{len(local)} local files, {len(remote)} remote files")
    print(f"upload {len(to_upload)}, delete {len(to_delete)}")
    if dry_run:
        for p in to_upload:
            print(f"  + {p}")
        for p in to_delete:
            print(f"  - {p}")
        return

    def upload(path):
        request("PUT", storage_url(path), data=lambda: open(local[path], "rb"), headers={
            "Checksum": checksums[path],
            "Content-Type": "application/octet-stream",
            "Content-Length": str(local[path].stat().st_size),
        })
        return path

    def delete(path):
        request("DELETE", storage_url(path))
        return path

    with ThreadPoolExecutor(WORKERS) as pool:
        # One group at a time, so nothing of a later group lands before an earlier one
        for _, group in groupby(to_upload, key=upload_order):
            for path in pool.map(upload, list(group)):
                print(f"  + {path}")
        for path in pool.map(delete, to_delete):
            print(f"  - {path}")

    if not to_upload and not to_delete:
        print("storage zone is up to date")
    elif API_KEY and PULLZONE_ID:
        request("POST", f"https://api.bunny.net/pullzone/{PULLZONE_ID}/purgeCache", data=b"", key=API_KEY)
        print(f"purged cache of pull zone {PULLZONE_ID}")
    else:
        print("BUNNY_API_KEY/BUNNY_PULLZONE_ID not set, skipping cache purge")


if __name__ == "__main__":
    main()
