terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.33"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.16"
    }
    # gavinbunney/kubectl handles raw manifests whose CRDs are created in the
    # same apply (Cilium L2 policies, cert-manager Certificate, ESO
    # ClusterSecretStore, ArgoCD Applications). hashicorp/kubernetes_manifest
    # cannot — it requires the CRD at plan time.
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.19"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }

  # Same bucket as terraform/gcp; different prefix.
  backend "gcs" {
    bucket = "rockingham-homelab-tfstate"
    prefix = "terraform/bootstrap"
  }
}
