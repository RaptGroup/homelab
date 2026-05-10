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

# Apex `jackhall.dev` zone. Squarespace's nameserver field for the domain
# already points at Cloud DNS (the lab subzone NS got applied at the apex
# level when the user delegated), so the apex *has* to live in Cloud DNS
# too — otherwise the assigned ns-cloud-* nameservers return REFUSED for
# anything at the apex and Let's Encrypt's CAA walk SERVFAILs while
# trying to issue `*.lab.jackhall.dev` (the walk goes
# `*.lab.jackhall.dev` → `lab.jackhall.dev` → `jackhall.dev` → `dev`).
#
# This zone holds only what the apex genuinely needs — an SOA/NS pair
# (auto-managed by Cloud DNS), the explicit CAA permitting Let's Encrypt,
# and an in-bailiwick NS record delegating `lab.jackhall.dev` to the
# subzone below. No A/AAAA at the apex; the homelab does not host
# anything at `jackhall.dev` itself.
resource "google_dns_managed_zone" "apex" {
  project     = google_project.lab.project_id
  name        = var.apex_zone_name
  dns_name    = "${var.apex_dns_name}."
  description = "Rockingham Homelab — apex jackhall.dev. Holds the CAA record for Let's Encrypt and the NS delegation for lab.jackhall.dev. Squarespace must point the registrar nameserver field at this zone's name_servers."
  visibility  = "public"

  depends_on = [google_project_service.enabled]
}

# CAA at the apex. Without this, LE's CAA lookup at every level above
# `*.lab.jackhall.dev` (`lab.jackhall.dev`, `jackhall.dev`, `dev`) finds
# nothing and falls through to the default-allow — that already works
# once the apex resolves at all. The explicit record is defense in depth:
# any future certificate issued for jackhall.dev or below has to go
# through Let's Encrypt.
resource "google_dns_record_set" "apex_caa" {
  project      = google_project.lab.project_id
  managed_zone = google_dns_managed_zone.apex.name
  name         = google_dns_managed_zone.apex.dns_name
  type         = "CAA"
  ttl          = 300

  rrdatas = concat(
    [for issuer in var.apex_caa_issuers : "0 issue \"${issuer}\""],
    [for issuer in var.apex_caa_issuers : "0 issuewild \"${issuer}\""],
  )
}

# Delegation NS for the lab subzone. With both apex and lab in Cloud DNS
# this is technically redundant for resolution (whichever ns-cloud-* the
# resolver hits already serves both zones), but standard practice — and
# it's what makes the lab subzone delegation visible in `dig +trace`.
resource "google_dns_record_set" "apex_lab_delegation" {
  project      = google_project.lab.project_id
  managed_zone = google_dns_managed_zone.apex.name
  name         = google_dns_managed_zone.lab.dns_name
  type         = "NS"
  ttl          = 21600

  rrdatas = google_dns_managed_zone.lab.name_servers
}

# Public managed zone delegated from the apex via the NS record above.
# cert-manager creates ACME TXT records here.
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

# --- Talos cluster secrets backup --------------------------------------------
#
# Container only. The cluster CA private key, etcd bootstrap token, and
# friends inside talos/_out/secrets.yaml are the one irreplaceable file
# in the lab — losing them means rebuilding the cluster from scratch.
#
# The secret VALUE is uploaded out of band via gcloud, deliberately:
# pulling it through TF would land it in the GCS-backed state file,
# doubling the surface, and any operator without a local secrets.yaml
# would either need a CI-plumbed env var or trigger a spurious
# "version will be destroyed" diff. The TF-managed container plus a
# manual `gcloud secrets versions add` keeps state idempotent and the
# value's provenance honest. See talos/README.md for the upload and
# restore commands.
resource "google_secret_manager_secret" "talos_cluster_secrets" {
  project   = google_project.lab.project_id
  secret_id = "talos-cluster-secrets"

  labels = {
    purpose  = "cluster-management"
    rotation = "talosctl-gen-secrets"
  }

  replication {
    auto {}
  }

  depends_on = [google_project_service.enabled]
}

# --- ArgoCD: GitHub deploy key for the homelab repo --------------------------
#
# Container only, same rationale as talos-cluster-secrets above. The
# matching public half is registered as a read-only deploy key on
# RaptGroup/homelab. The repo is currently public, so authenticated clones
# are not strictly required today — the SSH path is retained as
# forward-compat with any future private repo (e.g. a temporarily-private
# fork during an incident, or a separate secrets repo), and to keep
# bootstrap exercising the full ESO-from-GSM credential path end-to-end as
# a smoke test on a fresh project. ESO syncs the private key into a K8s
# Secret in the argocd namespace labelled
# `argocd.argoproj.io/secret-type: repository`; the SSH URL match means
# Argo applies it to every Application whose `repoURL` is the SSH form.
#
# Upload (after `tofu apply` here):
#   gcloud secrets versions add argocd-repo-ssh-key \
#     --project=rockingham-homelab \
#     --data-file=<path-to-private-key>
resource "google_secret_manager_secret" "argocd_repo_ssh_key" {
  project   = google_project.lab.project_id
  secret_id = "argocd-repo-ssh-key"

  labels = {
    purpose  = "gitops"
    rotation = "manual"
  }

  replication {
    auto {}
  }

  depends_on = [google_project_service.enabled]
}

# --- Per-addon credential containers -----------------------------------------
#
# One GSM container per addon that needs an out-of-band credential. The
# container is TF-managed (so the addon's ExternalSecret can reference a
# stable name on a fresh GCP project), the value is uploaded out of band
# via `gcloud secrets versions add`. Same rationale as
# talos-cluster-secrets above: keeping plaintext or hashed credentials
# out of TF state.

