# VeloPilot F-Droid repositories

F-Droid repositories for [VeloPilot](https://velopilot.be), built from the GitHub releases of
[velo-pilot/android](https://github.com/velo-pilot/android) and hosted on Bunny CDN, one per channel:

| Repository | URL | Contents | App | Signed with | Published by |
| --- | --- | --- | --- | --- | --- |
| release | <https://cdn.velopilot.be/fdroid/repo> | the newest 3 releases `vX.Y.Z` | VeloPilot, `be.velopilot.app` | release key, in Bitwarden | `./release.sh`, locally |
| beta | <https://cdn.velopilot.be/fdroid-beta/repo> | the newest 3 betas `vX.Y.Z-beta.N` (pre-releases) | VeloPilot Beta, `be.velopilot.beta` (β icon) | CI key, in SOPS and GitHub | GitHub Actions |
| dev | <https://cdn.velopilot.be/fdroid-dev/repo> | the newest 3 builds of main `vX.Y.Z-dev.RUN` (pre-releases) | VeloPilot Dev, `be.velopilot.dev` (α icon) | CI key, in SOPS and GitHub | GitHub Actions |

The three are separate apps (flavours `velopilot`, `velopilotBeta` and `velopilotDev` in velo-pilot/android),
so they install next to each other.

Everything users download comes from cdn.velopilot.be: the APKs, icons and signed index. Each
folder also has `velopilot-latest.apk`, a copy of the newest APK for a stable download link
(`https://cdn.velopilot.be/fdroid/velopilot-latest.apk`). Users add a repository with its
fingerprint (`infra/repo-key.sh fingerprint release|dev`; the beta repository has the dev
fingerprint) to F-Droid, Droid-ify, Neo Store or Obtainium.

The release repository key never leaves Bitwarden except while `./release.sh` signs a release, and
the release storage zone's password stays in the local OpenTofu state. GitHub only holds the CI key
and the CI storage zone's password, so a leak there can't change the release repository.

## Layout

| Path | What |
| --- | --- |
| `metadata/be.velopilot.app.yml` | App description, links and categories shown in F-Droid; the beta and dev apps get `BETA_METADATA` and `DEV_METADATA` in `scripts/build-repo.py` on top |
| `icon.png`, `icon-beta.png`, `icon-dev.png` | Repository and app icons, from `branding/generate.py` in velo-pilot/android |
| `scripts/fetch-releases.py` | Lists the newest releases of a channel in velo-pilot/android and downloads their APKs |
| `scripts/build-repo.py` | Writes the metadata with each release's notes as its changelog, runs `fdroid update` to sign the index |
| `scripts/bunny-sync.py` | Uploads the repository to Bunny Storage: changed files only, APKs first, the index last, then deletes what's gone |
| `.github/workflows/publish.yml` | Builds and publishes the beta and dev repositories |
| `release.sh`, `Containerfile` | Builds and publishes the release repository from a local checkout |
| `infra/` | bunny.net and GitHub setup of both repositories, as OpenTofu |

## Releases in velo-pilot/android

The workflows of velo-pilot/android build and publish the GitHub releases (see `build-container/README.md`
there): every push to main a dev build, by hand a beta or a release. Each release has exactly one `.apk`
asset; the tag says the channel, and the release notes become the F-Droid changelog (up to 500 characters).
Drafts are skipped. After a dev build or beta, the workflow starts the publish jobs here with a
`repository_dispatch` (with `FDROID_DISPATCH_TOKEN`); without it, the schedule picks them up within 6 hours.

## Publishing a release

After a release in velo-pilot/android:

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

## Beta and dev repositories (GitHub Actions)

`.github/workflows/publish.yml` publishes both on pushes to `main`, on an `android-release` repository
dispatch, every 6 hours and on demand (Actions > Publish dev and beta > Run workflow; tick *force* to
publish even if nothing changed). Runs without changes stop after comparing the releases and this
repository with `inputs.sha256` on the CDN; runs without any release of a channel keep what its
repository holds. The jobs run in the GitHub `dev` environment, which only accepts `main`. They can't
purge the CDN cache (that needs the account API key); both pull zones keep `/fdroid-beta/` and
`/fdroid-dev/` cached for a minute instead.

## Infrastructure (OpenTofu)

`infra/` defines everything the repositories and the Android builds run on, so change these settings
there, not in the bunny.net or GitHub UI (the next plan would revert UI edits):

| File | What |
| --- | --- |
| `infra/bunny.tf` | Storage zones for the release repository and the CI (beta and dev) repositories, the pull zone on `cdn.velopilot.be` (origin: the release zone) with an edge rule that forwards `/fdroid-beta/` and `/fdroid-dev/` to the CI zone's own pull zone, and the `cdn` record in the velopilot.be DNS zone (which velo-pilot/site manages) |
| `infra/github.tf` | The `dev` environment of velo-pilot/fdroid, the `dev` and `release` environments of velo-pilot/android, and their variables and secrets |
| `infra/secrets.enc.yaml` | Secrets, encrypted with [SOPS](https://github.com/getsops/sops) for the PGP keys in `.sops.yaml` |
| `infra/repo-key.sh` | Creates the repository keys and prints their fingerprints |
| `infra/apk-key.sh` | Creates the APK signing keys and prints their certificate fingerprints |
| `infra/new-github-token.sh` | Creates the GitHub tokens |

State is local (`infra/terraform.tfstate`, gitignored) and holds the storage zone passwords and
the CI keys. Keys in `infra/secrets.enc.yaml`:

- `bunny_api_key`: bunny.net → Account settings → API key (the same as velo-pilot/site's). Only
  `release.sh` uses it outside OpenTofu, to purge the cache.
- `github_token`: for OpenTofu, a fine-grained token for velo-pilot/fdroid and velo-pilot/android
  with read access to *Actions* and read/write access to *Administration*, *Environments*, *Secrets*
  and *Variables*: `infra/new-github-token.sh infra`.
- `android_releases_token`: for the publish jobs and `release.sh`, a fine-grained token for
  velo-pilot/android with read access to *Contents*: `infra/new-github-token.sh releases`.
  Not needed once velo-pilot/android is public.
- `fdroid_dispatch_token`: for the workflows of velo-pilot/android, a fine-grained token for
  velo-pilot/fdroid with read/write access to *Contents*: `infra/new-github-token.sh dispatch`.
  Optional: without it, the schedule picks up new builds.
- `fdroid_dev_keystore_base64`, `fdroid_dev_keystore_password`: the CI repository key, from
  `infra/repo-key.sh new dev`.
- `apk_dev_keystore_*`, `apk_release_keystore_*`: the APK signing keys of VeloPilot Dev, and of
  VeloPilot Beta and VeloPilot, from `infra/apk-key.sh new dev|release`. Losing the release key means
  users have to uninstall VeloPilot to update it.

First setup, after creating the GitHub repositories:

```sh
sudo pacman -S --needed opentofu sops podman rbw
infra/new-github-token.sh infra
infra/new-github-token.sh releases
infra/new-github-token.sh dispatch
infra/repo-key.sh new dev
infra/repo-key.sh new release    # stores the key in Bitwarden; back up the vault
infra/apk-key.sh new dev
infra/apk-key.sh new release
tofu -chdir=infra init
tofu -chdir=infra apply
```

Then push this repository to `main`, push velo-pilot/android to build, and run `./release.sh`
for the release repository.
