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
    "artifactregistry.googleapis.com",
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

# Public managed zone for the lab subzone. The NS delegation that points
# `lab.jackhall.dev` at the four `ns-cloud-d*.googledomains.com.` records
# lives inside the CF apex zone (terraform/cloudflare/main.tf →
# `cloudflare_dns_record.lab_delegation`); this root just owns the
# subzone itself. cert-manager creates ACME TXT records here.
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
# RaptGroup/homelab. ArgoCD authenticates to GitHub through this deploy
# key so bootstrap exercises the full ESO-from-GSM credential path end-
# to-end as a smoke test on a fresh project. ESO syncs the private key
# into a K8s Secret in the argocd namespace labelled
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

# Grafana admin password for the kube-prometheus-stack Application
# (kubernetes/apps/kube-prometheus-stack/). Container only — the JSON
# payload `{"admin-user":"admin","admin-password":"<password>"}` is
# uploaded out of band by the operator, same pattern as
# `adguard-home-admin` above. ADR-0007 Q5: anonymous viewers see
# dashboards; editing requires this admin password. ESO syncs the
# container into K8s Secret `observability/grafana-admin` via the
# `grafana-admin` ExternalSecret in this slice's manifests/.
#
# Upload (after `tofu apply` here):
#
#   echo -n '{"admin-user":"admin","admin-password":"<password>"}' \
#     | gcloud secrets versions add grafana-admin-password \
#         --project rockingham-homelab --data-file=-
#
# Rotation: re-upload a new version with the same command; ESO's
# next refresh (1h) propagates it. Grafana picks up the new
# credential on its next pod restart — kick with
# `kubectl -n observability rollout restart deploy kube-prometheus-stack-grafana`
# if the rotation has to take effect immediately.
resource "google_secret_manager_secret" "grafana_admin_password" {
  project   = google_project.lab.project_id
  secret_id = "grafana-admin-password"

  labels = {
    purpose = "addon-credential"
    addon   = "kube-prometheus-stack"
  }

  replication {
    auto {}
  }

  depends_on = [google_project_service.enabled]
}

# Alertmanager notification endpoints for the kube-prometheus-stack
# Application (kubernetes/apps/kube-prometheus-stack/). Containers only —
# the values are uploaded out of band by the operator, same pattern as
# `grafana-admin-password` above, so the URLs (each a bearer secret in
# its own right) never enter Terraform state or Git. ESO syncs each into
# its own K8s Secret in `observability` via the ExternalSecrets in this
# slice's manifests/; `alertmanagerSpec.secrets` mounts them so the
# Alertmanager config's `webhook_url_file` / `url_file` paths resolve.
#
# discord-alertmanager-webhook: the Discord channel webhook URL the
# default Alertmanager route POSTs actionable alerts to. Mint it on a
# dedicated alerts channel (Channel → Edit → Integrations → Webhooks).
#
# healthchecks-watchdog-url: the healthchecks.io ping URL the chart's
# always-firing `Watchdog` alert POSTs to every minute — the dead-man's
# switch. If Prometheus, Alertmanager, the node, or the ISP dies, the
# pings stop and healthchecks.io pages on its own schedule, surviving a
# fully-dark cluster. Create a check with period 1m and a short grace
# window, then copy its ping URL here.
#
# Upload (after `tofu apply` here; see kube-prometheus-stack/README.md):
#
#   echo -n '<discord-webhook-url>' \
#     | gcloud secrets versions add discord-alertmanager-webhook \
#         --project rockingham-homelab --data-file=-
#   echo -n '<healthchecks-ping-url>' \
#     | gcloud secrets versions add healthchecks-watchdog-url \
#         --project rockingham-homelab --data-file=-
resource "google_secret_manager_secret" "discord_alertmanager_webhook" {
  project   = google_project.lab.project_id
  secret_id = "discord-alertmanager-webhook"

  labels = {
    purpose  = "addon-credential"
    addon    = "kube-prometheus-stack"
    rotation = "manual"
  }

  replication {
    auto {}
  }

  depends_on = [google_project_service.enabled]
}

resource "google_secret_manager_secret" "healthchecks_watchdog_url" {
  project   = google_project.lab.project_id
  secret_id = "healthchecks-watchdog-url"

  labels = {
    purpose  = "addon-credential"
    addon    = "kube-prometheus-stack"
    rotation = "manual"
  }

  replication {
    auto {}
  }

  depends_on = [google_project_service.enabled]
}

