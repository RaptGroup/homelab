variable "kubeconfig_path" {
  description = "Path to the Talos-issued kubeconfig used by the kubernetes/helm/kubectl providers. Default points at the conventional talos/_out location."
  type        = string
  default     = "../../talos/_out/kubeconfig"
}

variable "kube_context" {
  description = "Optional kubeconfig context to use. Leave empty to use the file's current-context."
  type        = string
  default     = ""
}

variable "lab_dns_name" {
  description = "FQDN of the lab subzone served by Cloud DNS. Must match terraform/gcp's value."
  type        = string
  default     = "lab.jackhall.dev"
}

variable "letsencrypt_email" {
  description = "Contact email registered with Let's Encrypt for issuance + expiry notices. The default is the homelab operator; override in terraform.tfvars if a different mailbox should receive expiry warnings."
  type        = string
  default     = "jackvincenthall@gmail.com"
}

variable "letsencrypt_server" {
  description = "Let's Encrypt ACME directory URL. Defaults to production; override with the staging URL for first-run smoke tests."
  type        = string
  default     = "https://acme-v02.api.letsencrypt.org/directory"
}

variable "lb_pool_start" {
  description = "First IP in the CiliumLoadBalancerIPPool range. Sits above the Optimum DHCP scope and the static cluster range."
  type        = string
  default     = "192.168.1.200"
}

variable "lb_pool_end" {
  description = "Last IP in the CiliumLoadBalancerIPPool range."
  type        = string
  default     = "192.168.1.230"
}

variable "control_plane_node_selector" {
  description = "Label key used to identify Talos control-plane nodes for L2-announcement exclusion. Matches the Talos default."
  type        = string
  default     = "node-role.kubernetes.io/control-plane"
}

variable "argocd_repo_url" {
  description = "Git repository ArgoCD reads bootstrap manifests from (the root app-of-apps and the self-managed argocd Application). SSH form is used so ArgoCD always authenticates via the deploy key — synced from GSM by ESO into a labelled `repository` Secret in the argocd namespace, identical to every other ESO-from-GSM credential in this bootstrap — keeping the credential path exercised end-to-end."
  type        = string
  default     = "git@github.com:RaptGroup/homelab.git"
}

variable "argocd_target_revision" {
  description = "Git revision (branch, tag, or commit) ArgoCD tracks for bootstrap and app-of-apps Applications."
  type        = string
  default     = "main"
}

# --- Chart / manifest version pins ----------------------------------------

variable "gateway_api_version" {
  description = "Tag (with leading v) of kubernetes-sigs/gateway-api whose standard-install.yaml is applied. Must be supported by the chosen Cilium version."
  type        = string
  default     = "v1.2.0"
}

variable "cilium_chart_version" {
  description = "Cilium Helm chart version (matches the Cilium minor)."
  type        = string
  default     = "1.16.5"
}

variable "cert_manager_chart_version" {
  description = "cert-manager Helm chart version."
  type        = string
  default     = "v1.16.2"
}

variable "external_secrets_chart_version" {
  description = "external-secrets Helm chart version."
  type        = string
  default     = "0.10.7"
}

variable "argocd_chart_version" {
  description = "argo-cd Helm chart version (Argo Helm chart, not the Argo CD app version it ships)."
  type        = string
  default     = "9.5.13"
}

variable "local_path_version" {
  description = "Tag (with leading v) of rancher/local-path-provisioner whose deploy/local-path-storage.yaml is applied."
  type        = string
  default     = "v0.0.32"
}
