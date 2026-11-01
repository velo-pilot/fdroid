#!/usr/bin/env python3
"""Fetch the newest releases of the VeloPilot Android app from GitHub.

    fetch-releases.py list <dir>       write <dir>/releases.json
    fetch-releases.py download <dir>   write <dir>/releases.json and download each
                                       release's APK to <dir>/apks/<tag>.apk

Picks the KEEP_RELEASES newest published releases of the channel that have an APK
asset, oldest first. The channel is in the tag (build-container/ci/version.sh in
velo-pilot/android): releases vX.Y.Z, betas vX.Y.Z-beta.N and dev builds
vX.Y.Z-dev.RUN; betas and dev builds are pre-releases. Drafts are skipped. Each release needs exactly one
.apk asset; its notes become the version's changelog in F-Droid. Without any, it
writes an empty list: there is nothing to publish yet.

Environment:
  CHANNEL         release (default), beta or dev
  ANDROID_REPO    owner/name of the app repository (default velo-pilot/android)
  GITHUB_TOKEN    token that can read its releases (fine-grained: Contents read);
                  not needed once the repository is public
  KEEP_RELEASES   number of releases to publish (default 3)
"""

import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

REPO = os.environ.get("ANDROID_REPO", "velo-pilot/android")
TOKEN = os.environ.get("GITHUB_TOKEN")
KEEP = int(os.environ.get("KEEP_RELEASES", "3"))
CHANNEL = os.environ.get("CHANNEL", "release")
# Tag and whether it is a pre-release, per channel
CHANNELS = {
    "release": (r"v\d+\.\d+\.\d+", False),
    "beta": (r"v\d+\.\d+\.\d+-beta\.\d+", True),
    "dev": (r"v\d+\.\d+\.\d+-dev\.\d+", True),
}
if CHANNEL not in CHANNELS:
    sys.exit(f"CHANNEL is {CHANNEL!r}, expected release, beta or dev")
TAG, PRERELEASE = CHANNELS[CHANNEL]


def get(url, accept="application/vnd.github+json"):
    req = urllib.request.Request(url, headers={"Accept": accept, "X-GitHub-Api-Version": "2022-11-28"})
    if TOKEN:
        # Unredirected, so the token isn't sent on to the storage host that serves the asset
        req.add_unredirected_header("Authorization", f"Bearer {TOKEN}")
    try:
        return urllib.request.urlopen(req, timeout=600)
    except urllib.error.HTTPError as e:
        hint = " (private repository: is GITHUB_TOKEN set and allowed to read it?)" if e.code == 404 else ""
        sys.exit(f"GET {url}: HTTP {e.code}{hint}")


def list_releases():
    releases, page = [], 1
    while len(releases) < KEEP:
        with get(f"https://api.github.com/repos/{REPO}/releases?per_page=100&page={page}") as resp:
            batch = json.load(resp)
        if not batch:
            break
        for release in batch:
            if release["draft"] or release["prerelease"] != PRERELEASE or not re.fullmatch(TAG, release["tag_name"]):
                continue
            apks = [a for a in release["assets"] if a["name"].endswith(".apk")]
            if not apks:
                print(f"skipping {release['tag_name']}: no APK asset", file=sys.stderr)
                continue
            if len(apks) > 1:
                sys.exit(f"{release['tag_name']} has {len(apks)} APK assets, expected one")
            apk = apks[0]
            releases.append({
                "tag": release["tag_name"],
                "published_at": release["published_at"],
                "notes": (release["body"] or "").strip(),
                "apk": {
                    "id": apk["id"],
                    "name": apk["name"],
                    "size": apk["size"],
                    # sha256:<hex>, on assets uploaded since mid 2025
                    "digest": apk.get("digest") or "",
                    "updated_at": apk["updated_at"],
                },
            })
        page += 1
    releases.sort(key=lambda r: r["published_at"])
    return releases[-KEEP:]


def download(release, target):
    apk = release["apk"]
    url = f"https://api.github.com/repos/{REPO}/releases/assets/{apk['id']}"
    digest = hashlib.sha256()
    target.parent.mkdir(parents=True, exist_ok=True)
    with get(url, accept="application/octet-stream") as resp, open(target, "wb") as f:
        for block in iter(lambda: resp.read(1 << 20), b""):
            digest.update(block)
            f.write(block)
    if target.stat().st_size != apk["size"]:
        sys.exit(f"{apk['name']}: got {target.stat().st_size} bytes, expected {apk['size']}")
    if apk["digest"] and apk["digest"] != f"sha256:{digest.hexdigest()}":
        sys.exit(f"{apk['name']}: SHA-256 doesn't match the release's digest")


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("list", "download"):
        sys.exit(__doc__)
    out = Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)

    releases = list_releases()
    if not releases:
        print(f"{REPO} has no published {CHANNEL} release with an APK yet")
    (out / "releases.json").write_text(json.dumps(releases, indent=2) + "\n")
    for release in releases:
        print(f"{release['tag']}: {release['apk']['name']} ({release['apk']['size'] // 1_000_000} MB)")

    if sys.argv[1] == "download":
        for release in releases:
            download(release, out / "apks" / f"{release['tag']}.apk")
            print(f"downloaded {release['tag']}")


if __name__ == "__main__":
    main()