# Harbor admin password for kubernetes/apps/harbor/ (#221). Harbor ships
# LAN-only at harbor.lab.jackhall.dev as the homelab's self-hosted OCI
# registry + Helm chart host, distinct from the GCP Artifact Registry
# `projects` repo (ADR-0006, the public/preview push path). Harbor is
# the LAN home for artifacts the homelab builds and keeps on its own
# infrastructure — decoupling them from GCP.
#
# Container only (same pattern as grafana-admin-password above): the
# plaintext password is uploaded out of band by the operator so the
# secret never round-trips through TF state or Git. The Harbor chart's
# `existingSecretAdminPassword` knob references the K8s Secret's
# `HARBOR_ADMIN_PASSWORD` key, which ESO syncs from this container via
# the `harbor-admin-password` ExternalSecret in
# kubernetes/apps/harbor/manifests/. Until the operator uploads a
# version, ESO reports `SecretSyncedError` and the Harbor core pod
# fails to find the credential — Argo reports `Degraded` rather than
# silently masking the gap, same fail-loud shape as Grafana.
#
# Upload (after `tofu apply` here):
#
#   echo -n '<harbor-admin-password>' \
#     | gcloud secrets versions add harbor-admin-password \
#         --project rockingham-homelab --data-file=-
#
# Rotation: re-upload a new version with the same command. ESO's next
# refresh (1h) propagates it; Harbor picks the new credential up on its
# next core pod restart — kick with
# `kubectl -n harbor rollout restart deploy harbor-core` to apply
# immediately.
resource "google_secret_manager_secret" "harbor_admin_password" {
  project   = google_project.lab.project_id
  secret_id = "harbor-admin-password"

  labels = {
    purpose = "addon-credential"
    addon   = "harbor"
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
    # `environment` is only present on OIDC tokens issued for a job that
    # declares `environment: <name>` in its workflow definition. Plan-only
    # jobs omit it. The apply SA's workloadIdentityUser binding below pins
    # to a specific environment value, so a plan-only token (no
    # `environment` claim) can never satisfy that principalSet.
    "attribute.environment" = "assertion.environment"
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

# roles/viewer covers every `*.get` and `*.list` the plan SA needs to
# refresh resources during `tofu plan`, with one well-known exception:
# `storage.buckets.getIamPolicy`. GCS's IAM permission model split bucket
# policy reads out of the basic viewer role (the legacy ACL world made
# IAM-policy access more privileged than other read paths), so refreshing
# `google_storage_bucket_iam_member` against any bucket in this project
# 403s on plan. roles/iam.securityReviewer is the predefined role for
# "read every IAM policy in the project, change none of them" — exactly
# the shape plan refresh needs. Bound project-wide rather than
# bucket-scoped because the gap recurs the moment a second bucket-IAM
# binding (or any other resource backed by an API that withholds
# getIamPolicy from roles/viewer) gets added; one binding here covers
# them all.
resource "google_project_iam_member" "tf_ci_security_reviewer" {
  project = google_project.lab.project_id
  role    = "roles/iam.securityReviewer"
  member  = "serviceAccount:${google_service_account.tf_ci.email}"
}

resource "google_service_account_iam_member" "tf_ci_wif_user" {
  service_account_id = google_service_account.tf_ci.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_actions.name}/attribute.repository/${var.github_repository}"
}

# Per-secret read on cloudflare-api-token. Project-wide roles/viewer
# above grants list-but-not-read on Secret Manager versions; reading
# the cleartext requires the dedicated secretAccessor role. The plan
# job for terraform/cloudflare/ instantiates the Cloudflare provider
# with this token at plan time, so widening the plan SA here is
# load-bearing for that root's PR plan to succeed. Narrow on purpose:
# bound to a single secret_id, not project-wide secretAccessor — a
# leak of this SA's tokens still cannot read any other GSM container
# in the project.
resource "google_secret_manager_secret_iam_member" "tf_ci_cloudflare_api_token_accessor" {
  project   = google_project.lab.project_id
  secret_id = google_secret_manager_secret.cloudflare_api_token.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.tf_ci.email}"
}

# Apply SA. roles/owner because tofu apply has to (re)create everything in
# this root, including the WIF pool/provider, project IAM bindings, and the
# tfstate bucket — narrower predefined roles either don't cover all of those
# or split them across so many bindings that the boundary stops being
# meaningful at homelab scale. The blast radius is bounded the other way: by
# the workloadIdentityUser binding below, which only lets workflow jobs that
# declare `environment: <var.ci_apply_environment>` impersonate this SA. The
# `gcp` GitHub environment carries deployment-branch restrictions and a
# required reviewer (set in the GitHub UI), so reaching this SA from CI
# requires (a) a push to main, (b) a workflow that opts into the
# environment, and (c) operator approval at run time. See ADR-0004.
resource "google_service_account" "tf_ci_apply" {
  project      = google_project.lab.project_id
  account_id   = var.tf_ci_apply_sa_id
  display_name = "Terraform CI apply"
  description  = "Used by .github/workflows/terraform-apply.yml. roles/owner on the project; impersonable only from a job declaring `environment: ${var.ci_apply_environment}`."

  depends_on = [google_project_service.enabled]
}

