# VeloPilot F-Droid repositories

F-Droid repositories for [VeloPilot](https://velopilot.be), built from the GitHub releases of
[velo-pilot/android](https://github.com/velo-pilot/android) and hosted on Bunny CDN:

| Repository | URL | Contents | App | Signed with | Published by |
| --- | --- | --- | --- | --- | --- |
| release | <https://cdn.velopilot.be/fdroid/repo> | the newest 3 releases | VeloPilot, `be.velopilot.app` | release key, in Bitwarden | `./release.sh`, locally |
| dev | <https://cdn.velopilot.be/fdroid-dev/repo> | the newest 3 pre-releases | VeloPilot Dev, `be.velopilot.dev` | dev key, in SOPS and GitHub | GitHub Actions |

The dev builds are a separate app (flavour `velopilotDev` in velo-pilot/android) with an α instead of the P
in its icon, so they install next to the release app.

Everything users download comes from cdn.velopilot.be: the APKs, icons and signed index. Each
folder also has `velopilot-latest.apk`, a copy of the newest APK for a stable download link
(`https://cdn.velopilot.be/fdroid/velopilot-latest.apk`). Users add a repository with its
fingerprint (`infra/repo-key.sh fingerprint release|dev`) to F-Droid, Droid-ify, Neo Store
or Obtainium.

The release key never leaves Bitwarden except while `./release.sh` signs a release, and the
release storage zone's password stays in the local OpenTofu state. GitHub only holds the dev key
and the dev storage zone's password, so a leak there can't change the release repository.

## Layout

| Path | What |
| --- | --- |
| `metadata/be.velopilot.app.yml` | App description, links and categories shown in F-Droid; the dev app gets `DEV_METADATA` in `scripts/build-repo.py` on top |
| `icon.png`, `icon-dev.png` | Repository and app icons of the release and dev repositories, from `branding/generate.py` in velo-pilot/android |
| `scripts/fetch-releases.py` | Lists the newest releases (or pre-releases) of velo-pilot/android and downloads their APKs |
| `scripts/build-repo.py` | Writes the metadata with each release's notes as its changelog, runs `fdroid update` to sign the index |
| `scripts/bunny-sync.py` | Uploads the repository to Bunny Storage: changed files only, APKs first, the index last, then deletes what's gone |
| `.github/workflows/publish-dev.yml` | Builds and publishes the dev repository |
| `release.sh`, `Containerfile` | Builds and publishes the release repository from a local checkout |
| `infra/` | bunny.net and GitHub setup, as OpenTofu |

## Releases in velo-pilot/android

Each GitHub release needs exactly one `.apk` asset and a higher versionCode than the
releases before it. The release notes become the F-Droid changelog (up to 500 characters).
Full releases go to the release repository and must be `be.velopilot.app` (flavour `velopilot`);
pre-releases go to the dev repository and must be `be.velopilot.dev` (flavour `velopilotDev`,
e.g. `assembleVelopilotDevOpenglArm64Release`). Drafts are skipped.

The dev repository picks up new pre-releases within 6 hours. To publish one right away, the
release workflow in velo-pilot/android can start the publish job (with a token that has
*Contents: read and write* on velo-pilot/fdroid):

```sh
curl -fsS -X POST -H "Authorization: Bearer $FDROID_DISPATCH_TOKEN" \
  https://api.github.com/repos/velo-pilot/fdroid/dispatches -d '{"event_type":"android-release"}'
```

## Publishing a release

After creating a release in velo-pilot/android:

```sh
./release.sh --dry-run   # optional: builds and signs, then lists what the upload would change
./release.sh
```

It reads the GitHub token and the Bunny API key from `infra/secrets.enc.yaml` (SOPS), the release
storage zone from `tofu -chdir=infra output release_upload`, and the release key from the
Bitwarden entry "VeloPilot F-Droid release key" through `rbw` (which asks to unlock the vault).
It builds the repository in a podman container with Debian's fdroidserver, uploads it and
purges the CDN cache. To withdraw a release, delete or mark it pre-release on GitHub and run
`./release.sh` again.

## Dev repository (GitHub Actions)

`.github/workflows/publish-dev.yml` publishes the dev repository on pushes to `main`, on an
`android-release` repository dispatch, every 6 hours and on demand (Actions > Publish dev > Run
workflow; tick *force* to publish even if nothing changed). Runs without changes stop after
comparing the pre-releases and this repository with `inputs.sha256` on the CDN. The job runs
in the GitHub `dev` environment, which only accepts `main`. It can't purge the CDN cache (that
needs the account API key); both pull zones keep `/fdroid-dev/` cached for a minute instead.

## Infrastructure (OpenTofu)

`infra/` defines everything the repositories run on, so change these settings there, not in the
bunny.net or GitHub UI (the next plan would revert UI edits):

| File | What |
| --- | --- |
| `infra/bunny.tf` | Storage zones for the release and dev repositories, the pull zone on `cdn.velopilot.be` (origin: the release zone) with an edge rule that forwards `/fdroid-dev/` to the dev zone's own pull zone, and the `cdn` record in the velopilot.be DNS zone (which velo-pilot/site manages) |
| `infra/github.tf` | The `dev` environment of velo-pilot/fdroid, and its variables and secrets |
| `infra/secrets.enc.yaml` | Secrets, encrypted with [SOPS](https://github.com/getsops/sops) for the PGP keys in `.sops.yaml` |
| `infra/repo-key.sh` | Creates the repository keys and prints their fingerprints |
| `infra/new-github-token.sh` | Creates the GitHub tokens |

State is local (`infra/terraform.tfstate`, gitignored) and holds the storage zone passwords and
the dev key. Keys in `infra/secrets.enc.yaml`:

- `bunny_api_key`: bunny.net → Account settings → API key (the same as velo-pilot/site's). Only
  `release.sh` uses it outside OpenTofu, to purge the cache.
- `github_token`: for OpenTofu, a fine-grained token for velo-pilot/fdroid with read access to
  *Actions* and read/write access to *Administration*, *Environments*, *Secrets* and *Variables*:
  `infra/new-github-token.sh infra`.
- `android_releases_token`: for the publish job and `release.sh`, a fine-grained token for
  velo-pilot/android with read access to *Contents*: `infra/new-github-token.sh releases`.
  Not needed once velo-pilot/android is public.
- `fdroid_dev_keystore_base64`, `fdroid_dev_keystore_password`: the dev key, from
  `infra/repo-key.sh new dev`.

First setup, after creating the GitHub repository velo-pilot/fdroid:

```sh
sudo pacman -S --needed opentofu sops podman rbw
infra/new-github-token.sh infra
infra/new-github-token.sh releases
infra/repo-key.sh new dev
infra/repo-key.sh new release    # stores the key in Bitwarden; back up the vault
tofu -chdir=infra init
tofu -chdir=infra apply
```

Then push this repository to `main` to publish the dev repository, and run `./release.sh`
for the release repository.
