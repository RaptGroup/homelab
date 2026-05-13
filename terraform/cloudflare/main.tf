# Cloudflare-side records for the homelab's two public surfaces (ADR-0003
# amendment + ADR-0006 amendment, both dated 2026-05-12).
#
# This root owns the contents of the CF-managed apex zone for
# `jackhall.dev`:
#
#   - Apex CAA pinning issuance to letsencrypt.org. Mirrors what the
#     Cloud DNS apex used to publish; load-bearing for `*.lab.jackhall.dev`
#     cert renewals (cert-manager DNS-01 against Cloud DNS, validated by
#     LE whose CAA walk lands here).
#   - NS delegation records at `lab.jackhall.dev` pointing at the four
#     `ns-cloud-d*.googledomains.com.` Cloud DNS nameservers. Keeps the
#     `lab.jackhall.dev` zone exactly where it was (Cloud DNS), reached
#     via inter-provider NS delegation from this CF apex.
#   - CAA exception at `projects.jackhall.dev` allowing pki.goog +
#     letsencrypt.org — Cloudflare's contracted CAs for issuance on the
#     public preview surface.
#   - ACM-issued advanced edge certificate covering
#     `projects.jackhall.dev` + `*.projects.jackhall.dev`. CF Universal
#     SSL (free) only covers depth-1 names (apex + `*.<apex>`) and the
#     CA/B Forum prohibits nested wildcards, so two-label hostnames like
#     `<svc>-<ns>.projects.jackhall.dev` require an Advanced Certificate
#     Manager pack ($10/mo). See ADR-0006's 2026-05-13 amendment.
#   - The named Cloudflare Tunnel (`rockingham-projects`) with
#     `config_src = "cloudflare"` — ingress rules managed via the CF
#     API (this root), not via a config file on the cloudflared pod.
#   - Tunnel ingress config: wildcard rule forwarding
#     `*.projects.jackhall.dev` to the `projects` Cilium Gateway's
#     ClusterIP-resolved Service in-cluster; fallback 404.
#   - Wildcard CNAME `*.projects.jackhall.dev → <tunnel-id>.cfargotunnel.com`
#     proxied through CF's edge; TLS terminates at the ACM-issued
#     wildcard cert above.
#   - GSM version write of the per-tunnel connector token so the
#     in-cluster `cloudflared` addon's ExternalSecret can sync it.
#
# The apex zone itself is added in the CF dashboard during one-time
# bootstrap — see README. This root reads it as a data source.

# Apex zone metadata. `data.cloudflare_zones` returns a list; bind the
# single expected match via `one()` so a zero-length result fails loudly
# rather than silently treating the zone as missing.
data "cloudflare_zones" "apex" {
  name = local.apex_dns_name
}

locals {
  apex_zone = one(data.cloudflare_zones.apex.result)

  projects_record_name = "projects.${local.apex_dns_name}"
  lab_subzone_name     = "lab.${local.apex_dns_name}"
}

# --- Apex CAA: letsencrypt.org ----------------------------------------------
#
# Mirrors the Cloud DNS apex CAA verbatim (see
# terraform/gcp/main.tf → google_dns_record_set.apex_caa). Both records
# coexist during Squarespace propagation — same content, different
# providers — and resolvers querying either side get the same answer.
# Once Squarespace's NS update has propagated and the Cloud DNS apex is
# fully unreferenced, the GCP-side record is removed in #146.
#
# `issuewild` is the load-bearing one for `*.lab.jackhall.dev`; the
# plain `issue` is included for completeness so a non-wildcard cert
# (if ever needed) under the apex doesn't fall through to default-allow.
resource "cloudflare_dns_record" "apex_caa_issue" {
  for_each = toset(var.apex_caa_issuers)

  zone_id = local.apex_zone.id
  name    = local.apex_dns_name
  type    = "CAA"
  ttl     = 300

  data = {
    flags = 0
    tag   = "issue"
    value = each.value
  }
}

resource "cloudflare_dns_record" "apex_caa_issuewild" {
  for_each = toset(var.apex_caa_issuers)

  zone_id = local.apex_zone.id
  name    = local.apex_dns_name
  type    = "CAA"
  ttl     = 300

  data = {
    flags = 0
    tag   = "issuewild"
    value = each.value
  }
}

# --- Lab subzone delegation: NS pointing at Cloud DNS -----------------------
#
# Keeps `lab.jackhall.dev` on Cloud DNS unchanged. The NS values are
# read from terraform/gcp/'s `lab_zone_name_servers` output via
# terraform_remote_state — no operator paste, no drift if Cloud DNS
# ever re-shards the zone to a different ns-cloud-* set.
#
# The NS record set lives at `lab.jackhall.dev` inside the CF apex
# zone; CF must serve this so that a public resolver following the
# apex's NS chain finds the Cloud DNS nameservers for the lab subzone
# and continues resolution there.
resource "cloudflare_dns_record" "lab_delegation" {
  for_each = toset(local.lab_zone_name_servers)

  zone_id = local.apex_zone.id
  name    = local.lab_subzone_name
  type    = "NS"
  ttl     = 21600

  # The v5 provider's NS record type stores the target in `content`.
  # Cloud DNS exports nameservers with trailing dots; strip them here
  # because Cloudflare normalises away the trailing dot on storage and
  # would otherwise emit a no-op diff on every plan.
  content = trimsuffix(each.value, ".")
}