resource "google_project_iam_member" "tf_ci_apply_owner" {
  project = google_project.lab.project_id
  role    = "roles/owner"
  member  = "serviceAccount:${google_service_account.tf_ci_apply.email}"
}

# Env-scoped impersonation. The principalSet is keyed on the
# `environment` claim, and the provider's attribute_condition already
# pins repository to var.github_repository — combined, this is
# equivalent to `repo:${var.github_repository}:environment:${var.ci_apply_environment}`.
# Tokens minted from a plan-style job (no `environment` claim) will not
# match this set, so the apply SA cannot be impersonated from
# terraform-plan.yml or any other workflow that omits the environment.
resource "google_service_account_iam_member" "tf_ci_apply_wif_user" {
  service_account_id = google_service_account.tf_ci_apply.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_actions.name}/attribute.environment/${var.ci_apply_environment}"
}

# --- terraform/cloudflare/ apply SA -----------------------------------------
#
# Unlike tf_ci_apply (above) which holds roles/owner on the whole
# project because terraform/gcp/ legitimately creates/destroys
# everything in the project, terraform/cloudflare/'s GCP-side surface
# is two GSM bindings:
#
#   - data: read cloudflare-api-token to instantiate the CF provider
#   - resource: write a new version to cloudflare-tunnel-token after
#     CF mints the connector token
#
# Plus state I/O against this project's tfstate bucket and a read of
# terraform/gcp/'s state for the remote_state lookup. Granting
# roles/owner here would re-create the same broad surface tf_ci_apply
# carries — pointless when the root's actual GCP needs are this narrow.
# Instead, the bindings below add up to "read one secret, append one
# secret version, manage state objects in one bucket" and nothing
# else. The env-scoped WIF binding pins impersonation to a job whose
# OIDC token's `environment` claim is `${var.ci_apply_cloudflare_environment}`,
# parallel to the gcp environment for tf_ci_apply.
#
# Most of the apply blast radius is Cloudflare-side, not GCP-side, and
# the CF API token is scoped at mint time (Zone:Edit + Tunnel:Edit +
# SSL:Edit on jackhall.dev + the account) — narrowing the CF surface
# happens there, not here.
resource "google_service_account" "tf_ci_apply_cloudflare" {
  project      = google_project.lab.project_id
  account_id   = var.tf_ci_apply_cloudflare_sa_id
  display_name = "Terraform CI apply (cloudflare)"
  description  = "Used by .github/workflows/terraform-apply-cloudflare.yml. Narrow secret-scoped + bucket-scoped GCP permissions, no project IAM. Impersonable only from a job declaring `environment: ${var.ci_apply_cloudflare_environment}`."

  depends_on = [google_project_service.enabled]
}

# Read the operator-uploaded CF API token. Same secret tf_ci already
# reads via the binding higher up; binding both SAs at the per-secret
# level (rather than granting project-wide secretAccessor to either)
# keeps the reachable secret set minimal.
resource "google_secret_manager_secret_iam_member" "tf_ci_apply_cloudflare_api_token_accessor" {
  project   = google_project.lab.project_id
  secret_id = google_secret_manager_secret.cloudflare_api_token.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.tf_ci_apply_cloudflare.email}"
}

# Append a new version to cloudflare-tunnel-token. roles/secretmanager.secretVersionAdder
# is the narrowest predefined role that grants secretmanager.versions.add;
# crucially it does **not** include secretmanager.versions.access, so a
# leak of this SA cannot exfiltrate the existing tunnel token, only
# write a (CF-rejected, because of the secret rotation key) new one.
# The cleanup of older versions is handled by GSM's own retention,
# not by this SA.
resource "google_secret_manager_secret_iam_member" "tf_ci_apply_cloudflare_tunnel_token_version_adder" {
  project   = google_project.lab.project_id
  secret_id = google_secret_manager_secret.cloudflare_tunnel_token.secret_id
  role      = "roles/secretmanager.secretVersionAdder"
  member    = "serviceAccount:${google_service_account.tf_ci_apply_cloudflare.email}"
}

