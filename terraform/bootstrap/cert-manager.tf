resource "kubernetes_namespace" "cert_manager" {
  metadata {
    name = "cert-manager"
  }
}

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  namespace        = kubernetes_namespace.cert_manager.metadata[0].name
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_chart_version
  create_namespace = false
  atomic           = true
  wait             = true
  timeout          = 600

  values = [yamlencode({
    crds = {
      enabled = true
    }
  })]

  # cert-manager itself depends only on Cilium being up. Its ClusterIssuer
  # and Certificate are configured below and additionally wait on ESO so the
  # DNS-01 SA key can be sourced through GSM rather than written by TF.
  depends_on = [
    helm_release.cilium,
  ]
}

# DNS-01 SA key uploaded to GSM, then synced into K8s by ESO. Keeps the "ESO
# SA key is the only TF-managed K8s Secret" rule from ADR-0001 intact.
resource "google_service_account_key" "cert_manager" {
  service_account_id = "projects/${local.project_id}/serviceAccounts/${local.cert_manager_sa_email}"
}

resource "google_secret_manager_secret" "cert_manager_dns01" {
  project   = local.project_id
  secret_id = "cert-manager-dns01-key"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "cert_manager_dns01" {
  secret      = google_secret_manager_secret.cert_manager_dns01.id
  secret_data = base64decode(google_service_account_key.cert_manager.private_key)
}

# ESO syncs the DNS-01 key from GSM into a K8s Secret cert-manager reads.
resource "kubectl_manifest" "cert_manager_dns01_external_secret" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "cert-manager-dns01-key"
      namespace = kubernetes_namespace.cert_manager.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        kind = "ClusterSecretStore"
        name = "gsm"
      }
      target = {
        name           = "cert-manager-dns01-key"
        creationPolicy = "Owner"
      }
      data = [
        {
          secretKey = "credentials.json"
          remoteRef = {
            key = google_secret_manager_secret.cert_manager_dns01.secret_id
          }
        },
      ]
    }
  })

  server_side_apply = true
  force_conflicts   = true

  depends_on = [
    kubectl_manifest.cluster_secret_store_gsm,
    google_secret_manager_secret_version.cert_manager_dns01,
  ]
}

resource "kubectl_manifest" "cluster_issuer_letsencrypt" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt-dns01"
    }
    spec = {
      acme = {
        email  = var.letsencrypt_email
        server = var.letsencrypt_server
        privateKeySecretRef = {
          name = "letsencrypt-dns01-account-key"
        }
        solvers = [
          {
            selector = {
              dnsZones = [var.lab_dns_name]
            }
            dns01 = {
              cloudDNS = {
                project = local.project_id
                # Skip cert-manager's auto-discovery of the hosted zone.
                # That code path calls dns.managedZones.list at project level;
                # our SA holds roles/dns.admin scoped to *this zone* (good for
                # record CRUD) and nothing project-wide, so the list call
                # returns 403 and the challenge never reaches "presented".
                # Naming the zone explicitly drops the list call entirely.
                hostedZoneName = local.lab_zone_name
                serviceAccountSecretRef = {
                  name = "cert-manager-dns01-key"
                  key  = "credentials.json"
                }
              }
            }
          },
        ]
      }
    }
  })

  server_side_apply = true
  force_conflicts   = true

  depends_on = [
    helm_release.cert_manager,
    kubectl_manifest.cert_manager_dns01_external_secret,
  ]
}

# Single cluster-wide wildcard. Gateways in any namespace reference this
# Secret via ReferenceGrant (the Gateway API cross-namespace pattern).
resource "kubectl_manifest" "wildcard_certificate" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = local.wildcard_cert_name
      namespace = kubernetes_namespace.cert_manager.metadata[0].name
    }
    spec = {
      secretName = local.wildcard_secret_name
      issuerRef = {
        name  = "letsencrypt-dns01"
        kind  = "ClusterIssuer"
        group = "cert-manager.io"
      }
      dnsNames = [
        var.lab_dns_name,
        "*.${var.lab_dns_name}",
      ]
    }
  })

  server_side_apply = true
  force_conflicts   = true

  depends_on = [
    kubectl_manifest.cluster_issuer_letsencrypt,
  ]
}
