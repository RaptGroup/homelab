# local-path-provisioner is the Phase 1 default StorageClass. The upstream
# Helm chart is community-maintained and lags releases; the official YAML
# under deploy/ is the canonical install path.
data "http" "local_path_manifest" {
  url = "https://raw.githubusercontent.com/rancher/local-path-provisioner/${var.local_path_version}/deploy/local-path-storage.yaml"

  request_headers = {
    Accept = "application/yaml"
  }
}

data "kubectl_file_documents" "local_path" {
  content = data.http.local_path_manifest.response_body
}

# The upstream Deployment's command is `local-path-provisioner --debug start
# --config /etc/config/config.json` — without --helper-pod-namespace, the
# provisioner spawns its hostPath-using helper pods in the *consumer's*
# namespace, which trips the cluster-default `baseline` Pod Security
# admission level. Decode each upstream document, append the flag onto the
# provisioner Deployment's command, and re-encode. Every other document
# (RBAC, ConfigMap, ServiceAccount, the namespace itself) flows through
# unchanged.
locals {
  local_path_manifests_patched = {
    for key, body in data.kubectl_file_documents.local_path.manifests :
    key => (
      try(yamldecode(body).kind, "") == "Deployment" &&
      try(yamldecode(body).metadata.name, "") == "local-path-provisioner"
      ) ? yamlencode(merge(yamldecode(body), {
        spec = merge(yamldecode(body).spec, {
          template = merge(yamldecode(body).spec.template, {
            spec = merge(yamldecode(body).spec.template.spec, {
              containers = [
                for c in yamldecode(body).spec.template.spec.containers :
                c.name == "local-path-provisioner"
                ? merge(c, {
                  command = concat(c.command, ["--helper-pod-namespace", "local-path-storage"])
                })
                : c
              ]
            })
          })
        })
    })) : body
  }
}

resource "kubectl_manifest" "local_path" {
  for_each = local.local_path_manifests_patched

  yaml_body         = each.value
  server_side_apply = true
  force_conflicts   = true

  depends_on = [
    helm_release.external_secrets,
  ]
}

# Mark local-path the cluster default. Talos doesn't ship a default
# StorageClass, so there's nothing to unset; the annotation alone is enough.
resource "kubernetes_annotations" "local_path_default" {
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"

  metadata {
    name = "local-path"
  }

  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "true"
  }

  force = true

  depends_on = [
    kubectl_manifest.local_path,
  ]
}

# By default local-path-provisioner spawns its hostPath-using helper pod
# in the *consumer's* namespace, which means every namespace with a PVC
# inherits a hostPath volume — and the cluster's default Pod Security
# admission level (`baseline`) forbids hostPath. Surfaced when the first
# PVC-using addon (AdGuard Home, #28) hit
# `helper-pod-create-pvc-… is forbidden: violates PodSecurity "baseline":
# hostPath volumes`.
#
# Two paired changes keep every other namespace at `baseline`:
#   1. Pin every helper pod to local-path-storage via the provisioner's
#      --helper-pod-namespace flag.
#   2. Label local-path-storage with the `privileged` PSA enforce/audit/
#      warn levels so the helper pod is allowed to use hostPath there.
resource "kubernetes_labels" "local_path_storage_psa" {
  api_version = "v1"
  kind        = "Namespace"

  metadata {
    name = "local-path-storage"
  }

  labels = {
    "pod-security.kubernetes.io/enforce" = "privileged"
    "pod-security.kubernetes.io/audit"   = "privileged"
    "pod-security.kubernetes.io/warn"    = "privileged"
  }

  force = true

  depends_on = [
    kubectl_manifest.local_path,
  ]
}

