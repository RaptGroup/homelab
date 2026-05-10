output "project_id" {
  description = "GCP project that owns the homelab's external resources."
  value       = var.project_id
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