# State I/O on the tfstate bucket. roles/storage.objectUser covers
# get/create/delete/list — everything tofu needs to read its own
# state object, write updates, and acquire GCS-native state locks
# via object generations. Bucket-scoped, not project-scoped: a leak
# only reaches state objects in this one bucket. It does include
# read of terraform/gcp/'s state object (necessary for the
# remote_state data source) and write of terraform/cloudflare/'s
# own state object; in principle this SA could also overwrite
# terraform/gcp/'s state, which is wider than ideal — bounded by
# the env-scoped WIF gate + required reviewer on the cloudflare
# environment. Same calculus as tf_ci_apply's roles/owner: trust
# the impersonation gate as the primary boundary, keep the IAM
# minimal-but-not-conditional at homelab scale.
resource "google_storage_bucket_iam_member" "tf_ci_apply_cloudflare_state" {
  bucket = google_storage_bucket.tfstate.name
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.tf_ci_apply_cloudflare.email}"
}

resource "google_service_account_iam_member" "tf_ci_apply_cloudflare_wif_user" {
  service_account_id = google_service_account.tf_ci_apply_cloudflare.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_actions.name}/attribute.environment/${var.ci_apply_cloudflare_environment}"
}

# --- Artifact Registry: preview-environment images -------------------------
#
# Docker-format regional repository holding the OCI images that
# preview-env workloads pull. Region is us-east4 (Ashburn, VA) — closest
# of the four US GCP regions to the Rockingham homelab, and closest to
# GitHub-hosted runners on the east coast that do most preview-env
# pushes. Image path:
#
#   us-east4-docker.pkg.dev/rockingham-homelab/projects/<workload>:<tag>
#
# The repository name mirrors the preview-env subzone
# (`projects.jackhall.dev`) on purpose — image paths and DNS hostnames
# share the `projects` label so an operator reading either knows
# they're looking at the same surface.
#
# Cleanup policies bound preview-env churn:
#   - Untagged blobs (failed pushes, replaced layers) are deleted after
#     7 days. Untagged content is uniformly garbage at homelab scale.
#   - Tagged versions are deleted after 90 days. Preview tags are
#     usually keyed on PR / commit and rotate naturally; 90 days is
#     generous enough that a stale-but-still-relevant branch image
#     survives a vacation.
resource "google_artifact_registry_repository" "projects" {
  project       = google_project.lab.project_id
  location      = var.artifact_registry_region
  repository_id = var.artifact_registry_repository_id
  description   = "Preview-environment images (ADR-0006). Pushed by tf-ci-arc-push from ARC workflows; pulled in-cluster via tf-ci-cluster-pull through an ESO GCRAccessToken generator."
  format        = "DOCKER"

  cleanup_policies {
    id     = "delete-untagged-after-7d"
    action = "DELETE"
    condition {
      tag_state  = "UNTAGGED"
      older_than = "604800s"
    }
  }

  cleanup_policies {
    id     = "delete-tagged-after-90d"
    action = "DELETE"
    condition {
      tag_state  = "TAGGED"
      older_than = "7776000s"
    }
  }

  depends_on = [google_project_service.enabled]
}

# Push SA for ARC workflows. roles/artifactregistry.writer scoped to
# the `projects` repo only (via google_artifact_registry_repository_iam_member),
# not project-wide — a leaked push token cannot create new repositories
# or affect anything outside the preview-env surface.
resource "google_service_account" "arc_push" {
  project      = google_project.lab.project_id
  account_id   = var.arc_push_sa_id
  display_name = "Artifact Registry push (ARC)"
  description  = "Impersonable from ARC-pool workflows in the repository allowlist (CONTEXT.md → ARC). roles/artifactregistry.writer scoped to the `projects` repo; cannot reach anything else in the project."

  depends_on = [google_project_service.enabled]
}

resource "google_artifact_registry_repository_iam_member" "arc_push_writer" {
  project    = google_project.lab.project_id
  location   = google_artifact_registry_repository.projects.location
  repository = google_artifact_registry_repository.projects.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.arc_push.email}"
}

# Dedicated WIF provider for ARC push. The existing `github` provider's
# attribute_condition pins repository to var.github_repository
# (RaptGroup/homelab) — narrower than the ARC App installations'
# combined allowlist. Widening the existing provider's condition would
# also widen tf-ci-apply's reachable token set (apply's principalSet
# keys on attribute.environment alone, so a wider repo gate plus an
# `environment: gcp` claim from any repo would impersonate apply).
# A second provider keeps the apply gate untouched and gives ARC push
# its own repo allowlist at the pool boundary, in addition to the
# per-repo workloadIdentityUser bindings below.
resource "google_iam_workload_identity_pool_provider" "github_arc" {
  project                            = google_project.lab.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github_actions.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-arc"
  display_name                       = "GitHub OIDC (ARC repos)"
  description                        = "Trusts GitHub-issued OIDC tokens whose `repository` claim is in var.arc_push_repository_allowlist. Consumed by tf-ci-arc-push only; tf-ci-plan and tf-ci-apply continue to use the `github` provider, which is locked to var.github_repository."

  attribute_mapping = {
    "google.subject"             = "assertion.sub"
    "attribute.repository"       = "assertion.repository"
    "attribute.repository_owner" = "assertion.repository_owner"
    "attribute.ref"              = "assertion.ref"
    "attribute.actor"            = "assertion.actor"
  }

  attribute_condition = "assertion.repository in ${jsonencode(var.arc_push_repository_allowlist)}"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# Per-repo workloadIdentityUser bindings. The attribute_condition above
# is the pool-level gate; this set is the SA-level gate. Both must
# pass — an OIDC token from a repo not in the allowlist is rejected
# before reaching the SA, and a token from an allowlisted repo can
# only act as this specific SA via its matching principalSet entry.
resource "google_service_account_iam_member" "arc_push_wif_user" {
  for_each = toset(var.arc_push_repository_allowlist)

  service_account_id = google_service_account.arc_push.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_actions.name}/attribute.repository/${each.value}"
}

