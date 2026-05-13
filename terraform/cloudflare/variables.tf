variable "cloudflare_account_id" {
  description = "Cloudflare account ID that owns the apex jackhall.dev zone. Find at https://dash.cloudflare.com → account home → Overview (right sidebar). The same account holds the API token in GSM."
  type        = string
}

variable "tunnel_name" {
  description = "Human-readable name for the cloudflared tunnel that fronts the projects Gateway. Surfaces in Cloudflare's Zero Trust dashboard as the tunnel identity; not used in DNS or URLs."
  type        = string
  default     = "rockingham-projects"
}

variable "apex_caa_issuers" {
  description = "CA hostnames allowed to issue certificates at the apex jackhall.dev. Mirrors the Cloud DNS apex CAA verbatim (terraform/gcp/main.tf → var.apex_caa_issuers); load-bearing for *.lab.jackhall.dev cert renewals to keep passing the CAA walk after the apex move (ADR-0003 amendment 2026-05-12)."
  type        = list(string)
  default     = ["letsencrypt.org"]
}

variable "projects_caa_issuers" {
  description = "CA hostnames allowed to issue certificates for projects.jackhall.dev and below. Published as a CAA record at the projects.jackhall.dev name inside the CF apex zone; overrides the apex letsencrypt.org pin for this name only (ADR-0006). Cloudflare's contracted CAs are pki.goog (Google Trust Services / DigiCert) and letsencrypt.org; the ACM-issued projects wildcard (cloudflare_certificate_pack.projects_wildcard, certificate_authority = \"google\") needs pki.goog allowed here."
  type        = list(string)
  default     = ["pki.goog", "letsencrypt.org"]
}

variable "tunnel_origin_service" {
  description = "Cleartext HTTP URL cloudflared forwards inbound `*.projects.jackhall.dev` traffic to. The `projects` Cilium Gateway (kubernetes/apps/projects-gateway/) is exposed as a Service named `cilium-gateway-projects` in the gateway-system namespace — Cilium uses the `cilium-gateway-<gateway-name>` naming convention for the auto-generated Service. Port 80 because TLS terminates at Cloudflare's edge and the in-cluster hop is cleartext inside the tunnel (see ADR-0006)."
  type        = string
  default     = "http://cilium-gateway-projects.gateway-system.svc.cluster.local:80"
}

variable "gcp_project_id" {
  description = "Override for the GCP project ID. Defaults to the terraform_remote_state lookup against terraform/gcp/ — set only when applying this root against a project ID other than what gcp's state currently has, which should be never under normal operation."
  type        = string
  default     = ""
}
