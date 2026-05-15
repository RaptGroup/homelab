resource "kubernetes_namespace" "external_secrets" {
  metadata {
    name = "external-secrets"
  }
}

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  namespace        = kubernetes_namespace.external_secrets.metadata[0].name
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = var.external_secrets_chart_version
  create_namespace = false
  atomic           = true
  wait             = true
  timeout          = 600

  values = [yamlencode({
    installCRDs = true
  })]

  # cert-manager comes before ESO in the issue's stated order, but ESO has no
  # runtime dep on cert-manager — and we want ESO up before the cert-manager
  # ClusterIssuer so the DNS-01 SA key can be sourced from GSM via ESO
  # rather than created directly by Terraform.
  depends_on = [
    helm_release.cert_manager,
  ]
}

# Workload-identity principal for the gsm ClusterSecretStore (ADR-0007).
# ESO mints a projected token for this ServiceAccount with `aud` set to
# the cluster WIF provider's full resource name, POSTs it to GCP STS to
# get a federated access token, then impersonates the `external-secrets`
# GCP SA (authorized by the workloadIdentityUser binding in
# terraform/gcp/main.tf → `eso_wif_user`) to read GSM.
#
# The `iam.gke.io/gcp-service-account` annotation is the well-known
# convention ESO's workloadIdentityFederation reader uses on
# external-secrets-chart v2.4.1 to decide which GCP SA to impersonate
# after the STS exchange (the inline `gcpServiceAccountEmail` field was
# added upstream on 2026-05-13 and is not yet in v2.4.1; revisit on the
# next ESO bump and collapse this annotation into the CSS auth block).
# Parallel to kubernetes/apps/ar-canary/manifests/serviceaccount.yaml,
# which exercises the same shape for the AR-pull path.
#
# Terraform no longer creates any K8s Secret directly — ESO authenticates
# via WIF, every other credential flows through ESO from GSM.
resource "kubernetes_service_account" "eso_gsm" {
  metadata {
    name      = "external-secrets-gsm"
    namespace = kubernetes_namespace.external_secrets.metadata[0].name
    annotations = {
      "iam.gke.io/gcp-service-account" = local.eso_sa_email
    }
  }

  depends_on = [
    helm_release.external_secrets,
  ]
}

# Cluster-wide GSM backend. Every ExternalSecret in the cluster references
# this store by name (`gsm`). Project ID is read from terraform/gcp state.
# Auth uses workloadIdentityFederation against the cluster's own OIDC
# issuer (ADR-0007) — no JSON key anywhere on the bootstrap path.
resource "kubectl_manifest" "cluster_secret_store_gsm" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ClusterSecretStore"
    metadata = {
      name = "gsm"
    }
    spec = {
      provider = {
        gcpsm = {
          projectID = local.project_id
          auth = {
            workloadIdentityFederation = {
              # The STS exchange's `audience` parameter and the projected
              # token's `aud` claim must both equal the WIF provider's
              # full resource name — GCP STS rejects the exchange otherwise.
              audience = local.cluster_wif_audience
              serviceAccountRef = {
                name      = kubernetes_service_account.eso_gsm.metadata[0].name
                namespace = kubernetes_service_account.eso_gsm.metadata[0].namespace
                audiences = [local.cluster_wif_audience]
              }
            }
          }
        }
      }
    }
  })

  server_side_apply = true
  force_conflicts   = true

  depends_on = [
    helm_release.external_secrets,
    kubernetes_service_account.eso_gsm,
  ]
}