# In-cluster pull SA. roles/artifactregistry.reader scoped to the
# `projects` repo. Impersonated from in-cluster Pods via the cluster's
# own Workload Identity Federation pool (see the `cluster_oidc_*` and
# `cluster_wif_*` resources below): a Pod-mounted projected K8s SA
# token is exchanged at GCP STS for a federated access token, then
# impersonated into this SA. No JSON key — same posture as the ARC
# push path has via GitHub OIDC. The roles/artifactregistry.reader
# scope is the only thing constraining what the resulting token can
# do. See kubernetes/apps/ar-canary/.
resource "google_service_account" "cluster_pull" {
  project      = google_project.lab.project_id
  account_id   = var.cluster_pull_sa_id
  display_name = "Artifact Registry pull (cluster)"
  description  = "In-cluster identity for pulls from the `projects` AR repo. roles/artifactregistry.reader scoped to the repo; cannot read anything else. Impersonable via the cluster WIF binding only — no JSON key anywhere."

  depends_on = [google_project_service.enabled]
}

resource "google_artifact_registry_repository_iam_member" "cluster_pull_reader" {
  project    = google_project.lab.project_id
  location   = google_artifact_registry_repository.projects.location
  repository = google_artifact_registry_repository.projects.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.cluster_pull.email}"
}

# --- Cluster OIDC issuer hosting + cluster WIF -----------------------------
#
# The Talos cluster mints its own JWTs (kube-apiserver TokenRequest API)
# and uses them as the input to a GCP STS token exchange — same shape
# the ARC push path has via GitHub OIDC, but with the cluster as the
# OP. For GCP STS to validate those JWTs it has to fetch the cluster's
# OIDC discovery document and JWKS from a publicly-reachable URL; Talos
# defaults its issuer to a cluster-internal address, which is
# unreachable from outside the LAN.
#
# The cheapest pattern for "publicly-reachable URL serving two small
# static JSON objects" is a public-read GCS bucket served directly via
# `https://storage.googleapis.com/<bucket>/...`. The bucket's hostname
# already has a valid TLS cert and a stable URL shape — no Cloud Load
# Balancer (~$20/mo on a homelab budget), no custom DNS, no ACM cert
# rotation. The trade-off is the URL doesn't live under jackhall.dev;
# acceptable because nothing reads this URL by hand — kube-apiserver
# advertises it in `iss` and GCP STS fetches it.
#
# Issuer URL: https://storage.googleapis.com/<var.cluster_oidc_bucket>
# Discovery: <issuer>/.well-known/openid-configuration  (TF-managed below)
# JWKS:      <issuer>/openid/v1/jwks                    (uploaded out of band)
#
# The JWKS contents come from the live cluster's signing public keys
# and have to be uploaded after each Talos secret rotation. See
# talos/README.md for the operator-side recipe.

locals {
  cluster_oidc_issuer = "https://storage.googleapis.com/${google_storage_bucket.cluster_oidc.name}"
}

resource "google_storage_bucket" "cluster_oidc" {
  project  = google_project.lab.project_id
  name     = var.cluster_oidc_bucket
  location = var.cluster_oidc_bucket_location

  uniform_bucket_level_access = true
  # `inherited` rather than `enforced` because WIF discovery is
  # unauthenticated by spec — GCP STS fetches the discovery doc and
  # JWKS without any credentials, so allUsers must be able to read
  # objects. The contents are non-sensitive (issuer metadata + public
  # signing keys), but flagging the deviation here so a future reader
  # doesn't reflexively "lock it down" by enforcing PAP.
  public_access_prevention = "inherited"
  force_destroy            = false

  depends_on = [google_project_service.enabled]
}

