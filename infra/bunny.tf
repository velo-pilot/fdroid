# cdn.velopilot.be on bunny.net: two storage zones behind one hostname.
#
# - release: the release repository (/fdroid/), uploaded from a local checkout by
#   release.sh. Its password never leaves this state. It is the origin of the
#   pull zone on cdn.velopilot.be.
# - dev: the dev and beta repositories (/fdroid-dev/, /fdroid-beta/), uploaded by
#   the GitHub Actions jobs, which get this zone's password only. It has a pull zone
#   of its own, which an edge rule on cdn.velopilot.be forwards both folders to.
#
# The velopilot.be DNS zone belongs to velo-pilot/site (its infra/bunny.tf); this
# only adds the cdn record to it.

locals {
  domain   = "velopilot.be"
  hostname = "cdn.${local.domain}"
  # Storage and pull zone names are global across all bunny.net accounts.
  release_zone_name = "velopilot-fdroid"
  dev_zone_name     = "velopilot-fdroid-dev"
  pullzone_name     = "velopilot-cdn"
  dev_pullzone_name = "velopilot-fdroid-dev"
  # The provider's cdn_domain is only the suffix (b-cdn.net).
  cdn_host = "${bunnynet_pullzone.cdn.name}.${bunnynet_pullzone.cdn.cdn_domain}"
}

# HDD, no replication, Falkenstein (like the site's zone): the pull zone caches
# everything, and both repositories can be rebuilt from the GitHub releases.
resource "bunnynet_storage_zone" "release" {
  name      = local.release_zone_name
  zone_tier = "Standard"
  region    = "DE"

  lifecycle {
    # Replacing the zone deletes the repository, changes the upload password, and
    # Bunny also deletes the pull zone (with its hostname and certificate).
    prevent_destroy = true
  }
}

resource "bunnynet_storage_zone" "dev" {
  name      = local.dev_zone_name
  zone_tier = "Standard"
  region    = "DE"
}

resource "bunnynet_pullzone" "cdn" {
  name = local.pullzone_name

  # The provider defaults to blocking requests without a Referer, which F-Droid
  # clients don't send, and to allowing TLS 1.0 and 1.1.
  block_no_referer = false
  tls_support      = []

  origin {
    type        = "StorageZone"
    storagezone = bunnynet_storage_zone.release.id
  }

  routing {
    tier = "Standard"
  }
}

# The dev storage zone's own pull zone, only reached through cdn.velopilot.be. The
# jobs can't purge caches (that needs the account API key, which can change anything,
# release zone included), so both pull zones keep its files for a minute only.
resource "bunnynet_pullzone" "dev" {
  name = local.dev_pullzone_name

  block_no_referer      = false
  tls_support           = []
  cache_expiration_time = 60

  origin {
    type        = "StorageZone"
    storagezone = bunnynet_storage_zone.dev.id
  }

  routing {
    tier = "Standard"
  }
}

# /fdroid-dev/ and /fdroid-beta/ on cdn.velopilot.be come from the dev pull zone,
# path unchanged, so the jobs upload to those folders in the dev zone. (The OriginStorage action, which
# would skip the second pull zone, rejects every storage zone id with "Storage zone
# not valid".)
resource "bunnynet_pullzone_edgerule" "dev" {
  enabled     = true
  pullzone    = bunnynet_pullzone.cdn.id
  description = "Serve /fdroid-dev/ and /fdroid-beta/ from the ${local.dev_zone_name} storage zone"

  actions = [
    {
      type       = "OriginUrl"
      parameter1 = "https://${bunnynet_pullzone.dev.name}.${bunnynet_pullzone.dev.cdn_domain}"
      parameter2 = null
      parameter3 = null
    },
    {
      type       = "OverrideCacheTime"
      parameter1 = "60"
      parameter2 = null
      parameter3 = null
    },
  ]

  match_type = "MatchAny"
  triggers = [
    {
      type       = "Url"
      match_type = "MatchAny"
      patterns   = ["*/fdroid-dev/*", "*/fdroid-beta/*"]
      parameter1 = null
      parameter2 = null
    }
  ]
}

data "bunnynet_dns_zone" "site" {
  domain = local.domain
}

resource "bunnynet_dns_record" "cdn" {
  zone  = data.bunnynet_dns_zone.site.id
  name  = "cdn"
  type  = "CNAME"
  value = local.cdn_host
}

# Bunny issues a Let's Encrypt certificate for the hostname, which needs the DNS
# record above to resolve to the pull zone first.
resource "bunnynet_pullzone_hostname" "cdn" {
  pullzone    = bunnynet_pullzone.cdn.id
  name        = local.hostname
  tls_enabled = true
  force_ssl   = true

  depends_on = [bunnynet_dns_record.cdn]
}
