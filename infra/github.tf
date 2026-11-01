# The dev environment that the publish jobs in .github/workflows/publish.yml run in,
# and the credentials they use: the dev storage zone and the CI repository key,
# nothing that can change the release repository. Only main may use it, so other
# branches and pull requests never see the secrets.

locals {
  repository = "fdroid"
}

resource "github_repository_environment" "dev" {
  repository  = local.repository
  environment = "dev"

  deployment_branch_policy {
    protected_branches     = false
    custom_branch_policies = true
  }
}

resource "github_repository_environment_deployment_policy" "main" {
  repository     = local.repository
  environment    = github_repository_environment.dev.environment
  branch_pattern = "main"
}

resource "github_actions_environment_variable" "dev" {
  for_each = {
    BUNNY_STORAGE_ZONE = bunnynet_storage_zone.dev.name
    BUNNY_STORAGE_HOST = bunnynet_storage_zone.dev.hostname
  }

  repository    = local.repository
  environment   = github_repository_environment.dev.environment
  variable_name = each.key
  value         = each.value
}

resource "github_actions_environment_secret" "dev" {
  for_each = {
    BUNNY_STORAGE_PASSWORD = bunnynet_storage_zone.dev.password
    # Reads the releases of velo-pilot/android while that repository is private.
    ANDROID_RELEASES_TOKEN = local.secrets.android_releases_token
    # Signs the dev and beta repository indexes; created by infra/repo-key.sh new dev.
    FDROID_KEYSTORE_BASE64   = local.secrets.fdroid_dev_keystore_base64
    FDROID_KEYSTORE_PASSWORD = local.secrets.fdroid_dev_keystore_password
  }

  repository  = local.repository
  environment = github_repository_environment.dev.environment
  secret_name = each.key
  value       = each.value
}

# The environments of velo-pilot/android that its workflows build and sign the APKs
# in: dev (.github/workflows/velopilot-dev.yml, the dev signing key) and release
# (.github/workflows/velopilot-release.yml, the release signing key, for betas and
# releases). Only main may use them. Both may ask this repository to publish.

locals {
  android = "android"
  # The keys come from infra/apk-key.sh
  android_environments = {
    dev = {
      APK_KEYSTORE_BASE64 = local.secrets.apk_dev_keystore_base64
      APK_KEY_PASSWORD    = local.secrets.apk_dev_keystore_password
    }
    release = {
      APK_KEYSTORE_BASE64 = local.secrets.apk_release_keystore_base64
      APK_KEY_PASSWORD    = local.secrets.apk_release_keystore_password
    }
  }
  # Without fdroid_dispatch_token (infra/new-github-token.sh dispatch), velo-pilot/fdroid picks up new builds
  # with its schedule
  dispatch = can(local.secrets.fdroid_dispatch_token) ? { FDROID_DISPATCH_TOKEN = local.secrets.fdroid_dispatch_token } : {}
  android_secrets = merge([
    for environment, secrets in local.android_environments : {
      for name, value in merge(secrets, local.dispatch) :
      "${environment}/${name}" => { environment = environment, name = name, value = value }
    }
  ]...)
}

resource "github_repository_environment" "android" {
  for_each    = local.android_environments
  repository  = local.android
  environment = each.key

  deployment_branch_policy {
    protected_branches     = false
    custom_branch_policies = true
  }
}

resource "github_repository_environment_deployment_policy" "android_main" {
  for_each       = github_repository_environment.android
  repository     = local.android
  environment    = each.value.environment
  branch_pattern = "main"
}

resource "github_actions_environment_secret" "android" {
  for_each    = local.android_secrets
  repository  = local.android
  environment = github_repository_environment.android[each.value.environment].environment
  secret_name = each.value.name
  value       = each.value.value
}
