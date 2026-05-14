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

# Bootstrap SA key for ESO. This is the ONLY K8s Secret Terraform creates
# directly — every other credential flows through ESO from GSM.
resource "google_service_account_key" "eso" {
  service_account_id = "projects/${local.project_id}/serviceAccounts/${local.eso_sa_email}"
}

resource "kubernetes_secret" "eso_gcp_sa" {
  metadata {
    name      = "gcp-sm-credentials"
    namespace = kubernetes_namespace.external_secrets.metadata[0].name
  }

  data = {
    "credentials.json" = base64decode(google_service_account_key.eso.private_key)
  }

  type = "Opaque"
}

# Cluster-wide GSM backend. Every ExternalSecret in the cluster references
# this store by name (`gsm`). Project ID is read from terraform/gcp state.
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
            secretRef = {
              secretAccessKeySecretRef = {
                name      = kubernetes_secret.eso_gcp_sa.metadata[0].name
                namespace = kubernetes_secret.eso_gcp_sa.metadata[0].namespace
                key       = "credentials.json"
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
    kubernetes_secret.eso_gcp_sa,
  ]
}
