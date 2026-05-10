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
