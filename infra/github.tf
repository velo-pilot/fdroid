# The dev environment that the publish job in .github/workflows/publish-dev.yml runs
# in, and the credentials it uses: the dev storage zone and the dev repository key,
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
    # Signs the dev repository index; created by infra/repo-key.sh new dev.
    FDROID_KEYSTORE_BASE64   = local.secrets.fdroid_dev_keystore_base64
    FDROID_KEYSTORE_PASSWORD = local.secrets.fdroid_dev_keystore_password
  }

  repository  = local.repository
  environment = github_repository_environment.dev.environment
  secret_name = each.key
  value       = each.value
}
