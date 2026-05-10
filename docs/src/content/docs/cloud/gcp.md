---
title: rockingham-homelab GCP project
description: The single GCP project that owns every cloud-side resource for the lab — DNS zones, Secret Manager containers, the IAM service accounts cert-manager and ESO impersonate, the Workload Identity Federation pool GitHub Actions authenticates through, and the Terraform state bucket.
---

Everything the lab needs from a cloud provider lives in one GCP project,
`rockingham-homelab`. The project is created by
[`terraform/gcp/`](https://github.com/RaptGroup/homelab/tree/main/terraform/gcp)
and holds, in a single bounded blast radius:

- Two Cloud DNS managed zones (`jackhall.dev` apex + `lab.jackhall.dev`
  subzone).
- The Secret Manager (GSM) containers that External Secrets Operator
  reads from.
- Two IAM service accounts (`cert-manager-dns01`, `external-secrets`) the
  cluster impersonates from inside the cluster, and one plan-only CI SA
  (`tf-ci-plan`) GitHub Actions impersonates from outside.
- A Workload Identity Federation pool that trusts GitHub OIDC tokens
  scoped to this repository.
- The GCS bucket holding Terraform state for both roots.

`terraform/gcp/` is the *only* place these resources are declared.
`terraform/bootstrap/` reads remote-state outputs from it (zone name, SA
emails, project ID) but creates nothing on the cloud side; ArgoCD never
touches GCP at all.

## Why one project

Project-level isolation is the only blast-radius boundary GCP enforces
cheaply. Everything in `rockingham-homelab` can be torn down atomically
with `tofu destroy` — the project resource has `deletion_policy = "DELETE"`,
which overrides the v6 provider default of `PREVENT`. A `gcloud projects
undelete <project_id>` window covers the next 30 days if the destroy was
accidental. This convention is captured in
[ADR-0001](https://github.com/RaptGroup/homelab/blob/main/docs/adr/0001-iac-strategy.md)
and surfaces in
[CONTEXT.md](https://github.com/RaptGroup/homelab/blob/main/CONTEXT.md)
as the `rockingham-homelab` entry.

## DNS

Both zones live in Cloud DNS. The shape exists for one structural reason:
the registrar (Squarespace) was pointed at Cloud DNS nameservers at the
apex level when the `lab` subzone was first delegated. Without an apex
zone in Cloud DNS, queries for `jackhall.dev` return `REFUSED` and Let's
Encrypt's CAA walk SERVFAILs while trying to issue `*.lab.jackhall.dev` —
the walk traverses `*.lab.jackhall.dev → lab.jackhall.dev →
jackhall.dev → dev` and stops at the first level that doesn't resolve.

| Zone | Holds | Why it's in Cloud DNS |
|---|---|---|
| `jackhall.dev` (apex) | SOA/NS (auto), the CAA record, the `lab` NS delegation. Nothing else. | Squarespace's nameserver field points here, so the apex *must* resolve from Cloud DNS or every walk above the lab subzone fails. |
| `lab.jackhall.dev` | ACME DNS-01 TXT records, written by cert-manager. No A/AAAA — internal hostnames are served by AdGuard Home in-cluster. | NS-delegated from the apex above. cert-manager needs write access via a service account; that's only possible against a zone in a provider Terraform owns. |

The CAA record at the apex permits Let's Encrypt and only Let's Encrypt
to issue for `jackhall.dev` and below. Without an explicit CAA, the CAA
walk hits the default-allow at the `dev` TLD and the cluster still gets
its cert; the explicit record is defense in depth, blocking any other
CA from accidentally issuing for this domain if the apex ever stops
returning `REFUSED`.

The `lab.jackhall.dev` zone is the *public* half of the lab's
[split-horizon DNS](/homelab/networking/split-horizon-dns/) setup — it
publishes only ACME challenges, never the LAN IPs of cluster services.
LAN-side resolution is owned by AdGuard Home on `192.168.1.200`.

Outputs to consume:

- `lab_zone_name` → `terraform/bootstrap/` passes it to cert-manager's
  `ClusterIssuer` so the DNS-01 solver targets exactly this zone.
- `lab_zone_name_servers` → operator pastes into the registrar after the
  first apply, completing the NS delegation.
- `apex_zone_name_servers` → operator compares against Squarespace's
  current nameserver field; mismatch is the signal to update Squarespace.

## Secret Manager

GSM is the storage half of the cluster's secrets pipeline. Every
credential the lab needs at runtime lives here as a *container* declared
by Terraform; the actual versions are uploaded out of band via
`gcloud secrets versions add`. This split keeps the plaintext values out
of Terraform state — pulling them through TF would land them in the
GCS-backed state file (doubling the surface) and force every operator
without a local copy to either plumb a CI env var or trigger a spurious
"version will be destroyed" diff on every plan.

The containers currently provisioned:

| GSM secret ID | Purpose | Uploader |
|---|---|---|
| `talos-cluster-secrets` | The whole of `talos/_out/secrets.yaml` — cluster CA private key, etcd bootstrap token, friends. The one irreplaceable file in the lab. | Operator, after `talosctl gen secrets`. See [`talos/README.md`](https://github.com/RaptGroup/homelab/tree/main/talos). |
| `argocd-repo-ssh-key` | Private half of the GitHub deploy key ArgoCD uses to clone this repo. | Operator, after registering the public half as a read-only deploy key on the repo. |
| `adguard-home-admin` | JSON `{username, password_hash}` for AdGuard Home's admin user. `password_hash` is the bcrypt hash; the matching plaintext lives in the homepage-adguard-* pair below. | Operator. |
| `homepage-adguard-username` / `homepage-adguard-password` | Plaintext credentials for the Homepage AdGuard widget (the live-status API doesn't accept the bcrypt hash). Must match the password in `adguard-home-admin`. | Operator. |
| `homepage-argocd-token` | ArgoCD readonly API token for the Homepage ArgoCD widget. | Operator. |
| `arc-app-id` / `arc-app-private-key` | GitHub App ID and PEM private key for the `Rockingham Homelab ARC` App that backs both runner scale sets. | Operator, after creating/rotating the App. |
| `arc-installation-id-raptgroup` / `arc-installation-id-brazostech` | Per-org installation IDs for the two ARC pools (`raptgroup` and `brazostech`). One App, two installations. | Operator. |

How cluster addons read these: every credential transits through
[External Secrets Operator](/homelab/platform/external-secrets/). Each
addon ships an `ExternalSecret` manifest under `kubernetes/apps/<addon>/`
that names the GSM secret by ID; ESO polls every hour, materialises the
value as a Kubernetes `Secret` in the addon's namespace, and the addon
consumes it normally. The mapping is one-to-one: a GSM container above
corresponds to exactly one `ExternalSecret` somewhere in the repo.

Rotating a credential is a one-shot
`gcloud secrets versions add <id>` against the container — no Terraform
run, no ArgoCD sync. ESO picks up the new version on its next refresh
and the consuming addon picks it up on its next pod restart (or sooner,
if the addon watches the `Secret`).

## IAM service accounts

Three service accounts. Each is scoped tightly enough that compromise of
its credentials does not give general access to the project.

### `cert-manager-dns01`

Used by cert-manager's DNS-01 solver to write `_acme-challenge`
TXT records into the `lab.jackhall.dev` zone. The SA holds
`roles/dns.admin` **scoped to that one managed zone**, not
project-wide — there is no `roles/dns.admin` binding at the project
level, so the SA cannot list, read, or modify the apex zone or any
future zone. The matching SA key is minted by `terraform/bootstrap/`,
uploaded to GSM, and synced into the cluster by ESO so the
`ClusterIssuer` can read it as a normal Kubernetes `Secret`.

This is the "scope the SA, then name the zone explicitly" pattern: the
`ClusterIssuer` in cert-manager names `hostedZoneName: lab.jackhall.dev`
explicitly rather than letting cert-manager auto-discover, because the
SA lacks the project-level `dns.managedZones.list` permission
auto-discovery would call. See
[cert-manager](/homelab/platform/cert-manager/) for the full chain.

### `external-secrets`

Used by ESO to read every GSM container above. Holds
`roles/secretmanager.secretAccessor` at the project level — read-only,
all secrets in the project. Project-scope is deliberate: each new
container that comes online is automatically reachable by ESO without a
per-secret IAM resource, which matters because containers are added
opportunistically as addons land.

The SA key is minted by `terraform/bootstrap/`, written into one
Kubernetes `Secret` (`gcp-sm-credentials` in the `external-secrets`
namespace), and *every other credential in the cluster flows through
this single bootstrap*. That property is load-bearing for the
[ADR-0001](https://github.com/RaptGroup/homelab/blob/main/docs/adr/0001-iac-strategy.md)
boundary — see
[External Secrets Operator](/homelab/platform/external-secrets/) for
the chicken-and-egg argument and the alternatives that were rejected.

### `tf-ci-plan`

Used by `.github/workflows/terraform-plan.yml` to run `tofu plan` on
pull requests. Holds `roles/viewer` at the project level — enough to
read state, the live resource graph, and the contents of the tfstate
bucket; *structurally* insufficient to apply changes. `tofu apply`
remains operator-only on a workstation with ADC. Impersonated via
Workload Identity Federation (see below) rather than via a long-lived
JSON key.

## Workload Identity Federation

The CI plan workflow runs on GitHub-hosted runners and authenticates
to GCP via OIDC instead of a JSON key. The pieces:

```
GitHub Actions runner
  │
  │  emits OIDC token w/ assertion.repository == "RaptGroup/homelab"
  ▼
Workload Identity Pool: github-actions
  │
  │  provider "github" trusts token.actions.githubusercontent.com
  │  attribute_condition rejects any other repository
  ▼
principalSet → attribute.repository/RaptGroup/homelab
  │
  │  roles/iam.workloadIdentityUser → tf-ci-plan SA
  ▼
tf-ci-plan@rockingham-homelab.iam.gserviceaccount.com  (roles/viewer)
```

The lock is on the *provider*, not the pool: a pool can have many
providers and the trust scope of each is enforced in the provider's
`attribute_condition`. Here the condition is
`assertion.repository == "RaptGroup/homelab"`, so an OIDC token issued
for any other repo — even one in the same org — is rejected before it
can reach the SA. There is no branch or actor restriction; any push,
PR, or manual run from this repo can call `terraform plan`, but that
is bounded by the viewer-only SA.

What CI is wired up to consume:

| GitHub Actions repository variable / secret | Value source |
|---|---|
| `GCP_WIF_PROVIDER` (variable) | `tofu output -raw ci_workload_identity_provider` |
| `GCP_CI_SA` (variable) | `tofu output -raw ci_service_account_email` |
| `GCP_BILLING_ACCOUNT` (secret) | The same billing account ID used in `terraform.tfvars` |

The third value is a secret rather than a variable because Terraform
needs it to set the `billing_account` variable; the workflow refuses to
plan without it. See
[`terraform/gcp/README.md`](https://github.com/RaptGroup/homelab/tree/main/terraform/gcp#ci-github-actions-auth)
for the operator-side wire-up commands, and
[Automation / `terraform-plan`](/homelab/automation/ci/#terraform-plan)
for the workflow side — what runs against this SA on each PR and how
the `bootstrap` root's plan handles having no live cluster to refresh
against.

## State bucket

`gs://rockingham-homelab-tfstate` holds the Terraform state for both
roots:

- `gs://rockingham-homelab-tfstate/terraform/gcp/` — this root's state.
- `gs://rockingham-homelab-tfstate/terraform/bootstrap/` — the
  bootstrap root's state.

Versioning is on (10 newer versions retained, older ones expire after
30 noncurrent-days), uniform bucket-level access is enforced, and
public access is structurally prevented. The bucket location is a
single region (`US-CENTRAL1`) — multi-region is overkill for a homelab
and roughly doubles the storage cost.

The GCS backend uses object generations for native state locking — no
separate lock table required (unlike S3 + DynamoDB). Concurrent plans
from a workstation and CI serialize at the bucket level.

Bootstrap-from-scratch caveat: on the very first apply (or after a
`tofu destroy`), the bucket doesn't yet exist, so `tofu init` against
the GCS backend can't read anything and fails. The recipe is to
temporarily comment out the `backend "gcs"` block in `versions.tf`,
apply locally, then uncomment and `tofu init -migrate-state` to push
the state into the bucket. See
[`terraform/gcp/README.md`](https://github.com/RaptGroup/homelab/tree/main/terraform/gcp#bootstrap-from-scratch)
for the full sequence.

## More

[`terraform/gcp/README.md`](https://github.com/RaptGroup/homelab/tree/main/terraform/gcp)
is the operator-facing run book — billing prerequisites, the manual
`gcloud services enable serviceusage.googleapis.com` step on a fresh
project, the registrar handoff after the first apply, and the teardown
flow that reverses the bootstrap. The
[`main.tf`](https://github.com/RaptGroup/homelab/blob/main/terraform/gcp/main.tf)
in that directory is short enough to read end-to-end; each resource
carries an inline comment explaining why it's shaped the way it is.
