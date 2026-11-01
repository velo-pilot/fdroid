#!/usr/bin/env bash
# Replaces a GitHub token in infra/secrets.enc.yaml with a new fine-grained token.
# GitHub has no API to create tokens, so this opens the "new token" page with
# everything pre-filled except the repository, then stores what you paste.
#
# Usage: infra/new-github-token.sh infra      github_token: OpenTofu, on velo-pilot/fdroid
#        infra/new-github-token.sh releases   android_releases_token: the publish job, reads
#                                             the releases of velo-pilot/android
set -euo pipefail
cd "$(dirname "$0")"

owner=velo-pilot
secrets=secrets.enc.yaml

case "${1:-}" in
  infra)
    key=github_token repo=fdroid
    name=velopilot-fdroid-infra description="OpenTofu+in+${owner}%2Ffdroid%2Finfra"
    permissions="actions=read&administration=write&environments=write&secrets=write&actions_variables=write"
    explain="Actions: read; Administration, Environments, Secrets, Variables: read and write"
    ;;
  releases)
    key=android_releases_token repo=android
    name=velopilot-fdroid-releases description="F-Droid+publish+job+in+${owner}%2Ffdroid"
    permissions="contents=read"
    explain="Contents: read"
    ;;
  *)
    sed -n '2,/^set -e/p' "$0" | sed '$d; s/^# \{0,1\}//'
    exit 1
    ;;
esac

url="https://github.com/settings/personal-access-tokens/new"
url+="?name=$name-$(date +%Y-%m)"
url+="&description=$description"
url+="&target_name=$owner&expires_in=366"
url+="&$permissions"

cat <<EOF
On the page that opens (or open it yourself):
  $url

1. Under "Repository access", pick "Only select repositories" -> $repo
2. Check the permissions: $explain
3. Generate the token and copy it

EOF
xdg-open "$url" >/dev/null 2>&1 || true

read -rsp "Paste the new token: " token
echo
[[ $token =~ ^github_pat_[A-Za-z0-9_]+$ ]] || { echo "that doesn't look like a fine-grained token (github_pat_...)" >&2; exit 1; }

# The header goes through stdin so the token doesn't show up in process listings.
status=$(printf 'Authorization: Bearer %s\n' "$token" |
  curl -s -o /dev/null -w '%{http_code}' -H @- "https://api.github.com/repos/$owner/$repo")
[ "$status" = 200 ] || { echo "the token can't read $owner/$repo (HTTP $status); is the repository selected?" >&2; exit 1; }

if [ -f "$secrets" ]; then
  # Decrypting needs your PGP key, so gpg-agent may ask for its passphrase.
  printf '"%s"' "$token" | sops set --value-stdin "$secrets" "[\"$key\"]"
else
  printf '%s: %s\n' "$key" "$token" |
    sops --encrypt --filename-override "infra/$secrets" --input-type yaml --output-type yaml /dev/stdin >"$secrets"
fi
echo "stored $key in infra/$secrets; revoke the old token at https://github.com/settings/personal-access-tokens"
if [ "$key" = android_releases_token ]; then
  echo "run tofu -chdir=infra apply to hand it to the publish job"
fi
