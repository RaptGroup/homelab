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
  description = "The four NS records to enter at the registrar to delegate the lab subzone to Cloud DNS."
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

output "ci_workload_identity_provider" {
  description = "Full resource name of the GitHub OIDC Workload Identity Provider. Set this as the GCP_WIF_PROVIDER repository variable in GitHub Actions."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "ci_service_account_email" {
  description = "Email of the plan-only CI service account. Set this as the GCP_CI_SA repository variable in GitHub Actions."
  value       = google_service_account.tf_ci.email
}
