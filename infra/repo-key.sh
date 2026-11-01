#!/usr/bin/env bash
# The keys that sign the F-Droid repository indexes:
#
# - dev: signs the dev repository in the GitHub Actions job. It lives in
#   infra/secrets.enc.yaml (fdroid_dev_keystore_base64, fdroid_dev_keystore_password);
#   OpenTofu hands it to the job.
# - release: signs the release repository. It lives only in Bitwarden, in the entry
#   "$BW_ENTRY" (password: keystore password, notes: base64 of the keystore), and
#   release.sh takes it out for a release.
#
# Usage: infra/repo-key.sh new dev|release           create a key, once; never replaces one
#        infra/repo-key.sh fingerprint dev|release   print the fingerprint and the link to add the repository
#
# Users trust a repository by its key's fingerprint: if the key changes, they have to
# remove the repository and add it again, so back up the Bitwarden vault. Bitwarden
# goes through rbw; keytool runs in a container (podman), so no JDK is needed.
set -euo pipefail
cd "$(dirname "$0")"

BW_ENTRY=${BW_ENTRY:-VeloPilot F-Droid release key}
secrets=secrets.enc.yaml
cdn=https://cdn.velopilot.be
image=docker.io/library/eclipse-temurin:21-jre-noble

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"

label=""
if command -v selinuxenabled >/dev/null && selinuxenabled; then
  label=":z"
fi

keytool() {
  podman run --rm -v "$work:/keys$label" -w /keys -e KEY_PASSWORD "$image" keytool "$@"
}

sops_secret() {
  sops decrypt --extract "[\"$1\"]" "$secrets" 2>/dev/null
}

# Prints the keystore password, then the base64 keystore, of channel $1; fails if there's no key
read_key() {
  case $1 in
    dev)
      sops_secret fdroid_dev_keystore_password && echo && sops_secret fdroid_dev_keystore_base64 && echo
      ;;
    release)
      rbw get --raw "$BW_ENTRY" 2>/dev/null |
        python3 -c 'import json, sys; e = json.load(sys.stdin); print(e["data"]["password"]); print(e["notes"].strip())'
      ;;
  esac
}

alias_of() {
  [ "$1" = dev ] && echo velopilot-dev || echo velopilot
}

folder_of() {
  [ "$1" = dev ] && echo fdroid-dev || echo fdroid
}

fingerprint() {
  local key
  key=$(read_key "$1") || { echo "there is no $1 key; run $0 new $1" >&2; exit 1; }
  KEY_PASSWORD=$(head -1 <<<"$key")
  export KEY_PASSWORD
  sed -n 2p <<<"$key" | base64 -d >"$work/keystore.p12"
  local fp
  fp=$(keytool -exportcert -keystore keystore.p12 -alias "$(alias_of "$1")" -storepass:env KEY_PASSWORD |
    sha256sum | cut -d' ' -f1 | tr a-f A-F)
  echo "Fingerprint of the $1 repository: $fp"
  echo "Add to F-Droid: $cdn/$(folder_of "$1")/repo?fingerprint=$fp"
}

new_key() {
  if [ "$1" = dev ] && [ ! -f "$secrets" ]; then
    echo "create infra/$secrets first (see README.md)" >&2
    exit 1
  fi
  if read_key "$1" >/dev/null; then
    echo "there already is a $1 key; new never replaces it" >&2
    exit 1
  fi
  KEY_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true)
  export KEY_PASSWORD
  local name="VeloPilot F-Droid repository"
  [ "$1" = dev ] && name+=" (dev)"
  keytool -genkeypair -keystore keystore.p12 -storetype PKCS12 -alias "$(alias_of "$1")" \
    -keyalg RSA -keysize 4096 -validity 10000 -dname "CN=$name" \
    -storepass:env KEY_PASSWORD -keypass:env KEY_PASSWORD
  local keystore
  keystore=$(base64 -w0 <"$work/keystore.p12")

  case $1 in
    dev)
      printf '"%s"' "$keystore" | sops set --value-stdin "$secrets" '["fdroid_dev_keystore_base64"]'
      printf '"%s"' "$KEY_PASSWORD" | sops set --value-stdin "$secrets" '["fdroid_dev_keystore_password"]'
      echo "stored the dev key in infra/$secrets; run tofu -chdir=infra apply to hand it to the publish job"
      ;;
    release)
      # rbw add opens an editor on a file whose first line becomes the password and the
      # rest the notes; this "editor" fills in that file.
      printf '%s\n%s\n' "$KEY_PASSWORD" "$keystore" >"$work/entry"
      printf '#!/bin/sh\ncat "%s" >"$1"\n' "$work/entry" >"$work/editor"
      chmod 700 "$work/editor"
      VISUAL="$work/editor" EDITOR="$work/editor" rbw add "$BW_ENTRY"
      rbw sync
      echo "stored the release key in Bitwarden as \"$BW_ENTRY\""
      ;;
  esac
  rm -f "$work/keystore.p12" "$work/entry" "$work/editor"
  # Reads the key back from where it was stored
  fingerprint "$1"
}

case "${1:-}:${2:-}" in
  new:dev | new:release) new_key "$2" ;;
  fingerprint:dev | fingerprint:release) fingerprint "$2" ;;
  *)
    sed -n '2,/^set -e/p' "$0" | sed '$d; s/^# \{0,1\}//'
    exit 1
    ;;
esac
