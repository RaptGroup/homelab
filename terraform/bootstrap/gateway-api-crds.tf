# Gateway API CRDs (HTTPRoute and friends). Must be applied before Cilium so
# cilium-operator finds the CRDs at startup and accepts its GatewayClass.
#
# Experimental channel, not standard: cilium-operator's gateway-api
# controller probes the API surface for *all* required GVKs at startup
# (gatewayclasses, gateways, httproutes, grpcroutes, referencegrants, plus
# tlsroutes — only present in the experimental channel) and refuses to
# register its GatewayClass when any are missing. With standard-install
# the controller logs `tlsroutes... not found` and the GatewayClass
# stays at `Accepted=Unknown / Waiting for controller`.
#
# Installing the experimental CRD does not contradict ADR-0002's
# "HTTPRoute only" stance — that decision is about which Gateway API
# kinds we *use*, not which CRDs sit unused on the API server.
data "http" "gateway_api_crds" {
  url = "https://github.com/kubernetes-sigs/gateway-api/releases/download/${var.gateway_api_version}/experimental-install.yaml"

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
