variable "project_id" {
  description = "ID of the GCP project that owns the homelab's external resources. Must already exist; see README for the gcloud command to create it."
  type        = string
  default     = "rockingham-homelab"
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
