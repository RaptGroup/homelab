output "project_id" {
  description = "GCP project that owns the homelab's external resources."
  value       = google_project.lab.project_id
}

output "project_number" {
  description = "Numeric project number (some IAM bindings and APIs want this rather than the ID)."
  value       = google_project.lab.number
}

output "lab_zone_name" {
  description = "Cloud DNS managed-zone resource name."
  value       = google_dns_managed_zone.lab.name
}

output "lab_zone_dns_name" {
  description = "FQDN of the lab subzone (with trailing dot, as Cloud DNS reports it)."
  value       = google_dns_managed_zone.lab.dns_name
}

output "lab_zone_name_servers" {
  description = "The four NS records that authoritatively serve lab.jackhall.dev. Encoded inside the apex zone's delegation already — no registrar change is needed for the subzone."
  value       = google_dns_managed_zone.lab.name_servers
}

output "cert_manager_sa_email" {
  description = "Service account email consumed by cert-manager's DNS-01 solver."
  value       = google_service_account.cert_manager.email
}

output "eso_sa_email" {
  description = "Service account email consumed by External Secrets Operator."
  value       = google_service_account.eso.email
}

output "tfstate_bucket" {
  description = "Name of the GCS bucket holding Terraform state for the homelab's TF roots."
  value       = google_storage_bucket.tfstate.name
}

output "talos_cluster_secrets_id" {
  description = "GSM secret ID holding talos/_out/secrets.yaml backups. Versions are uploaded out of band; see talos/README.md."
  value       = google_secret_manager_secret.talos_cluster_secrets.secret_id
}

output "argocd_repo_ssh_key_id" {
  description = "GSM secret ID holding the SSH private key for the GitHub deploy key ArgoCD uses to clone the homelab repo. Versions are uploaded out of band."
  value       = google_secret_manager_secret.argocd_repo_ssh_key.secret_id
}

output "adguard_home_admin_secret_id" {
  description = "GSM secret ID holding the AdGuard Home admin user/bcrypt-hash. Versions are uploaded out of band; see kubernetes/apps/adguard-home/README.md."
  value       = google_secret_manager_secret.adguard_home_admin.secret_id
}

output "homepage_adguard_username_secret_id" {
  description = "GSM secret ID holding the plaintext AdGuard admin username consumed by Homepage's AdGuard widget. Versions are uploaded out of band; see kubernetes/apps/homepage/README.md."
  value       = google_secret_manager_secret.homepage_adguard_username.secret_id
}

output "homepage_adguard_password_secret_id" {
  description = "GSM secret ID holding the plaintext AdGuard admin password consumed by Homepage's AdGuard widget. Same password as adguard-home-admin (which stores its bcrypt hash). Versions are uploaded out of band; see kubernetes/apps/homepage/README.md."
  value       = google_secret_manager_secret.homepage_adguard_password.secret_id
}

output "homepage_argocd_token_secret_id" {
  description = "GSM secret ID holding the ArgoCD readonly API token consumed by Homepage's ArgoCD widget. Versions are uploaded out of band; see kubernetes/apps/homepage/README.md."
  value       = google_secret_manager_secret.homepage_argocd_token.secret_id
}

output "ci_workload_identity_provider" {
  description = "Full resource name of the GitHub OIDC Workload Identity Provider. Set this as the GCP_WIF_PROVIDER repository variable in GitHub Actions."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "ci_service_account_email" {
  description = "Email of the plan-only CI service account. Set this as the GCP_CI_SA repository variable in GitHub Actions."
  value       = google_service_account.tf_ci.email
}

output "ci_apply_service_account_email" {
  description = "Email of the apply CI service account (roles/owner, env-scoped WIF). Set this as the GCP_APPLY_SA repository variable in GitHub Actions."
  value       = google_service_account.tf_ci_apply.email
}

output "ci_apply_cloudflare_service_account_email" {
  description = "Email of the cloudflare-root apply CI service account (narrow secret-scoped + bucket-scoped, env-scoped WIF on `cloudflare`). Set this as the GCP_APPLY_SA_CLOUDFLARE repository variable in GitHub Actions."
  value       = google_service_account.tf_ci_apply_cloudflare.email
}

output "artifact_registry_repository_url" {
  description = "Hostname-qualified URL of the preview-env Artifact Registry repository, used as the image-path prefix from both ARC pushes and cluster pulls. Full image paths look like `<this>/<workload>:<tag>`."
  value       = "${google_artifact_registry_repository.projects.location}-docker.pkg.dev/${google_project.lab.project_id}/${google_artifact_registry_repository.projects.repository_id}"
}

output "arc_push_service_account_email" {
  description = "Email of the Artifact Registry push SA. Set as the GCP_ARC_PUSH_SA Actions repository variable so ARC workflows can pass it to google-github-actions/auth."
  value       = google_service_account.arc_push.email
}

output "arc_workload_identity_provider" {
  description = "Full resource name of the GitHub OIDC provider scoped to the ARC repository allowlist. Set as the GCP_ARC_WIF_PROVIDER Actions repository variable so ARC workflows can pass it to google-github-actions/auth."
  value       = google_iam_workload_identity_pool_provider.github_arc.name
}

output "cluster_pull_service_account_email" {
  description = "Email of the in-cluster Artifact Registry pull SA. Referenced by the GCRAccessToken generator under kubernetes/apps/ar-canary/ as the impersonation target after the cluster WIF token exchange."
  value       = google_service_account.cluster_pull.email
}

output "cluster_oidc_issuer" {
  description = "Public URL serving the cluster's OIDC discovery document + JWKS. Configured as kube-apiserver's --service-account-issuer in talos/patches/cluster/oidc-issuer.yaml."
  value       = local.cluster_oidc_issuer
}

output "cluster_oidc_bucket" {
  description = "Name of the GCS bucket fronting the cluster's OIDC issuer. Operator uploads the cluster's JWKS to gs://<bucket>/openid/v1/jwks after every Talos secret rotation; see talos/README.md."
  value       = google_storage_bucket.cluster_oidc.name
}

output "cluster_wif_provider" {
  description = "Full resource name of the cluster's OIDC WIF provider. Plugged into kubernetes/apps/ar-canary/manifests/gcr-access-token.yaml as the STS audience for the projected K8s SA token exchange."
  value       = google_iam_workload_identity_pool_provider.cluster_talos.name
}

output "cloudflare_api_token_secret_id" {
  description = "GSM secret ID holding the operator-minted Cloudflare API token consumed by terraform/cloudflare/. Versions are uploaded out of band (see terraform/cloudflare/README.md)."
  value       = google_secret_manager_secret.cloudflare_api_token.secret_id
}

output "cloudflare_tunnel_token_secret_id" {
  description = "GSM secret ID holding the per-tunnel cloudflared connector token. Versions are written by terraform/cloudflare/; the cloudflared addon's ExternalSecret consumes this name."
  value       = google_secret_manager_secret.cloudflare_tunnel_token.secret_id
}

output "apex_dns_name" {
  description = "FQDN of the apex `jackhall.dev` (without trailing dot). Consumed by terraform/cloudflare/ via terraform_remote_state to look up the CF apex zone."
  value       = var.apex_dns_name
}
