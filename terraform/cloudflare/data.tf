# Pull project ID, apex DNS name, the two GSM secret IDs, and Cloud DNS's
# nameservers for the lab subzone from terraform/gcp state. This root creates
# Cloudflare-side resources; terraform/gcp owns the GSM containers those
# resources read from and write to, and the Cloud DNS lab zone whose NS
# values we delegate to from the CF apex.
data "terraform_remote_state" "gcp" {
  backend = "gcs"

  config = {
    bucket = "rockingham-homelab-tfstate"
    prefix = "terraform/gcp"
  }
}

locals {
  project_id                        = var.gcp_project_id != "" ? var.gcp_project_id : data.terraform_remote_state.gcp.outputs.project_id
  apex_dns_name                     = data.terraform_remote_state.gcp.outputs.apex_dns_name
  cloudflare_api_token_secret_id    = data.terraform_remote_state.gcp.outputs.cloudflare_api_token_secret_id
  cloudflare_tunnel_token_secret_id = data.terraform_remote_state.gcp.outputs.cloudflare_tunnel_token_secret_id

  # Cloud DNS's authoritative nameservers for the lab.jackhall.dev zone.
  # Published as NS records inside the CF apex zone at lab.jackhall.dev so
  # the lab subzone stays delegated to Cloud DNS post-apex-move (ADR-0003
  # amendment). Reading this from remote state — rather than hardcoding
  # the four `ns-cloud-d*.googledomains.com.` values — keeps the
  # delegation correct if Cloud DNS ever re-shards the lab zone onto a
  # different ns-cloud-* set.
  lab_zone_name_servers = data.terraform_remote_state.gcp.outputs.lab_zone_name_servers
}

# Operator-uploaded CF API token. The plaintext is fetched at plan/apply
# time only — it lands in the state file as a sensitive value, the same
# posture as the bootstrap ESO SA key in terraform/bootstrap/. Outside of
# state, the value lives only in GSM.
data "google_secret_manager_secret_version_access" "cloudflare_api_token" {
  project = local.project_id
  secret  = local.cloudflare_api_token_secret_id
}
