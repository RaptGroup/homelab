# Public preview-env DNS + tunnel, ADR-0006.
#
# This root owns:
#   - The Cloudflare zone for projects.jackhall.dev (created in the CF
#     dashboard during one-time bootstrap; this root manages records,
#     not the zone resource itself — see README "Bootstrap").
#   - CAA records inside the subzone allowing CF's contracted CAs (pki.goog
#     for Google Trust Services / DigiCert, letsencrypt.org). Overrides the
#     apex Let's-Encrypt-only pin for this subzone only.
#   - A named Cloudflare Tunnel ("rockingham-projects") with config_src =
#     "cloudflare" — ingress rules are managed via the CF API (this root),
#     not via a credentials.json file on the cloudflared pod.
#   - The tunnel's ingress config: a single wildcard rule forwarding
#     *.projects.jackhall.dev to the `projects` Cilium Gateway's
#     ClusterIP-resolved Service inside the cluster, plus a fallback 404.
#   - The wildcard CNAME *.projects.jackhall.dev → <tunnel-id>.cfargotunnel.com.
#   - A GSM version write of the per-tunnel connector token so the
#     in-cluster `cloudflared` addon's ExternalSecret can sync it without
#     the operator ever handling the value.
#
# Bootstrap order: see README. The NS delegation that makes this subzone
# resolvable lives in terraform/gcp/ — operator pastes the four CF NS
# values output by this root into terraform/gcp/terraform.tfvars and
# re-applies gcp.

# Zone metadata. The zone is created in the Cloudflare dashboard during
# one-time bootstrap (the CF API token is scoped to a single zone, so it
# can't create new zones — that would need an account-level permission
# that widens the token's blast radius). This root reads the existing
# zone by name.
data "cloudflare_zones" "projects" {
  name = local.projects_dns_name
}

locals {
  # cloudflare_zones returns a list; bind the single expected match here so
  # downstream references stay readable. A zero-length result means the
  # operator hasn't completed the dashboard step yet; fail loudly rather
  # than silently treating the zone as missing.
  projects_zone = one(data.cloudflare_zones.projects.result)
}

# CAA records. The apex `jackhall.dev` zone pins issuance to letsencrypt.org
# (see terraform/gcp/main.tf → google_dns_record_set.apex_caa). Cloudflare's
# Universal SSL issues via Google Trust Services (`pki.goog`) by default
# and can fall back to Let's Encrypt; without an explicit CAA override at
# the subzone level, CF's issuance would walk up the tree, hit the apex
# pin, and fail. Publishing CAA at the subzone overrides that walk for
# anything under projects.jackhall.dev only. The apex pin is unchanged.
#
# Two records per issuer cover both plain `issue` and `issuewild`,
# matching the apex's shape. iodef is intentionally omitted — the homelab
# has no SOC inbox for misissuance reports.
resource "cloudflare_dns_record" "caa_issue" {
  for_each = toset(var.caa_issuers)

  zone_id = local.projects_zone.id
  name    = local.projects_dns_name
  type    = "CAA"
  ttl     = 300

  data = {
    flags = 0
    tag   = "issue"
    value = each.value
  }
}

resource "cloudflare_dns_record" "caa_issuewild" {
  for_each = toset(var.caa_issuers)

  zone_id = local.projects_zone.id
  name    = local.projects_dns_name
  type    = "CAA"
  ttl     = 300

  data = {
    flags = 0
    tag   = "issuewild"
    value = each.value
  }
}

# Tunnel secret — a base64-encoded 32-byte random value that authenticates
# the tunnel itself. Distinct from the *connector token* below (which is
# what cloudflared inside the cluster actually uses to dial out). The
# secret never leaves TF state and CF; it's used to mint the connector
# token via the cloudflare_zero_trust_tunnel_cloudflared_token data
# source. random_password's keepers (none here) makes the secret stable
# across applies — rotating the tunnel means a deliberate taint, not an
# incidental keeper-bust.
resource "random_password" "tunnel_secret" {
  length      = 64
  special     = false
  min_lower   = 1
  min_upper   = 1
  min_numeric = 1
}

# The named tunnel. config_src = "cloudflare" means the tunnel's ingress
# rules are managed via the CF API (the
# cloudflare_zero_trust_tunnel_cloudflared_config resource below), not via
# a credentials.json file rendered into the cloudflared pod. That keeps
# the in-cluster deployment minimal: it needs only the connector token,
# no config file mount, no credentials.json secret.
resource "cloudflare_zero_trust_tunnel_cloudflared" "projects" {
  account_id    = var.cloudflare_account_id
  name          = var.tunnel_name
  config_src    = "cloudflare"
  tunnel_secret = base64encode(random_password.tunnel_secret.result)
}

# Ingress config: one wildcard rule forwarding every hostname under
# *.projects.jackhall.dev to the projects Cilium Gateway, plus a fallback
# 404 for anything that somehow reaches the tunnel without a matching
# hostname (shouldn't happen — the wildcard CNAME below only routes the
# subzone — but cloudflared requires a terminal rule).
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "projects" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.projects.id

  config = {
    ingress = [
      {
        hostname = "*.${local.projects_dns_name}"
        service  = var.tunnel_origin_service
      },
      {
        service = "http_status:404"
      },
    ]
  }
}

# The wildcard CNAME. `proxied = true` means CF terminates TLS at the
# edge with the Universal SSL wildcard cert and forwards cleartext HTTP
# down the tunnel to cloudflared. Without `proxied = true`, the CNAME
# would resolve to the cfargotunnel.com host directly, browsers would
# get whatever cert cfargotunnel presents (not the projects-zone one),
# and the request would never enter the tunnel correctly.
resource "cloudflare_dns_record" "wildcard" {
  zone_id = local.projects_zone.id
  name    = "*.${local.projects_dns_name}"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.projects.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1 # "automatic" — CF requires ttl=1 for proxied records
}

# Connector token. cloudflared inside the cluster uses this to dial out
# to Cloudflare's edge. The data source is cheap (single API call) and
# the value is sensitive — TF stores it in state, then writes it to GSM
# as a new secret version. The cloudflared addon's ExternalSecret syncs
# the latest GSM version into a K8s Secret.
data "cloudflare_zero_trust_tunnel_cloudflared_token" "projects" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.projects.id
}

# Push the token to GSM. The container itself is owned by terraform/gcp/;
# this root only writes versions. Every apply that rotates the token (a
# `terraform taint` on the tunnel, or a CF-side disable+rotate) lands a
# new GSM version and the cluster-side ExternalSecret picks it up at its
# next refresh.
resource "google_secret_manager_secret_version" "tunnel_token" {
  secret      = "projects/${local.project_id}/secrets/${local.cloudflare_tunnel_token_secret_id}"
  secret_data = data.cloudflare_zero_trust_tunnel_cloudflared_token.projects.token
}