resource "google_storage_bucket_iam_member" "cluster_oidc_public_read" {
  bucket = google_storage_bucket.cluster_oidc.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

# The discovery document is fully derived from the issuer URL — TF
# generates and uploads it so a fresh project bootstraps to a working
# state without an extra manual gsutil step. The JWKS is the cluster-
# specific half and stays out-of-band (see talos/README.md).
resource "google_storage_bucket_object" "cluster_oidc_discovery" {
  bucket       = google_storage_bucket.cluster_oidc.name
  name         = ".well-known/openid-configuration"
  content_type = "application/json"
  content = jsonencode({
    issuer                                = local.cluster_oidc_issuer
    jwks_uri                              = "${local.cluster_oidc_issuer}/openid/v1/jwks"
    response_types_supported              = ["id_token"]
    subject_types_supported               = ["public"]
    id_token_signing_alg_values_supported = ["RS256"]
  })
  cache_control = "public, max-age=300"
}

# WIF pool dedicated to the cluster. Separate from `github-actions` so
# the pool boundary advertises the identity source. Per-namespace trust
# narrows on the SA-level binding below, not at the pool — same shape
# the github pool uses (provider attribute_condition + per-SA
# workloadIdentityUser).
resource "google_iam_workload_identity_pool" "cluster" {
  project                   = google_project.lab.project_id
  workload_identity_pool_id = var.cluster_wif_pool_id
  display_name              = "Rockingham cluster"
  description               = "OIDC pool trusted by the Talos `rockingham` cluster; per-namespace/SA trust is enforced on the SA-level workloadIdentityUser binding."

  depends_on = [google_project_service.enabled]
}

# Provider trusting the cluster's published OIDC issuer.
#
# attribute_mapping pulls subject, namespace, and SA name out of the
# JWT. `google.subject` is the only required mapping; the additional
# attributes are extracted so a future principalSet on
# attribute.namespace can scope an SA binding to a namespace pattern
# (the preview-env evolution) without re-doing the federation.
#
# CEL bracket syntax `assertion["kubernetes.io"][...]` is required
# because the K8s SA JWT claim key contains a dot.
#
# No attribute_condition — there's nothing to gate at the pool level
# beyond the issuer trust itself. A JWT minted by another K8s cluster
# would need to match the issuer URL (impossible — GCS bucket name is
# unique), and a JWT for an unbound SA still cannot impersonate any
# GCP SA without an explicit workloadIdentityUser binding.
resource "google_iam_workload_identity_pool_provider" "cluster_talos" {
  project                            = google_project.lab.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.cluster.workload_identity_pool_id
  workload_identity_pool_provider_id = var.cluster_wif_provider_id
  display_name                       = "Talos OIDC"
  description                        = "Trusts JWTs minted by the Talos cluster's kube-apiserver (issuer: ${local.cluster_oidc_issuer})."

  attribute_mapping = {
    "google.subject"           = "assertion.sub"
    "attribute.namespace"      = "assertion[\"kubernetes.io\"][\"namespace\"]"
    "attribute.serviceaccount" = "assertion[\"kubernetes.io\"][\"serviceaccount\"][\"name\"]"
  }

  oidc {
    issuer_uri = local.cluster_oidc_issuer
  }

  depends_on = [google_storage_bucket_object.cluster_oidc_discovery]
}

# Narrow workloadIdentityUser binding: only the puller SA inside
# var.cluster_pull_k8s_namespace can impersonate tf-ci-cluster-pull.
# When the preview-env baseline templates a puller SA into every
# preview namespace, replace this with a principalSet on
# `attribute.namespace` matching the preview-env naming scheme so a
# single binding covers every preview at once.
#
# This is the active grant path for the cluster→AR pull: ESO v2.x's
# `auth.workloadIdentityFederation` reader on the `ar-canary-puller`
# ServiceAccount picks up the `iam.gke.io/gcp-service-account`
# annotation, calls iamcredentials:generateAccessToken to impersonate
# tf-ci-cluster-pull (authorized by this binding), and returns that SA's
# token — which carries roles/artifactregistry.reader on the `projects`
# repo via the per-repo binding below.
resource "google_service_account_iam_member" "cluster_pull_wif_user" {
  service_account_id = google_service_account.cluster_pull.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/${google_iam_workload_identity_pool.cluster.name}/subject/system:serviceaccount:${var.cluster_pull_k8s_namespace}:${var.cluster_pull_k8s_sa}"
}

# Bootstrap ESO's GSM access via the same cluster WIF pool (ADR-0007).
# The `external-secrets-gsm` K8s ServiceAccount in the
# `external-secrets` namespace is the workload-identity principal; ESO
# mints a projected token for it, exchanges it at GCP STS for a
# federated token, then impersonates the `external-secrets` GCP SA
# (authorized by this binding) to read GSM. The project-scoped
# `roles/secretmanager.secretAccessor` binding higher up is what gives
# the impersonated SA actual read access; this binding only authorizes
# the impersonation hop. No long-lived JSON key on the bootstrap path.
#
# Namespace/SA strings must match the kubernetes_service_account
# resource in `terraform/bootstrap/external-secrets.tf` and the
# `serviceAccountRef` in the `gsm` ClusterSecretStore manifest — the
# constraint is named here as the GCP-side IAM gate.
resource "google_service_account_iam_member" "eso_wif_user" {
  service_account_id = google_service_account.eso.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/${google_iam_workload_identity_pool.cluster.name}/subject/system:serviceaccount:${var.eso_k8s_namespace}:${var.eso_k8s_sa}"
}

# Narrow workloadIdentityUser binding: only the cert-manager controller
# SA (cert-manager/cert-manager — chart-rendered name) can impersonate
# the cert-manager DNS-01 solver SA. Same shape as cluster_pull_wif_user
# and eso_wif_user above — different K8s SA, different GCP SA, same
# cluster pool.
#
# cert-manager's clouddns provider has no native non-GKE WIF knob, so
# the controller's ADC does the token exchange itself: a projected K8s
# SA token (audience = the cluster WIF provider's full resource name,
# mounted at /var/run/secrets/tokens/gcp-token) is the input to GCP STS;
# an external_account credentials JSON delivered via
# GOOGLE_APPLICATION_CREDENTIALS names the cert_manager GCP SA as the
# impersonation target. After exchange the `clouddns` solver runs with
# this SA's zone-scoped roles/dns.admin and never sees provider-specific
# auth config. See terraform/bootstrap/cert-manager.tf for the
# cluster-side wiring.
resource "google_service_account_iam_member" "cert_manager_wif_user" {
  service_account_id = google_service_account.cert_manager.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/${google_iam_workload_identity_pool.cluster.name}/subject/system:serviceaccount:${var.cert_manager_k8s_namespace}:${var.cert_manager_k8s_sa}"
}

# --- Longhorn off-site backups (GCS via S3 interop) ------------------------
#
# Longhorn writes snapshot/backup data to GCS through the bucket's S3
# interoperability endpoint. The pieces:
#
#   1. GCS bucket scoped to backup data only.
#   2. Dedicated SA with `roles/storage.objectAdmin` BOUND TO THE BUCKET,
#      not project-wide — leaking the SA's HMAC pair cannot reach anything
#      else in the project.
#   3. GSM container `longhorn-backup-credentials` holding the HMAC
#      `{access_id, secret}` JSON. ESO syncs it into a K8s Secret in
#      `longhorn-system` (kubernetes/apps/longhorn/manifests/external-secret.yaml),
#      which Longhorn references via `defaultBackupStore.backupTargetCredentialSecret`.
#
# The HMAC key itself is deliberately NOT a TF resource. Same rationale as
# `talos-cluster-secrets` / `argocd-repo-ssh-key`: keeping a long-lived
# plaintext credential out of TF state. The operator mints the HMAC out of
# band via `gcloud storage hmac create` (one command, atomic) and uploads
# the resulting JSON to GSM — both bytes land only in GSM, never in the
# state bucket. Deleting `google_service_account.longhorn_backup` here
# revokes the HMAC implicitly (HMAC keys are owned by the SA), so TF still
# governs the lifecycle even though it doesn't own the secret value. See
# terraform/gcp/README.md for the mint + upload + rotation commands.
resource "google_service_account" "longhorn_backup" {
  project      = google_project.lab.project_id
  account_id   = var.longhorn_backup_sa_id
  display_name = "Longhorn backup target"
  description  = "S3-interop identity Longhorn uses to write off-site backups. roles/storage.objectAdmin bound at the longhorn-backups bucket only. HMAC pair in the longhorn-backup-credentials GSM container, operator-minted out of band."

  depends_on = [google_project_service.enabled]
}

resource "google_storage_bucket" "longhorn_backups" {
  project  = google_project.lab.project_id
  name     = var.longhorn_backups_bucket
  location = var.longhorn_backups_bucket_location

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  # force_destroy=false so an accidental `tofu destroy` doesn't take the
  # bucket — and every backup in it — without first emptying through
  # Longhorn's own delete path or `gcloud storage rm -r`. Same posture
  # as the tfstate bucket above.
  force_destroy = false

  # No object versioning. Longhorn writes immutable backup blocks with
  # content-addressed names and manages its own retention via RecurringJob
  # CRDs in the cluster — keeping noncurrent GCS versions on top of
  # Longhorn's history would double-store every backup for no gain.
  #
  # No lifecycle rule either. Longhorn owns retention semantics
  # (RecurringJob `.spec.retain` per volume); a TTL here would silently
  # delete blocks Longhorn still references, breaking restore. If a
  # bucket-level floor is ever wanted as a backstop, it must be set
  # *higher* than the longest Longhorn retain window — out of scope for
  # this slice.

  depends_on = [google_project_service.enabled]
}

# Bucket-scoped objectAdmin. roles/storage.objectAdmin covers
# create/read/delete/list of objects, which is exactly what Longhorn needs
# to write new backup blocks and prune old ones. Binding at the bucket
# resource (not the project) is the blast-radius gate: a leaked HMAC pair
# cannot touch the tfstate bucket, the AR push paths, or anything else
# in the project.
resource "google_storage_bucket_iam_member" "longhorn_backup_object_admin" {
  bucket = google_storage_bucket.longhorn_backups.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.longhorn_backup.email}"
}

