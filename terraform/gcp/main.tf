provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  required_apis = [
    # serviceusage is the API that tofu itself calls to read/manage every
    # other google_project_service resource. It must be enabled before any
    # plan or apply that authenticates via a SA whose quota project is this
    # project (CI does — local ADC usually routes quota through the user's
    # personal default project, which masks this in dev). On a fresh GCP
    # account, enable it once by hand:
    #   gcloud services enable serviceusage.googleapis.com \
    #     --project=rockingham-homelab
    "serviceusage.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "dns.googleapis.com",
    "secretmanager.googleapis.com",
    "storage.googleapis.com",
  ]
}

# The whole homelab GCP footprint is a single project so it can be torn
# down atomically. deletion_policy = "DELETE" overrides the v6 provider
# default of PREVENT so `tofu destroy` actually destroys.
resource "google_project" "lab" {
  name                = var.project_name
  project_id          = var.project_id
  billing_account     = var.billing_account
  org_id              = var.org_id
  folder_id           = var.folder_id
  auto_create_network = false
  deletion_policy     = "DELETE"
}

resource "google_project_service" "enabled" {
  for_each = toset(local.required_apis)

  project            = google_project.lab.project_id
  service            = each.value
  disable_on_destroy = false
}

# Public managed zone delegated from the registrar via NS records on the
# parent jackhall.dev zone. cert-manager creates ACME TXT records here.
resource "google_dns_managed_zone" "lab" {
  project     = google_project.lab.project_id
  name        = var.lab_zone_name
  dns_name    = "${var.lab_dns_name}."
  description = "Rockingham Homelab — public subzone for lab.jackhall.dev (split-horizon: this side holds only ACME challenges and any genuinely public records)."
  visibility  = "public"

  depends_on = [google_project_service.enabled]
}

# cert-manager DNS-01 solver. Scoped to the lab zone, not project-wide.
resource "google_service_account" "cert_manager" {
  project      = google_project.lab.project_id
  account_id   = var.cert_manager_sa_id
  display_name = "cert-manager DNS-01 solver"
  description  = "Used by cert-manager in the homelab cluster to solve Let's Encrypt DNS-01 challenges against the lab.jackhall.dev zone."

  depends_on = [google_project_service.enabled]
}

resource "google_dns_managed_zone_iam_member" "cert_manager_dns_admin" {
  project      = google_project.lab.project_id
  managed_zone = google_dns_managed_zone.lab.name
  role         = "roles/dns.admin"
  member       = "serviceAccount:${google_service_account.cert_manager.email}"
}

# External Secrets Operator. Project-scoped accessor — individual secrets
# are created later (out of band or by the bootstrap layer) and this SA
# can read all of them without a per-secret IAM resource.
resource "google_service_account" "eso" {
  project      = google_project.lab.project_id
  account_id   = var.eso_sa_id
  display_name = "External Secrets Operator"
  description  = "Used by ESO in the homelab cluster to read secrets from Google Secret Manager."

  depends_on = [google_project_service.enabled]
}

resource "google_project_iam_member" "eso_secret_accessor" {
  project = google_project.lab.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.eso.email}"
}

# Terraform state lives here. GCS backend uses object generations for
# native state locking — no separate lock table needed (unlike S3+Dynamo).
resource "google_storage_bucket" "tfstate" {
  project  = google_project.lab.project_id
  name     = var.tfstate_bucket
  location = var.tfstate_bucket_location

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 10
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      days_since_noncurrent_time = 30
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.enabled]
}

# --- CI: Workload Identity Federation for GitHub Actions ---------------------
#
# The terraform-plan workflow (.github/workflows/terraform-plan.yml) runs on
# GitHub-hosted runners and authenticates to GCP via OIDC instead of a
# long-lived JSON key. The pieces:
#
#   1. A pool that trusts GitHub's OIDC issuer.
#   2. A provider in that pool, with an attribute_condition locking the trust
#      to ${var.github_repository} so an OIDC token issued for any other repo
#      is rejected before it can reach the SA.
#   3. A plan-only service account with project-scoped roles/viewer — enough
#      to read state and the current resource graph, structurally insufficient
#      to apply changes.
#   4. A workloadIdentityUser binding allowing the GitHub repo (any branch,
#      any actor) to impersonate (3).

resource "google_iam_workload_identity_pool" "github_actions" {
  project                   = google_project.lab.project_id
  workload_identity_pool_id = "github-actions"
  display_name              = "GitHub Actions"
  description               = "OIDC pool trusted by GitHub Actions runners; per-repo trust is enforced on the provider, not the pool."

  depends_on = [google_project_service.enabled]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = google_project.lab.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github_actions.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub OIDC"
  description                        = "Trusts GitHub-issued OIDC tokens; locked to ${var.github_repository}."

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
    "attribute.actor"      = "assertion.actor"
  }

  attribute_condition = "assertion.repository == \"${var.github_repository}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# Plan-only. roles/viewer covers everything `tofu plan` needs to read across
# the project (DNS, IAM, Storage objects in the tfstate bucket, project
# metadata) and is intentionally insufficient to mutate anything. Apply
# remains operator-only on a workstation with ADC.
resource "google_service_account" "tf_ci" {
  project      = google_project.lab.project_id
  account_id   = var.tf_ci_sa_id
  display_name = "Terraform CI plan-only"
  description  = "Used by .github/workflows/terraform-plan.yml. Project-scoped roles/viewer; cannot apply."

  depends_on = [google_project_service.enabled]
}

resource "google_project_iam_member" "tf_ci_viewer" {
  project = google_project.lab.project_id
  role    = "roles/viewer"
  member  = "serviceAccount:${google_service_account.tf_ci.email}"
}

resource "google_service_account_iam_member" "tf_ci_wif_user" {
  service_account_id = google_service_account.tf_ci.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_actions.name}/attribute.repository/${var.github_repository}"
}