# --- Projects CAA exception: CF's contracted CAs ----------------------------
#
# Without this, the ACM-issued projects wildcard below (Google CA) would
# walk up to the apex CAA (`letsencrypt.org`), hit the `issuewild
# letsencrypt.org` pin, and fail to issue via Google Trust Services.
# Publishing CAA at `projects.jackhall.dev` overrides the walk for
# `projects.*` and below; the apex pin still applies to
# `*.lab.jackhall.dev` and any other non-projects name. `letsencrypt.org`
# is included alongside `pki.goog` so that flipping the certificate pack
# to `certificate_authority = "lets_encrypt"` doesn't require a CAA
# change too.
resource "cloudflare_dns_record" "projects_caa_issue" {
  for_each = toset(var.projects_caa_issuers)

  zone_id = local.apex_zone.id
  name    = local.projects_record_name
  type    = "CAA"
  ttl     = 300

  data = {
    flags = 0
    tag   = "issue"
    value = each.value
  }
}

resource "cloudflare_dns_record" "projects_caa_issuewild" {
  for_each = toset(var.projects_caa_issuers)

  zone_id = local.apex_zone.id
  name    = local.projects_record_name
  type    = "CAA"
  ttl     = 300

  data = {
    flags = 0
    tag   = "issuewild"
    value = each.value
  }
}

# --- Projects edge certificate: ACM advanced wildcard -----------------------
#
# CF Universal SSL on the Free plan covers depth-1 names only (apex +
# `*.<apex>`); CA/B Forum's nested-wildcard prohibition means
# `*.jackhall.dev` cannot cover `<anything>.<anything>.jackhall.dev`.
# Our preview hostnames are `<svc>-<ns>.projects.jackhall.dev` — two
# labels deep — so Universal SSL has no cert that can serve them and CF
# rejects the TLS handshake at the edge. Advanced Certificate Manager
# (paid: $10/mo per zone) issues a cert whose SAN list explicitly
# includes both `projects.jackhall.dev` and `*.projects.jackhall.dev`,
# which terminates TLS correctly for any single-label name under
# `projects`.
#
# DNS-01 (`validation_method = "txt"`) is auto-served by CF inside this
# same apex zone, so no operator interaction is needed for validation
# or renewal. `certificate_authority = "google"` matches the pki.goog
# entry in the projects CAA exception above; `lets_encrypt` would also
# satisfy CAA but Google issues faster and is CF's default for ACM.
# `validity_days = 90` matches the LE-style cadence we're used to from
# cert-manager on the lab path; CF auto-renews.
resource "cloudflare_certificate_pack" "projects_wildcard" {
  zone_id               = local.apex_zone.id
  type                  = "advanced"
  hosts                 = [local.projects_record_name, "*.${local.projects_record_name}"]
  validation_method     = "txt"
  validity_days         = 90
  certificate_authority = "google"
  cloudflare_branding   = false
}

# --- Cloudflare Tunnel ------------------------------------------------------
#
# Tunnel secret — base64-encoded 32-byte random value that authenticates
# the tunnel itself. Distinct from the *connector token* (data source
# below) which is what cloudflared inside the cluster actually uses to
# dial out. random_password with no keepers makes the secret stable
# across applies — rotation is a deliberate `terraform taint`, not an
# incidental keeper-bust.
resource "random_password" "tunnel_secret" {
  length      = 64
  special     = false
  min_lower   = 1
  min_upper   = 1
  min_numeric = 1
}

# The named tunnel. config_src = "cloudflare" means ingress rules are
# managed via the CF API (the cloudflare_zero_trust_tunnel_cloudflared_config
# resource below), not via a credentials.json file rendered into the
# cloudflared pod. Keeps the in-cluster deployment minimal: just the
# connector token, no config-file mount.
resource "cloudflare_zero_trust_tunnel_cloudflared" "projects" {
  account_id    = var.cloudflare_account_id
  name          = var.tunnel_name
  config_src    = "cloudflare"
  tunnel_secret = base64encode(random_password.tunnel_secret.result)
}

# Ingress config: forward every `*.projects.jackhall.dev` hostname to
# the projects Cilium Gateway, fallback 404 for anything else. The
# fallback is cosmetic — the wildcard CNAME below is the only public
# entry point — but cloudflared requires a terminal rule.
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "projects" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.projects.id

  config = {
    ingress = [
      {
        hostname = "*.${local.projects_record_name}"
        service  = var.tunnel_origin_service
      },
      {
        service = "http_status:404"
      },
    ]
  }
}

# Wildcard CNAME. `proxied = true` is load-bearing — without it the
# CNAME resolves to the cfargotunnel.com host directly, browsers see
# whatever cert cfargotunnel presents (not the ACM-issued wildcard),
# and the request never reaches the tunnel correctly.
resource "cloudflare_dns_record" "projects_wildcard" {
  zone_id = local.apex_zone.id
  name    = "*.${local.projects_record_name}"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.projects.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1 # "automatic" — CF requires ttl=1 for proxied records
}

# Connector token. cloudflared inside the cluster uses this to dial
# out. Sensitive value — TF stores it in state (same posture as
# bootstrap SA keys in terraform/bootstrap/) and writes it to GSM as
# a new version so the cluster-side ExternalSecret can sync it.
data "cloudflare_zero_trust_tunnel_cloudflared_token" "projects" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.projects.id
}

# Push the token to GSM. Container TF-managed in terraform/gcp/; this
# root only writes versions. A `terraform taint
# cloudflare_zero_trust_tunnel_cloudflared.projects` followed by
# `tofu apply` rotates the tunnel and lands a new GSM version; ESO
# picks it up at the next refresh.
resource "google_secret_manager_secret_version" "tunnel_token" {
  secret      = "projects/${local.project_id}/secrets/${local.cloudflare_tunnel_token_secret_id}"
  secret_data = data.cloudflare_zero_trust_tunnel_cloudflared_token.projects.token
}
