resource "kubernetes_namespace" "cert_manager" {
  metadata {
    name = "cert-manager"
  }
}

# external_account credentials JSON consumed by cert-manager's ADC at
# runtime. The controller mounts this ConfigMap as a file and reads it
# via GOOGLE_APPLICATION_CREDENTIALS (set on the controller container in
# the Helm values below); Google's auth library does the STS exchange +
# SA impersonation transparently, so cert-manager's `clouddns` solver
# falls through to ADC with no provider-specific config.
#
# `credential_source.file` points at the projected K8s SA token volume
# mounted on the controller pod. `audience` is the cluster WIF provider's
# full resource name prefixed with `//iam.googleapis.com/` — required by
# GCP STS as the `audience` parameter in the token-exchange request and
# the `aud` claim in the projected JWT. `service_account_impersonation_url`
# names the cert_manager GCP SA: after the STS exchange yields a
# federated principal whose subject is `system:serviceaccount:cert-manager:cert-manager`,
# ADC calls iamcredentials:generateAccessToken to impersonate the cert-
# manager SA — authorized by the workloadIdentityUser binding in
# terraform/gcp/main.tf.
resource "kubectl_manifest" "cert_manager_gcp_credentials" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata = {
      name      = "cert-manager-gcp-credentials"
      namespace = kubernetes_namespace.cert_manager.metadata[0].name
    }
    data = {
      "credentials.json" = jsonencode({
        type                              = "external_account"
        audience                          = local.cluster_wif_audience
        subject_token_type                = "urn:ietf:params:oauth:token-type:jwt"
        token_url                         = "https://sts.googleapis.com/v1/token"
        service_account_impersonation_url = "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${local.cert_manager_sa_email}:generateAccessToken"
        credential_source = {
          file = "/var/run/secrets/tokens/gcp-token"
          format = {
            type = "text"
          }
        }
      })
    }
  })

  server_side_apply = true
  force_conflicts   = true
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

  # Keyless DNS-01: a projected K8s SA token (audience = cluster WIF
  # provider FRN, expires hourly) plus the external_account credentials
  # ConfigMap are mounted on the controller; GOOGLE_APPLICATION_CREDENTIALS
  # points ADC at the credentials JSON, which references the token by
  # path. cert-manager's `clouddns` solver runs against ADC with no
  # provider-specific auth config — same code path GKE Workload Identity
  # exercises, just sourced from a projected token instead of the GKE
  # metadata server. See cert_manager_gcp_credentials above for the JSON
  # shape and terraform/gcp/main.tf for the impersonation binding.
  values = [yamlencode({
    crds = {
      enabled = true
    }
    volumes = [
      {
        name = "gcp-token"
        projected = {
          sources = [
            {
              serviceAccountToken = {
                audience          = local.cluster_wif_audience
                expirationSeconds = 3600
                path              = "gcp-token"
              }
            },
          ]
        }
      },
      {
        name = "gcp-credentials"
        configMap = {
          name = "cert-manager-gcp-credentials"
          items = [
            {
              key  = "credentials.json"
              path = "credentials.json"
            },
          ]
        }
      },
    ]
    volumeMounts = [
      {
        name      = "gcp-token"
        mountPath = "/var/run/secrets/tokens"
        readOnly  = true
      },
      {
        name      = "gcp-credentials"
        mountPath = "/etc/gcp"
        readOnly  = true
      },
    ]
    extraEnv = [
      {
        name  = "GOOGLE_APPLICATION_CREDENTIALS"
        value = "/etc/gcp/credentials.json"
      },
    ]
  })]

  # cert-manager itself depends only on Cilium being up. The DNS-01
  # credentials ConfigMap must exist before the controller pod schedules
  # (the projected-token + configmap volumes are mounted on every
  # controller pod, including the first one Helm waits on with
  # wait=true), so add it as a hard dependency.
  depends_on = [
    helm_release.cilium,
    kubectl_manifest.cert_manager_gcp_credentials,
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
                # No serviceAccountSecretRef — the controller authenticates
                # to Cloud DNS via ADC (projected K8s SA token → GCP STS →
                # cert_manager SA impersonation; see helm_release.cert_manager
                # values and cert_manager_gcp_credentials ConfigMap above).
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
