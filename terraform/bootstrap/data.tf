# Pull the GCP-side outputs (project ID, zone name, SA emails) from the
# terraform/gcp state so they don't have to be passed in by hand.
data "terraform_remote_state" "gcp" {
  backend = "gcs"

  config = {
    bucket = "rockingham-homelab-tfstate"
    prefix = "terraform/gcp"
  }
}

locals {
  project_id            = data.terraform_remote_state.gcp.outputs.project_id
  lab_zone_name         = data.terraform_remote_state.gcp.outputs.lab_zone_name
  cert_manager_sa_email = data.terraform_remote_state.gcp.outputs.cert_manager_sa_email
  eso_sa_email          = data.terraform_remote_state.gcp.outputs.eso_sa_email

  # WIF provider resource name for the cluster pool (ADR-0007). Used as both the
  # STS audience and the kube-apiserver TokenRequest `aud` claim on the
  # projected token ESO mints for the gsm ClusterSecretStore's serviceAccountRef.
  cluster_wif_provider = data.terraform_remote_state.gcp.outputs.cluster_wif_provider
  cluster_wif_audience = "//iam.googleapis.com/${data.terraform_remote_state.gcp.outputs.cluster_wif_provider}"

  # The wildcard cert is per-environment but the secret name is referenced from
  # every Gateway across the cluster — keep it in one place.
  wildcard_cert_name   = "wildcard-lab-jackhall-dev"
  wildcard_secret_name = "wildcard-lab-jackhall-dev-tls"
}
