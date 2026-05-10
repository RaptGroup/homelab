# Gateway API CRDs (HTTPRoute and friends). Standard channel only —
# experimental channel pulls in TLSRoute and friends that ADR-0002 explicitly
# leaves disabled. Must be applied before Cilium so cilium-operator finds the
# CRDs at startup and registers its GatewayClass.
data "http" "gateway_api_crds" {
  url = "https://github.com/kubernetes-sigs/gateway-api/releases/download/${var.gateway_api_version}/standard-install.yaml"

  request_headers = {
    Accept = "application/yaml"
  }
}

data "kubectl_file_documents" "gateway_api_crds" {
  content = data.http.gateway_api_crds.response_body
}

resource "kubectl_manifest" "gateway_api_crds" {
  for_each = data.kubectl_file_documents.gateway_api_crds.manifests

  yaml_body         = each.value
  server_side_apply = true
  # CRD upgrades change the schema in place; force conflicts so re-applies
  # don't fail when the upstream Gateway API release bumps a field.
  force_conflicts = true
}
