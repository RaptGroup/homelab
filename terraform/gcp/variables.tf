variable "project_id" {
  description = "ID of the GCP project this root creates and owns. Must be globally unique across GCP."
  type        = string
  default     = "rockingham-homelab"
}

variable "project_name" {
  description = "Human-readable display name for the project."
  type        = string
  default     = "Rockingham Homelab"
}

variable "billing_account" {
  description = "Billing account ID (e.g. 0X0X0X-0X0X0X-0X0X0X) to attach the project to. Find with `gcloud billing accounts list`."
  type        = string
}

variable "org_id" {
  description = "Optional organization ID to nest the project under. Leave null for personal accounts with no org."
  type        = string
  default     = null
}

variable "folder_id" {
  description = "Optional folder ID to nest the project under. Mutually exclusive with org_id. Leave null for personal accounts."
  type        = string
  default     = null
}

variable "region" {
  description = "Default region for any regional resources. Cloud DNS is global, but the provider still wants a default."
  type        = string
  default     = "us-central1"
}

variable "lab_dns_name" {
  description = "FQDN of the public DNS subzone delegated to Google Cloud DNS. Trailing dot is added automatically."
  type        = string
  default     = "lab.jackhall.dev"
}

variable "lab_zone_name" {
  description = "Name of the Cloud DNS managed zone resource. RFC1035 (lowercase letters, digits, hyphens)."
  type        = string
  default     = "lab-jackhall-dev"
}

variable "apex_dns_name" {
  description = "FQDN of the apex domain. Squarespace already delegates this to Cloud DNS at the registrar (the lab subzone NS were applied at the apex level), so the apex zone has to live here too — without it, queries return REFUSED and Let's Encrypt's CAA walk fails."
  type        = string
  default     = "jackhall.dev"
}

variable "apex_zone_name" {
  description = "Name of the Cloud DNS managed zone resource for the apex. RFC1035."
  type        = string
  default     = "jackhall-dev"
}

variable "apex_caa_issuers" {
  description = "ACME CA hostnames allowed to issue certificates for jackhall.dev and below. Empty list means no CAA record is published and Let's Encrypt falls through to the default-allow. Listing letsencrypt.org makes the cluster's wildcard issuer explicit and blocks any other CA from accidentally issuing for this domain."
  type        = list(string)
  default     = ["letsencrypt.org"]
}

variable "cert_manager_sa_id" {
  description = "Service account ID (the part before @) for the cert-manager DNS-01 solver."
  type        = string
  default     = "cert-manager-dns01"
}

variable "eso_sa_id" {
  description = "Service account ID (the part before @) for External Secrets Operator."
  type        = string
  default     = "external-secrets"
}

variable "tfstate_bucket" {
  description = "Globally-unique name of the GCS bucket holding Terraform state for this and other homelab roots. Must match the `bucket` value hardcoded in the backend block of any root that uses it."
  type        = string
  default     = "rockingham-homelab-tfstate"
}

variable "tfstate_bucket_location" {
  description = "Location for the tfstate bucket. Single region (cheaper) is fine for a homelab."
  type        = string
  default     = "US-CENTRAL1"
}

variable "github_repository" {
  description = "owner/repo of the GitHub repository allowed to impersonate the CI service account via Workload Identity Federation. Locks the WIF provider to a single repo so an OIDC token issued elsewhere cannot reach this project."
  type        = string
  default     = "raptgroup/homelab"
}

variable "tf_ci_sa_id" {
  description = "Service account ID (the part before @) for the plan-only CI service account used by the terraform-plan workflow."
  type        = string
  default     = "tf-ci-plan"
}
