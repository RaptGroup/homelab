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
  description = "FQDN of the apex domain. Authoritative DNS for the apex lives in Cloudflare (terraform/cloudflare/), not in this root — this value is exported so terraform/cloudflare/ can read it via terraform_remote_state and locate the CF apex zone."
  type        = string
  default     = "jackhall.dev"
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
  default     = "RaptGroup/homelab"
}

variable "tf_ci_sa_id" {
  description = "Service account ID (the part before @) for the plan-only CI service account used by the terraform-plan workflow."
  type        = string
  default     = "tf-ci-plan"
}

variable "tf_ci_apply_sa_id" {
  description = "Service account ID (the part before @) for the apply CI service account used by the terraform-apply workflow. Holds roles/owner on the project; only impersonable from a workflow job that declares `environment: gcp` (env-scoped via the WIF binding)."
  type        = string
  default     = "tf-ci-apply"
}

variable "ci_apply_environment" {
  description = "GitHub deployment environment name that gates impersonation of the apply SA. The WIF binding restricts impersonation to OIDC tokens whose `environment` claim equals this value, so only workflow jobs that declare `environment: <this>` can mint a token for tf-ci-apply. Convention: environment names mirror Terraform root names (gcp ↔ terraform/gcp/)."
  type        = string
  default     = "gcp"
}

variable "tf_ci_apply_cloudflare_sa_id" {
  description = "Service account ID (the part before @) for the apply CI service account used by the terraform-apply-cloudflare workflow. Narrow secret-scoped + bucket-scoped permissions rather than the project-wide roles/owner that tf-ci-apply carries, because terraform/cloudflare/'s GCP-side surface is just two GSM bindings + state I/O. Only impersonable from a workflow job that declares `environment: cloudflare`."
  type        = string
  default     = "tf-ci-apply-cloudflare"
}

variable "ci_apply_cloudflare_environment" {
  description = "GitHub deployment environment name that gates impersonation of the cloudflare apply SA. Parallel to var.ci_apply_environment, keyed on the second Terraform root. Convention again: environment names mirror Terraform root names (cloudflare ↔ terraform/cloudflare/)."
  type        = string
  default     = "cloudflare"
}

variable "artifact_registry_region" {
  description = "Regional location for the Artifact Registry repository. us-east4 (Ashburn, VA) is geographically closest to the Rockingham homelab — image push from GitHub-hosted runners on the east coast and image pull from the homelab both win on latency vs. the us-central1 default used elsewhere in this root."
  type        = string
  default     = "us-east4"
}

variable "artifact_registry_repository_id" {
  description = "ID of the Docker-format Artifact Registry repository hosting preview-environment images. The repo name matches the preview-env subzone (projects.jackhall.dev) on purpose: image paths and DNS hostnames share the `projects` label, so an operator reading either knows they're looking at the same surface."
  type        = string
  default     = "projects"
}

variable "arc_push_repository_allowlist" {
  description = "GitHub `owner/repo` values whose workflows are allowed to impersonate the Artifact Registry push SA. Must stay a subset of the union of repos selected in the two ARC GitHub App installations (CONTEXT.md → ARC). Each entry gets its own workloadIdentityUser binding keyed on `attribute.repository`, and the dedicated `github-arc` WIF provider's attribute_condition rejects any other repo at the pool boundary — defense in depth so a leaked OIDC token from an unallowed repo cannot mint a push token."
  type        = list(string)
  default = [
    "RaptGroup/homelab",
    "RaptGroup/zipmenu-public",
  ]
}

variable "arc_push_sa_id" {
  description = "Service account ID (the part before @) for the Artifact Registry push SA. roles/artifactregistry.writer scoped to the `projects` repo, not project-wide. Impersonable from any workflow whose `repository` claim is in arc_push_repository_allowlist."
  type        = string
  default     = "tf-ci-arc-push"
}

variable "cluster_pull_sa_id" {
  description = "Service account ID (the part before @) for the in-cluster Artifact Registry pull SA. roles/artifactregistry.reader scoped to the `projects` repo. A JSON key for this SA lives in GSM (container TF-managed here, value uploaded out of band) and is exchanged in-cluster by an ESO GCRAccessToken generator for a short-lived dockerconfigjson — see kubernetes/apps/ar-canary/."
  type        = string
  default     = "tf-ci-cluster-pull"
}

# Note: variables `projects_dns_name` and `projects_zone_nameservers` were
# removed in #126's apex-on-CF refactor (#145). The projects.jackhall.dev
# name space is no longer a separate Cloud DNS or Cloudflare subzone — its
# records live as records inside the CF apex zone, owned by
# terraform/cloudflare/. No NS delegation at this layer.