# AdGuard Home admin user. JSON object with `username` and `password_hash`
# (bcrypt). Generate the hash locally with:
#
#   htpasswd -nbB admin '<password>' | cut -d: -f2
#
# then upload:
#
#   echo '{"username":"admin","password_hash":"<hash>"}' \
#     | gcloud secrets versions add adguard-home-admin \
#         --project rockingham-homelab --data-file=-
#
# The seed-config init container in kubernetes/apps/adguard-home reads
# the bcrypt hash and renders /opt/adguardhome/conf/AdGuardHome.yaml on
# first boot; AdGuard Home loads the user without going through the
# setup wizard.
resource "google_secret_manager_secret" "adguard_home_admin" {
  project   = google_project.lab.project_id
  secret_id = "adguard-home-admin"

  labels = {
    purpose = "addon-credential"
    addon   = "adguard-home"
  }

  replication {
    auto {}
  }

  depends_on = [google_project_service.enabled]
}

# Homepage live-status widget credentials. Three plaintext containers
# pulled by the homepage-widget-credentials ExternalSecret in
# kubernetes/apps/homepage/manifests/external-secret.yaml and surfaced as
# HOMEPAGE_VAR_* env vars on the Homepage Deployment.
#
# homepage-adguard-{username,password} hold the *plaintext* of the same
# admin credential whose bcrypt hash lives in adguard-home-admin — both
# must point at the same actual password. Homepage's AdGuard widget
# authenticates against the live admin API, which doesn't accept the
# bcrypt hash.
#
# Upload (after `tofu apply` here):
#
#   echo -n '<adguard-admin-username>' | gcloud secrets versions add \
#     homepage-adguard-username --project rockingham-homelab --data-file=-
#   echo -n '<adguard-admin-password>' | gcloud secrets versions add \
#     homepage-adguard-password --project rockingham-homelab --data-file=-
#   echo -n '<argocd-readonly-token>'  | gcloud secrets versions add \
#     homepage-argocd-token    --project rockingham-homelab --data-file=-
#
# See kubernetes/apps/homepage/README.md for the end-to-end flow.
resource "google_secret_manager_secret" "homepage_adguard_username" {
  project   = google_project.lab.project_id
  secret_id = "homepage-adguard-username"

  labels = {
    purpose = "addon-credential"
    addon   = "homepage"
  }

  replication {
    auto {}
  }

  depends_on = [google_project_service.enabled]
}

resource "google_secret_manager_secret" "homepage_adguard_password" {
  project   = google_project.lab.project_id
  secret_id = "homepage-adguard-password"

  labels = {
    purpose = "addon-credential"
    addon   = "homepage"
  }

  replication {
    auto {}
  }

  depends_on = [google_project_service.enabled]
}

resource "google_secret_manager_secret" "homepage_argocd_token" {
  project   = google_project.lab.project_id
  secret_id = "homepage-argocd-token"

  labels = {
    purpose = "addon-credential"
    addon   = "homepage"
  }

  replication {
    auto {}
  }

  depends_on = [google_project_service.enabled]
}

# ARC (actions-runner-controller) GitHub App credentials. Four containers
# pulled by the per-pool ExternalSecrets in
# kubernetes/apps/arc-runners-{raptgroup,brazostech}/manifests/external-secret.yaml
# and projected into a pre-defined K8s Secret consumed by the
# gha-runner-scale-set chart in Variation C. One App
# (`Rockingham Homelab ARC`) with two installations, both org-scoped:
# RaptGroup (the user's personal-projects org) and brazostech.
# **Not** installed on Scale Computing — that boundary is enforced
# server-side by GitHub. The App ID and private key are shared across
# both pools; only the installation ID differs.
#
# Upload (after `tofu apply` here):
#
#   echo -n '<APP_ID>'                | gcloud secrets versions add arc-app-id                     --project rockingham-homelab --data-file=-
#   echo -n '<RAPTGROUP_INSTALL_ID>'  | gcloud secrets versions add arc-installation-id-raptgroup  --project rockingham-homelab --data-file=-
#   echo -n '<BRAZOSTECH_INSTALL_ID>' | gcloud secrets versions add arc-installation-id-brazostech --project rockingham-homelab --data-file=-
#   gcloud secrets versions add arc-app-private-key \
#     --project rockingham-homelab \
#     --data-file=<path-to-app-private-key.pem>
#
# Rotation: regenerate the private key in the GitHub App's "Private keys"
# tab and re-run the last command. Installation IDs only change if the
# App is uninstalled and reinstalled.
resource "google_secret_manager_secret" "arc_app_id" {
  project   = google_project.lab.project_id
  secret_id = "arc-app-id"

  labels = {
    purpose = "addon-credential"
    addon   = "arc"
  }

  replication {
    auto {}
  }

  depends_on = [google_project_service.enabled]
}

resource "google_secret_manager_secret" "arc_app_private_key" {
  project   = google_project.lab.project_id
  secret_id = "arc-app-private-key"

  labels = {
    purpose  = "addon-credential"
    addon    = "arc"
    rotation = "manual"
  }

  replication {
    auto {}
  }

  depends_on = [google_project_service.enabled]
}

resource "google_secret_manager_secret" "arc_installation_id_raptgroup" {
  project   = google_project.lab.project_id
  secret_id = "arc-installation-id-raptgroup"

  labels = {
    purpose = "addon-credential"
    addon   = "arc"
  }

  replication {
    auto {}
  }

  depends_on = [google_project_service.enabled]
}

resource "google_secret_manager_secret" "arc_installation_id_brazostech" {
  project   = google_project.lab.project_id
  secret_id = "arc-installation-id-brazostech"

  labels = {
    purpose = "addon-credential"
    addon   = "arc"
  }

  replication {
    auto {}
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
