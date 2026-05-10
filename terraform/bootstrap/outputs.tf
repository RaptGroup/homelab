output "wildcard_cert_secret" {
  description = "Namespace/name of the K8s Secret holding the cluster-wide wildcard cert for *.lab.jackhall.dev. Gateways reference this via ReferenceGrant from their own namespace."
  value       = "${kubernetes_namespace.cert_manager.metadata[0].name}/${local.wildcard_secret_name}"
}

output "argocd_namespace" {
  description = "Namespace ArgoCD runs in. Used by the operator to port-forward the UI on first run before a Gateway is configured."
  value       = kubernetes_namespace.argocd.metadata[0].name
}

output "argocd_initial_admin_secret" {
  description = "Name of the K8s Secret holding the ArgoCD initial admin password (in the argocd namespace). The operator reads this once, logs in, and rotates."
  value       = "argocd-initial-admin-secret"
}

output "default_storage_class" {
  description = "Name of the StorageClass marked default after bootstrap."
  value       = "local-path"
}

output "lb_pool_range" {
  description = "Inclusive IP range allocated to LoadBalancer services by Cilium."
  value       = "${var.lb_pool_start}-${var.lb_pool_end}"
}