# GSM container for the HMAC `{access_id, secret}` JSON. Same shape as
# talos-cluster-secrets / argocd-repo-ssh-key: container TF-managed (so
# the addon's ExternalSecret can reference a stable name on a fresh
# project), value uploaded out of band so a long-lived credential is
# never round-tripped through TF state.
#
# Mint and upload (after `tofu apply` here):
#
#   gcloud storage hmac create \
#     $(tofu output -raw longhorn_backup_service_account_email) \
#     --project=$(tofu output -raw project_id) \
#     --format='json(accessId,secret)' > /tmp/longhorn-hmac.json
#   jq -c '{access_id: .accessId, secret: .secret}' /tmp/longhorn-hmac.json \
#     | gcloud secrets versions add \
#         $(tofu output -raw longhorn_backup_credentials_secret_id) \
#         --project=$(tofu output -raw project_id) \
#         --data-file=-
#   rm -f /tmp/longhorn-hmac.json
#
# Rotation: `gcloud storage hmac update <access_id> --deactivate` the
# current key, mint a new one with the same command above, upload as a
# new GSM version, then `gcloud storage hmac delete <access_id>` once
# Longhorn picks up the new version (ESO refresh + Longhorn's
# backup-target reload — bounded by `refreshInterval: 1h` on the
# ExternalSecret).
resource "google_secret_manager_secret" "longhorn_backup_credentials" {
  project   = google_project.lab.project_id
  secret_id = "longhorn-backup-credentials"

  labels = {
    purpose  = "addon-credential"
    addon    = "longhorn"
    rotation = "manual"
  }

  replication {
    auto {}
  }

  depends_on = [google_project_service.enabled]
}

