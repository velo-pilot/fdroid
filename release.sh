#!/usr/bin/env bash
# Publishes the release repository on https://cdn.velopilot.be/fdroid/repo from this checkout:
# fetches the newest full releases of velo-pilot/android, takes the release key out of Bitwarden,
# builds and signs the repository in a container (Containerfile) and uploads it to the release
# storage zone, then purges the CDN cache. The key is only on disk, in build/release/fdroid,
# while the repository is signed.
#
# Usage: ./release.sh [--dry-run]
#
# --dry-run builds and signs the repository but only lists what the upload would change.
#
# Needs podman, rbw, python3, sops (with your PGP key, for infra/secrets.enc.yaml) and tofu
# (with infra/terraform.tfstate, for the release storage zone's password).
set -euo pipefail
cd "$(dirname "$0")"

BW_ENTRY=${BW_ENTRY:-VeloPilot F-Droid release key}
export CHANNEL=release ANDROID_REPO=velo-pilot/android KEEP_RELEASES=${KEEP_RELEASES:-3}
export CDN_URL=https://cdn.velopilot.be
work=build/release
image=localhost/velopilot-fdroid
dry_run=()
[ "${1:-}" = --dry-run ] && dry_run=(--dry-run)

label=""
if command -v selinuxenabled >/dev/null && selinuxenabled; then
	label=":z"
fi

echo ">> Reading the GitHub token and the upload credentials"
GITHUB_TOKEN=$(sops decrypt --extract '["android_releases_token"]' infra/secrets.enc.yaml)
BUNNY_API_KEY=$(sops decrypt --extract '["bunny_api_key"]' infra/secrets.enc.yaml)
export GITHUB_TOKEN BUNNY_API_KEY
# BUNNY_STORAGE_ZONE, BUNNY_STORAGE_HOST, BUNNY_STORAGE_PASSWORD, BUNNY_PULLZONE_ID
while IFS='=' read -r -d '' key value; do
	export "$key=$value"
done < <(tofu -chdir=infra output -json release_upload |
	python3 -c 'import json, sys; [print(f"{k}={v}", end="\0") for k, v in json.load(sys.stdin).items()]')

echo ">> Fetching the releases of $ANDROID_REPO"
rm -rf "$work"
python3 -I scripts/fetch-releases.py download "$work"
if [ "$(python3 -c 'import json, sys; print(len(json.load(open(sys.argv[1]))))' "$work/releases.json")" = 0 ]; then
	echo "Nothing to publish" >&2
	exit 1
fi

echo ">> Preparing the fdroidserver container"
podman build --quiet -t "$image" - < Containerfile > /dev/null

echo ">> Taking the release key out of Bitwarden (\"$BW_ENTRY\")"
key=$(rbw get --raw "$BW_ENTRY" |
	python3 -c 'import json, sys; e = json.load(sys.stdin); print(e["data"]["password"]); print(e["notes"].strip())')
FDROID_KEYSTORE_PASSWORD=$(head -1 <<< "$key")
FDROID_KEYSTORE_BASE64=$(sed -n 2p <<< "$key")
unset key
export FDROID_KEYSTORE_PASSWORD FDROID_KEYSTORE_BASE64

echo ">> Building and signing the repository"
# The key goes in through the environment, not the command line
podman run --rm -v "$PWD:/src:ro$label" -v "$PWD/$work:/work$label" \
	-e CHANNEL -e CDN_URL -e FDROID_KEYSTORE_PASSWORD -e FDROID_KEYSTORE_BASE64 \
	"$image" python3 /src/scripts/build-repo.py /work
unset FDROID_KEYSTORE_PASSWORD FDROID_KEYSTORE_BASE64

echo ">> Uploading to the release storage zone"
python3 -I scripts/bunny-sync.py "${dry_run[@]}" "$work/publish/fdroid" fdroid
