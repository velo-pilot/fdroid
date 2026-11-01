terraform {
  required_version = "~> 1.13"

  required_providers {
    bunnynet = {
      source  = "BunnyWay/bunnynet"
      version = "0.19.2"
    }
    github = {
      source  = "integrations/github"
      version = "6.13.0"
    }
    sops = {
      source  = "carlpett/sops"
      version = "1.4.1"
    }
  }

  # Local state (infra/terraform.tfstate), gitignored. It holds the storage zone
  # passwords and the dev repository key, so don't share it; if it's lost,
  # import the resources again.
}
