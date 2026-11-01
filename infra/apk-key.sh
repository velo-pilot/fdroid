#!/usr/bin/env bash
# The keys that sign the VeloPilot APKs in the workflows of velo-pilot/android:
#
# - dev: VeloPilot Dev (be.velopilot.dev)
# - release: VeloPilot Beta (be.velopilot.beta) and VeloPilot (be.velopilot.app)
#
# They live in infra/secrets.enc.yaml (apk_<key>_keystore_base64, apk_<key>_keystore_password); OpenTofu hands
# them to the "dev" and "release" environments of velo-pilot/android (infra/github.tf).
#
# Usage: infra/apk-key.sh new dev|release           create a key, once; never replaces one
#        infra/apk-key.sh fingerprint dev|release   print the SHA-256 of its certificate, which apps like
#                                                   AppVerifier compare APKs with
#
# Android only installs an update signed with the same key as the installed app: losing the release key means
# users have to uninstall VeloPilot (and its settings) to get a newer release. infra/secrets.enc.yaml is in git, so
# it is backed up with the repository. keytool comes from a local JDK or a container (podman).
set -euo pipefail
cd "$(dirname "$0")"

secrets=secrets.enc.yaml
# The alias that build-container/ci/build-apk.sh in velo-pilot/android signs with
alias=velopilot
image=docker.io/library/eclipse-temurin:21-jre-noble

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"

label=""
if command -v selinuxenabled >/dev/null && selinuxenabled; then
  label=":z"
fi

# A local JDK's keytool if there is one, else the container's
keytool() {
  if command -v keytool >/dev/null; then
    (cd "$work" && command keytool "$@")
  else
    podman run --rm -v "$work:/keys$label" -w /keys -e KEY_PASSWORD "$image" keytool "$@"
  fi
}

sops_secret() {
  sops decrypt --extract "[\"$1\"]" "$secrets" 2>/dev/null
}

fingerprint() {
  KEY_PASSWORD=$(sops_secret "apk_$1_keystore_password") || { echo "there is no $1 key; run $0 new $1" >&2; exit 1; }
  export KEY_PASSWORD
  sops_secret "apk_$1_keystore_base64" | base64 -d >"$work/keystore.p12"
  local fp
  fp=$(keytool -exportcert -keystore keystore.p12 -alias "$alias" -storepass:env KEY_PASSWORD |
    sha256sum | cut -d' ' -f1 | tr a-f A-F | sed 's/../&:/g; s/:$//')
  echo "SHA-256 of the $1 APK signing certificate: $fp"
}

new_key() {
  if sops_secret "apk_$1_keystore_base64" >/dev/null; then
    echo "there already is a $1 key; new never replaces it" >&2
    exit 1
  fi
  KEY_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true)
  export KEY_PASSWORD
  local name="VeloPilot"
  [ "$1" = dev ] && name+=" Dev"
  keytool -genkeypair -keystore keystore.p12 -storetype PKCS12 -alias "$alias" \
    -keyalg RSA -keysize 4096 -validity 10000 -dname "CN=$name" \
    -storepass:env KEY_PASSWORD -keypass:env KEY_PASSWORD
  printf '"%s"' "$(base64 -w0 <"$work/keystore.p12")" |
    sops set --value-stdin "$secrets" "[\"apk_$1_keystore_base64\"]"
  printf '"%s"' "$KEY_PASSWORD" | sops set --value-stdin "$secrets" "[\"apk_$1_keystore_password\"]"
  rm -f "$work/keystore.p12"
  echo "stored the $1 key in infra/$secrets; run tofu -chdir=infra apply to hand it to velo-pilot/android"
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
