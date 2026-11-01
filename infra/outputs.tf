output "cdn_domain" {
  description = "The pull zone's own hostname, to test before DNS works."
  value       = local.cdn_host
}

output "repo_urls" {
  description = "The F-Droid repositories; infra/repo-key.sh fingerprint prints the links to add them."
  value = {
    release = "https://${local.hostname}/fdroid/repo"
    dev     = "https://${local.hostname}/fdroid-dev/repo"
  }
}

# For release.sh, which uploads the release repository from this checkout.
output "release_upload" {
  description = "Release storage zone and pull zone, for release.sh."
  sensitive   = true
  value = {
    BUNNY_STORAGE_ZONE     = bunnynet_storage_zone.release.name
    BUNNY_STORAGE_HOST     = bunnynet_storage_zone.release.hostname
    BUNNY_STORAGE_PASSWORD = bunnynet_storage_zone.release.password
    BUNNY_PULLZONE_ID      = tostring(bunnynet_pullzone.cdn.id)
  }
}
