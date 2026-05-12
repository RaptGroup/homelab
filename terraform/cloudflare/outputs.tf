output "apex_zone_id" {
  description = "Cloudflare zone ID for jackhall.dev. Mostly useful for follow-up CF API calls; not consumed by another TF root."
  value       = local.apex_zone.id
}

output "apex_zone_nameservers" {
  description = "The two authoritative nameservers Cloudflare has assigned to the jackhall.dev zone. Paste these into Squarespace's registrar nameserver fields (replacing the four `ns-cloud-a*.googledomains.com.` values currently configured) to flip the apex from Cloud DNS to Cloudflare. Until that flip, the CF zone is `Pending Nameserver Update` and only resolvers querying CF directly see these records."
  value       = local.apex_zone.name_servers
}

output "apex_zone_nameservers_json" {
  description = "Same as apex_zone_nameservers, but pre-formatted as JSON so `tofu output -raw apex_zone_nameservers_json` is convenient for scripting. The Squarespace registrar UI takes them one at a time, so the raw output is the operationally useful form."
  value       = jsonencode(local.apex_zone.name_servers)
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
