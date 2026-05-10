provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  required_apis = [
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
