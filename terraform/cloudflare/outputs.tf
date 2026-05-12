output "projects_zone_id" {
  description = "Cloudflare zone ID for projects.jackhall.dev. Mostly useful for follow-up CF API calls; not consumed by another TF root."
  value       = local.projects_zone.id
}

output "projects_zone_nameservers" {
  description = "The four authoritative nameservers Cloudflare has assigned to the projects.jackhall.dev zone. Paste this list into terraform/gcp/terraform.tfvars as `projects_zone_nameservers = [...]` and re-apply terraform/gcp/ to publish the NS delegation at the apex."
  value       = local.projects_zone.name_servers
}

output "projects_zone_nameservers_json" {
  description = "Same as projects_zone_nameservers, but pre-formatted as JSON so `tofu output -raw projects_zone_nameservers_json` drops directly into a tfvars file. Convenience wrapper, not a separate piece of data."
  value       = jsonencode(local.projects_zone.name_servers)
}

output "tunnel_id" {
  description = "UUID of the cloudflared tunnel. Used as the CNAME target `<id>.cfargotunnel.com` (already published by this root) and as the identifier in the Cloudflare Zero Trust dashboard."
  value       = cloudflare_zero_trust_tunnel_cloudflared.projects.id
}

output "tunnel_cname_target" {
  description = "The hostname the wildcard *.projects.jackhall.dev CNAME points at. Echoing it here so an operator can sanity-check the published record against the tunnel's published CNAME."
  value       = "${cloudflare_zero_trust_tunnel_cloudflared.projects.id}.cfargotunnel.com"
}

output "tunnel_token_secret_id" {
  description = "GSM secret ID holding the connector token. The cloudflared addon's ExternalSecret in kubernetes/apps/cloudflared/manifests/ references this name verbatim. Versions are written by this root on every apply; rotation is a `terraform taint` of the tunnel followed by `tofu apply`."
  value       = local.cloudflare_tunnel_token_secret_id
}