# --- Cloudflare Tunnel: public preview env path (ADR-0006) -----------------
#
# Two GSM containers back the `terraform/cloudflare/` root and the
# in-cluster `cloudflared` addon. The shape mirrors every other addon
# secret in this root: container TF-managed here, value uploaded out of
# band — so the long-lived plaintext credential never round-trips
# through TF state.
#
# cloudflare-api-token: the operator-minted Cloudflare API token used by
# `terraform/cloudflare/` to authenticate. Scoped to Zone:Edit +
# Tunnel:Edit + DNS:Edit on the projects zone only — wide enough for
# the root to manage the tunnel, the wildcard CNAME, and the CAA
# records, narrow enough that a leak doesn't reach the operator's
# other zones. Bootstrap step: see `terraform/cloudflare/README.md`.
#
# Upload (one-time bootstrap):
#
#   echo -n '<cf-api-token>' \
#     | gcloud secrets versions add cloudflare-api-token \
#         --project rockingham-homelab --data-file=-
#
# cloudflare-tunnel-token: the per-tunnel connector token cloudflared
# uses to authenticate to Cloudflare's edge. Unlike every other GSM
# container in this root, this one's value is written *by Terraform*
# (`terraform/cloudflare/` reads the token from the
# cloudflare_zero_trust_tunnel_cloudflared_token data source and posts
# it as a new secret version). The container is created here so the
# cloudflared addon's ExternalSecret has a stable name to reference,
# and so the `terraform/cloudflare/` root doesn't have to assume
# create-permissions on the GSM API surface beyond writing versions.
resource "google_secret_manager_secret" "cloudflare_api_token" {
  project   = google_project.lab.project_id
  secret_id = "cloudflare-api-token"

  labels = {
    purpose  = "addon-credential"
    addon    = "cloudflared"
    rotation = "manual"
  }

  replication {
    auto {}
  }

  depends_on = [google_project_service.enabled]
}

resource "google_secret_manager_secret" "cloudflare_tunnel_token" {
  project   = google_project.lab.project_id
  secret_id = "cloudflare-tunnel-token"

  labels = {
    purpose  = "addon-credential"
    addon    = "cloudflared"
    rotation = "terraform"
  }

  replication {
    auto {}
  }

  depends_on = [google_project_service.enabled]
}
