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
