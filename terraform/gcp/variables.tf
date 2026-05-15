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

variable "cert_manager_k8s_namespace" {
  description = "Kubernetes namespace whose ServiceAccount is allowed to impersonate cert-manager-dns01 through the cluster's WIF. The cert-manager Helm release runs in `cert-manager`; the controller's projected SA token is the input to the GCP STS exchange that yields a federated principal authorized to impersonate the cert_manager GCP SA."
  type        = string
  default     = "cert-manager"
}

variable "cert_manager_k8s_sa" {
  description = "Kubernetes ServiceAccount name (inside cert_manager_k8s_namespace) whose projected token is exchanged for cert-manager-dns01 credentials. Must match the controller SA the cert-manager chart renders — the Jetstack chart's `cert-manager.fullname` template resolves to `cert-manager` when both Release.Name and Chart.Name are `cert-manager`, which is the case in terraform/bootstrap/cert-manager.tf."
  type        = string
  default     = "cert-manager"
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
  description = "Service account ID (the part before @) for the in-cluster Artifact Registry pull SA. roles/artifactregistry.reader scoped to the `projects` repo. Impersonated from in-cluster Pods via the cluster's Workload Identity Federation pool — no JSON key. See kubernetes/apps/ar-canary/."
  type        = string
  default     = "tf-ci-cluster-pull"
}

variable "cluster_oidc_bucket" {
  description = "Globally-unique GCS bucket serving the cluster's OIDC discovery document + JWKS. The bucket name is baked into the issuer URL `https://storage.googleapis.com/<bucket>`, which is in turn baked into Talos's --service-account-issuer; renaming requires a coordinated cluster + IAM rollout, so default-and-leave."
  type        = string
  default     = "rockingham-homelab-oidc"
}

variable "cluster_oidc_bucket_location" {
  description = "Location for the OIDC bucket. Single region (cheaper). The bucket holds two static objects under 10 KiB combined; latency is irrelevant."
  type        = string
  default     = "US-CENTRAL1"
}

variable "cluster_wif_pool_id" {
  description = "WIF pool ID dedicated to the Talos cluster. Separate from `github-actions` so the pool boundary advertises the identity source — GitHub OIDC for the push path, the cluster's own OIDC for the pull path."
  type        = string
  default     = "cluster"
}

variable "cluster_wif_provider_id" {
  description = "WIF provider ID inside the cluster pool. `talos` to advertise the source of the JWTs."
  type        = string
  default     = "talos"
}

variable "cluster_pull_k8s_namespace" {
  description = "Kubernetes namespace whose ServiceAccount is allowed to impersonate tf-ci-cluster-pull through the cluster's WIF. Narrow on purpose — the ar-canary slice is the only consumer until the preview-env baseline templates a per-preview puller SA in. At that point this binding is widened (or replaced with a principalSet on attribute.namespace) to cover the preview-* namespace pattern."
  type        = string
  default     = "ar-canary"
}

variable "cluster_pull_k8s_sa" {
  description = "Kubernetes ServiceAccount name (inside cluster_pull_k8s_namespace) whose projected token is exchanged for tf-ci-cluster-pull credentials. Must match the SA created in kubernetes/apps/ar-canary/manifests/serviceaccount.yaml."
  type        = string
  default     = "ar-canary-puller"
}

variable "eso_k8s_namespace" {
  description = "Kubernetes namespace whose ServiceAccount is allowed to impersonate the `external-secrets` GCP SA through the cluster's WIF (ADR-0007). Must match the namespace the External Secrets Operator Helm chart is installed in by terraform/bootstrap/."
  type        = string
  default     = "external-secrets"
}

variable "eso_k8s_sa" {
  description = "Kubernetes ServiceAccount name (inside eso_k8s_namespace) whose projected token is exchanged for the `external-secrets` GCP SA's credentials at bootstrap time. Must match the kubernetes_service_account created in terraform/bootstrap/external-secrets.tf and referenced from the `gsm` ClusterSecretStore's serviceAccountRef."
  type        = string
  default     = "external-secrets-gsm"
}

variable "longhorn_backup_sa_id" {
  description = "Service account ID (the part before @) for the Longhorn backup-target SA. roles/storage.objectAdmin scoped to the longhorn-backups bucket only — a leak cannot reach any other bucket or object in the project. The SA's HMAC key (minted out of band; see terraform/gcp/README.md) is what Longhorn uses to authenticate against the GCS S3 interoperability API."
  type        = string
  default     = "longhorn-backup"
}

variable "longhorn_backups_bucket" {
  description = "Globally-unique name of the GCS bucket holding Longhorn off-site backups. Longhorn writes through the S3 interoperability API; the bucket's name is the `<bucket>` part of the `s3://<bucket>@<region>/` URL Longhorn's backupTarget setting consumes."
  type        = string
  default     = "rockingham-longhorn-backups"
}

variable "longhorn_backups_bucket_location" {
  description = "Location for the longhorn-backups bucket. us-east4 (Ashburn, VA) mirrors the artifact-registry region choice — closest of the four US GCP regions to the Rockingham homelab, which is where the bytes travel from. Single region rather than multi-region: backups are recoverable, not transactional, so the multi-region durability premium isn't worth the cost. Must match the `<region>` in kubernetes/apps/longhorn/helm-values.yaml's `backupTarget` URL (lowercase form)."
  type        = string
  default     = "US-EAST4"
}

# Note: variables `projects_dns_name` and `projects_zone_nameservers` were
# removed in #126's apex-on-CF refactor (#145). The projects.jackhall.dev
# name space is no longer a separate Cloud DNS or Cloudflare subzone — its
# records live as records inside the CF apex zone, owned by
# terraform/cloudflare/. No NS delegation at this layer.
