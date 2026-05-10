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

resource "kubectl_manifest" "local_path" {
  for_each = data.kubectl_file_documents.local_path.manifests

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

# local-path-provisioner spawns hostPath-using helper pods in its own
# namespace (the upstream Deployment injects POD_NAMESPACE from the
# downward API as metadata.namespace, and the binary uses that for helper
# pod creation — see provisioner.go: `helperPod.Namespace = p.namespace`).
# Helper pods therefore always land in `local-path-storage`, no flags
# needed. But the cluster-default Pod Security admission level is
# `baseline`, which forbids hostPath — so without this label the helper
# pods would be rejected inside local-path-storage itself. Surfaced when
# the first PVC-using addon (AdGuard Home, #28) hit
# `helper-pod-create-pvc-… is forbidden: violates PodSecurity "baseline":
# hostPath volumes`.
#
# Labelling local-path-storage `privileged` lets the helper pod use
# hostPath there while keeping every other namespace at `baseline`.
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

