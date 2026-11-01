#!/usr/bin/env python3
"""Build and sign an F-Droid repository from the releases that fetch-releases.py downloaded.

    build-repo.py <dir>

Reads <dir>/releases.json and <dir>/apks/, runs fdroid update in <dir>/fdroid and
lays out what goes to the CDN in <dir>/publish/<folder>/. The release repository
(folder fdroid) holds be.velopilot.app with icon.png, the dev repository (folder
fdroid-dev) the dev builds be.velopilot.dev with icon-dev.png, under the description
in metadata/be.velopilot.app.yml with DEV_METADATA on top. In <folder>:

  repo/                  the F-Droid repository: APKs, icons, signed index
  velopilot-latest.apk   a copy of the newest APK, for a stable download link
  inputs.sha256          INPUTS_HASH, if set, so the next run can tell nothing changed

The keystore is deleted again when the build ends. Needs fdroidserver (Debian
package) and keytool.

Environment:
  CHANNEL                   release (default) or dev
  FDROID_KEYSTORE_BASE64    base64 of the PKCS12 keystore that signs the index
  FDROID_KEYSTORE_PASSWORD  its store and key password
  CDN_URL                   public URL of the pull zone (default https://cdn.velopilot.be)
  INPUTS_HASH               optional, see above
"""

import base64
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import yaml
from fdroidserver import common

ROOT = Path(__file__).resolve().parent.parent
CDN_URL = os.environ.get("CDN_URL", "https://cdn.velopilot.be").rstrip("/")
METADATA = ROOT / "metadata" / "be.velopilot.app.yml"
CHANNELS = {
    # folder on the CDN, repository name, key alias (see infra/repo-key.sh), app id, icon
    "release": ("fdroid", "VeloPilot", "velopilot", "be.velopilot.app", "icon.png"),
    "dev": ("fdroid-dev", "VeloPilot dev builds", "velopilot-dev", "be.velopilot.dev", "icon-dev.png"),
}
DEV_METADATA = {
    "AutoName": "VeloPilot Dev",
    "Summary": "Development builds of VeloPilot, for testing",
    "Description": "Development builds of VeloPilot, to try what comes next. They install next to the "
                   "VeloPilot app, with their own settings, and may break.\n\n",
}
# F-Droid shows up to 500 characters of release notes
CHANGELOG_LIMIT = 500


def env(name):
    value = os.environ.get(name)
    if not value:
        sys.exit(f"{name} is not set")
    return value


def write_private(path, data):
    path.write_bytes(b"")
    path.chmod(0o600)
    path.write_bytes(data)


def build(work, fdroid, folder, repo_name, key_alias, app_id, icon):
    releases = json.loads((work / "releases.json").read_text())
    if not releases:
        sys.exit("releases.json lists no release, so there is nothing to publish")
    repo_url = f"{CDN_URL}/{folder}/repo"
    write_private(fdroid / "keystore.p12", base64.b64decode(env("FDROID_KEYSTORE_BASE64")))
    env("FDROID_KEYSTORE_PASSWORD")
    write_private(fdroid / "config.yml", f"""\
repo_url: {repo_url}
repo_name: {repo_name}
repo_description: >-
  OsmAnd for speed pedelecs, e-bikes and regular bikes, from velopilot.be.
archive_older: 0
keystore: keystore.p12
repo_keyalias: {key_alias}
keystorepass: {{env: FDROID_KEYSTORE_PASSWORD}}
keypass: {{env: FDROID_KEYSTORE_PASSWORD}}
""".encode())

    # fdroid update takes the repository icon from its working folder and the app icon from
    # the metadata: R8 shortens the resource paths in release APKs, so it can't find the icon there.
    shutil.copy(ROOT / icon, fdroid / "icon.png")
    app_dir = fdroid / "metadata" / app_id / "en-US"
    (app_dir / "changelogs").mkdir(parents=True)
    shutil.copy(ROOT / icon, app_dir / "icon.png")

    metadata = yaml.safe_load(METADATA.read_text())
    if folder == CHANNELS["dev"][0]:
        description = DEV_METADATA["Description"] + metadata["Description"]
        metadata.update(DEV_METADATA, Description=description)
    # A build entry per APK: the index only carries a version's release notes when the version
    # has one. Never mark an entry "disable": fdroid update deletes the APK of a disabled build.
    metadata["Builds"] = []
    versions = []
    for release in releases:
        apk = work / "apks" / f"{release['tag']}.apk"
        apk_id, code, name = common.get_apk_id(str(apk))
        code = int(code)
        if apk_id != app_id:
            sys.exit(f"{release['tag']}: the APK is {apk_id}, not {app_id}")
        if any(code == c for c, _ in versions):
            sys.exit(f"{release['tag']}: versionCode {code} is already in another release")
        if release["tag"].lstrip("v") != name:
            print(f"warning: {release['tag']} contains versionName {name}", file=sys.stderr)
        print(f"{release['tag']}: {name} (versionCode {code})")
        shutil.copy(apk, fdroid / "repo" / f"{app_id}_{code}.apk")
        metadata["Builds"].append({"versionName": name, "versionCode": code, "commit": release["tag"]})
        notes = release["notes"] or f"VeloPilot {name}"
        (app_dir / "changelogs" / f"{code}.txt").write_text(notes[:CHANGELOG_LIMIT].rstrip() + "\n")
        versions.append((code, name))
    current_code, current_name = max(versions)
    metadata.update(CurrentVersion=current_name, CurrentVersionCode=current_code)
    (fdroid / "metadata" / f"{app_id}.yml").write_text(yaml.safe_dump(metadata, sort_keys=False, allow_unicode=True))

    subprocess.run(["fdroid", "update"], cwd=fdroid, check=True)

    publish = work / "publish" / folder
    shutil.rmtree(work / "publish", ignore_errors=True)
    publish.mkdir(parents=True)
    shutil.move(fdroid / "repo", publish / "repo")
    shutil.copy(publish / "repo" / f"{app_id}_{current_code}.apk", publish / "velopilot-latest.apk")
    if os.environ.get("INPUTS_HASH"):
        (publish / "inputs.sha256").write_text(os.environ["INPUTS_HASH"] + "\n")

    cert = subprocess.run(
        ["keytool", "-exportcert", "-keystore", "keystore.p12", "-alias", key_alias,
         "-storepass:env", "FDROID_KEYSTORE_PASSWORD"],
        cwd=fdroid, check=True, capture_output=True).stdout
    fingerprint = hashlib.sha256(cert).hexdigest().upper()
    print(f"Built {current_name}. Repository: {repo_url}?fingerprint={fingerprint}")


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    channel = os.environ.get("CHANNEL", "release")
    if channel not in CHANNELS:
        sys.exit(f"CHANNEL is {channel!r}, expected release or dev")
    work = Path(sys.argv[1]).resolve()
    fdroid = work / "fdroid"
    shutil.rmtree(fdroid, ignore_errors=True)
    (fdroid / "repo").mkdir(parents=True)
    try:
        build(work, fdroid, *CHANNELS[channel])
    finally:
        (fdroid / "keystore.p12").unlink(missing_ok=True)


if __name__ == "__main__":
    main()
