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

# GitHub deploy-key credential ArgoCD uses to clone the homelab repo.
# Container lives in terraform/gcp (`argocd-repo-ssh-key`); private key is
# uploaded out of band via gcloud. ESO writes a K8s Secret carrying both
# `sshPrivateKey` and the SSH-form `url` — Argo matches Applications to
# this Secret by URL and uses the key automatically.
resource "kubectl_manifest" "argocd_repo_credentials" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "argocd-repo-homelab"
      namespace = kubernetes_namespace.argocd.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        kind = "ClusterSecretStore"
        name = "gsm"
      }
      target = {
        name           = "argocd-repo-homelab"
        creationPolicy = "Owner"
        template = {
          metadata = {
            labels = {
              "argocd.argoproj.io/secret-type" = "repository"
            }
          }
          data = {
            type          = "git"
            url           = var.argocd_repo_url
            sshPrivateKey = "{{ .sshPrivateKey }}"
          }
        }
      }
      data = [
        {
          secretKey = "sshPrivateKey"
          remoteRef = {
            key = "argocd-repo-ssh-key"
          }
        },
      ]
    }
  })

  server_side_apply = true
  force_conflicts   = true

  depends_on = [
    kubectl_manifest.cluster_secret_store_gsm,
    helm_release.argocd,
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

  depends_on = [
    helm_release.argocd,
    kubectl_manifest.argocd_repo_credentials,
  ]
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

  depends_on = [
    helm_release.argocd,
    kubectl_manifest.argocd_repo_credentials,
  ]
}
