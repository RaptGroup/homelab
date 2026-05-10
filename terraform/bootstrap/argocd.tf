resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }
}

locals {
  bootstrap_manifests_dir = "${path.module}/../../kubernetes/bootstrap"
}

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = kubernetes_namespace.argocd.metadata[0].name
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  create_namespace = false
  atomic           = true
  wait             = true
  timeout          = 600

  # Single source of truth for ArgoCD values — also referenced by the
  # self-managed Application via $values, so post-bootstrap edits flow in
  # through Argo without a Terraform run.
  values = [file("${local.bootstrap_manifests_dir}/argocd/values.yaml")]

  depends_on = [
    kubernetes_annotations.local_path_default,
  ]
}

# Self-management Application — Argo manages itself from the same chart and
# values file the bootstrap installed it from.
resource "kubectl_manifest" "argocd_self_managed" {
  yaml_body = templatefile("${local.bootstrap_manifests_dir}/argocd/application.yaml.tftpl", {
    argocd_namespace = kubernetes_namespace.argocd.metadata[0].name
    chart_version    = var.argocd_chart_version
    repo_url         = var.argocd_repo_url
    target_revision  = var.argocd_target_revision
  })

  server_side_apply = true
  force_conflicts   = true

  depends_on = [helm_release.argocd]
}

# Root app-of-apps Application watching kubernetes/apps/. From this point on,
# the cluster grows by dropping new directories under kubernetes/apps/ — no
# Terraform involvement.
resource "kubectl_manifest" "argocd_root" {
  yaml_body = templatefile("${local.bootstrap_manifests_dir}/root.yaml.tftpl", {
    argocd_namespace = kubernetes_namespace.argocd.metadata[0].name
    repo_url         = var.argocd_repo_url
    target_revision  = var.argocd_target_revision
  })

  server_side_apply = true
  force_conflicts   = true

  depends_on = [helm_release.argocd]
}
