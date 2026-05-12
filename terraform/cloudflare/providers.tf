provider "google" {
  project = local.project_id
}

# The API token comes from GSM — never an environment variable or a local
# file. A leaked workstation login (gcloud ADC) only reaches the token via
# GSM IAM (roles/secretmanager.secretAccessor on the operator's identity),
# not through a $HOME/.cloudflare/* path that ad-hoc commands might grep.
provider "cloudflare" {
  api_token = data.google_secret_manager_secret_version_access.cloudflare_api_token.secret_data
}
