# Secrets come from infra/secrets.enc.yaml, encrypted with SOPS for the PGP keys
# in /.sops.yaml. Create or edit it with: sops infra/secrets.enc.yaml
data "sops_file" "secrets" {
  source_file = "${path.module}/secrets.enc.yaml"
}

locals {
  secrets = yamldecode(data.sops_file.secrets.raw)
}

provider "sops" {}

provider "bunnynet" {
  api_key = local.secrets.bunny_api_key
}

provider "github" {
  owner = "velo-pilot"
  token = local.secrets.github_token
}
