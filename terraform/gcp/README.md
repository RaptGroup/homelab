# terraform/gcp

Provisions the GCP-side foundation for the Rockingham Homelab in a single
dedicated project (`rockingham-homelab` by default):

- The GCP project itself, with `deletion_policy = "DELETE"` so the whole
  footprint can be torn down as one unit.
- Cloud DNS managed zone for `lab.jackhall.dev`.
- Service account for cert-manager's DNS-01 solver (`roles/dns.admin`
  scoped to the zone, not the project).
- Service account for External Secrets Operator
  (`roles/secretmanager.secretAccessor` at the project level).
- GCS bucket `rockingham-homelab-tfstate` holding Terraform state for
  this and any future homelab roots.
- GSM secret `talos-cluster-secrets` (container only — versions are
  uploaded out of band) backing up `talos/_out/secrets.yaml`. See
  [`talos/README.md`](../../talos/README.md) for the upload + restore
  commands.
- Workload Identity Federation pool + GitHub OIDC provider, plus two
  CI service accounts: a plan-only SA (`roles/viewer`) consumed by the
  [`terraform-plan` workflow](../../.github/workflows/terraform-plan.yml),
  and an apply SA (`roles/owner`) consumed by the
  [`terraform-apply` workflow](../../.github/workflows/terraform-apply.yml)
  whose impersonation is gated on the `gcp` GitHub deployment
  environment (see ADR-0004).
- Artifact Registry repository `projects` (Docker, regional in
  `us-east4`) for preview-environment images (ADR-0006), plus a second
  WIF provider scoped to the ARC repository allowlist, a push SA
  (`tf-ci-arc-push`, repo-scoped `roles/artifactregistry.writer`)
  impersonable from any allowlisted repo's workflows, and a pull SA
  (`tf-ci-cluster-pull`, repo-scoped `roles/artifactregistry.reader`)
  whose JSON key lives in a GSM container consumed in-cluster by
  [`kubernetes/apps/ar-canary/`](../../kubernetes/apps/ar-canary).

State lives in `gs://rockingham-homelab-tfstate/terraform/gcp/` so local
and CI applies share the same state. The bucket is created by this same
root, so the very first apply on a fresh GCP account is local-state; see
"Bootstrap from scratch" below.

## Prerequisites

1. Authenticated `gcloud` ADC for Terraform to use:

   ```sh
   gcloud auth application-default login
   ```

2. A billing account ID — the project is created here but must be linked
   to billing or the Cloud DNS / Secret Manager APIs won't function. List
   your accounts:

   ```sh
   gcloud billing accounts list
   ```

3. The principal running `tofu apply` needs, at minimum:
   - `roles/resourcemanager.projectCreator` on the parent (org/folder) or
     no parent for personal accounts.
   - `roles/billing.user` on the billing account being linked.

## Inputs

Set these via a `terraform.tfvars` file (gitignored) or `-var` flags.
`terraform.tfvars` example:

```hcl
billing_account = "0X0X0X-0X0X0X-0X0X0X"
# org_id    = "123456789012"   # only if you have an org
# folder_id = "123456789012"   # mutually exclusive with org_id
```

`project_id` defaults to `rockingham-homelab`. Override only if that ID
is taken globally.

## APIs

`tofu apply` enables these on the new project:

- `cloudresourcemanager.googleapis.com`
- `iam.googleapis.com`
- `dns.googleapis.com`
- `secretmanager.googleapis.com`
- `storage.googleapis.com`
- `artifactregistry.googleapis.com`

`disable_on_destroy = false` so a partial destroy doesn't disable APIs
that other tooling (gcloud, the console) might still need before the
project itself goes away.

## Run

```sh
cd terraform/gcp
tofu init       # configures the GCS backend
tofu plan
tofu apply
```

A second `tofu plan` immediately after a successful apply must show
`No changes`. If it doesn't, that's a bug — open an issue.

## Bootstrap from scratch

If the GCS state bucket doesn't yet exist (true on a clean GCP account,
or after `tofu destroy`), the first `tofu init` against the GCS backend
fails — there's nothing to read. Two-phase recipe:

1. Comment out the `backend "gcs"` block in `versions.tf`.
2. `tofu init && tofu apply` — uses local state, creates the project,
   APIs, DNS zone, SAs, and the state bucket itself.
3. Uncomment the backend block.
4. `tofu init -migrate-state` — copies the local state into the bucket.
5. Delete the local `terraform.tfstate*` files (gitignored anyway).

After that, every machine and CI runner that authenticates to GCP
shares the same state.

## Registrar handoff

After the first apply, grab the four NS records and paste them into the
registrar managing `jackhall.dev` as an `NS` record set for the `lab`
subdomain:

```sh
tofu output -json lab_zone_name_servers
```

Until those NS records propagate, ACME DNS-01 challenges will fail
because public resolvers can't reach the Cloud DNS zone.

## Teardown

`tofu destroy` won't work end-to-end while state lives in the bucket
that's about to be destroyed. The recipe is the bootstrap-from-scratch
flow in reverse:

1. `tofu init -migrate-state` after switching the backend back to local
   (or `tofu state pull > terraform.tfstate` then comment out the
   backend block).
2. `tofu destroy`.

Because the project is owned by Terraform with `deletion_policy = DELETE`,
this removes the project itself — taking the DNS zone, state bucket,
service accounts, and any GSM secrets created later with it. There is a
30-day soft-delete window during which `gcloud projects undelete
<project_id>` can recover it.

## CI: GitHub Actions auth

`.github/workflows/terraform-plan.yml` and
`.github/workflows/terraform-apply.yml` run on GitHub-hosted runners
(not in-cluster ARC) and authenticate to GCP via Workload Identity
Federation — no JSON keys. This root creates the federation:

- A pool `github-actions` trusting GitHub's OIDC issuer.
- A provider `github` in that pool, with an `attribute_condition`
  that rejects any token whose `repository` claim isn't
  `var.github_repository`. A leaked OIDC token from another repo
  cannot reach this project.
- Two CI service accounts:

  | Service account            | Project role  | Used by                    | Impersonable from                                                                      |
  |----------------------------|---------------|----------------------------|----------------------------------------------------------------------------------------|
  | `tf-ci-plan` (default ID)  | `roles/viewer`| `terraform-plan.yml`       | Any workflow job in `var.github_repository`                                            |
  | `tf-ci-apply` (default ID) | `roles/owner` | `terraform-apply.yml`      | Only jobs that declare `environment: gcp` (env-scoped WIF binding; see ADR-0004)       |

  The plan SA is structurally insufficient to mutate anything; the
  apply SA can mutate everything but is reachable only from a job
  that opts into the `gcp` GitHub deployment environment. The provider
  attribute mapping exposes both `attribute.repository` and
  `attribute.environment`; the apply SA's `roles/iam.workloadIdentityUser`
  binding keys on `principalSet://…/attribute.environment/gcp` so the
  combined gate is equivalent to
  `repo:RaptGroup/homelab:environment:gcp`.

After the first apply, wire both workflows up by setting these GitHub
**Actions repository variables** (Settings → Secrets and variables →
Actions → Variables) to the values printed by `tofu output`:

| Repository variable | Value                                                    |
|---------------------|----------------------------------------------------------|
| `GCP_WIF_PROVIDER`  | `tofu output -raw ci_workload_identity_provider`         |
| `GCP_CI_SA`         | `tofu output -raw ci_service_account_email`              |
| `GCP_APPLY_SA`      | `tofu output -raw ci_apply_service_account_email`        |

And one **Actions secret**, so `terraform plan`/`apply` can satisfy
the `billing_account` variable in CI without a tracked tfvars file:

| Secret                | Value                                                  |
|-----------------------|--------------------------------------------------------|
| `GCP_BILLING_ACCOUNT` | The same billing account ID used in `terraform.tfvars` |

Then create the **`gcp` deployment environment** in the GitHub UI
(Settings → Environments → New environment, name `gcp`) with:

- **Deployment branch restriction:** `Selected branches and tags` →
  add `main`. The env-scoped WIF binding only restricts
  *impersonation*; the GitHub-side branch rule keeps a fork or
  feature-branch dispatch from queueing an apply at all.
- **Required reviewer:** the repo owner. The apply job pauses for
  approval at run time, regardless of who dispatched it.

Without the environment in place, the `apply` job in
`terraform-apply.yml` will queue indefinitely waiting for an
environment that doesn't exist. Without the deployment-branch rule,
a workflow run on a feature branch could attempt to opt into the
environment.

Until the four repo values above are set, both workflows fail loudly
at their first step with an error message pointing here — chosen
over a silent skip so a missing wire-up surfaces in the PR check
rather than hiding. For `terraform-plan.yml`, `fmt` and change
detection do not depend on auth and still gate the PR independently.

`terraform-apply.yml` re-plans on every run with `-detailed-exitcode`
and only proceeds to apply if the exit code is `2` (changes
detected). The apply job downloads the exact `tfplan` binary the
plan job produced, so what gets applied is what the reviewer
approved — not a re-derived second plan that could legitimately
diverge if state changed in between.

The workflow runs on two triggers: manual `workflow_dispatch`, and
`push` to `main` filtered to paths under `terraform/gcp/**` or the
workflow file itself. Merging a PR that doesn't touch those paths
does not trigger an apply. A top-level `concurrency` group
(`terraform-apply-gcp`, `cancel-in-progress: false`) serializes runs
so two rapid merges queue rather than cancel — cancelling an
in-flight `tofu apply` would leave a held state lock and possibly
half-modified resources. Auto-triggered runs go through the same
`gcp` environment gate as manual dispatches; the trigger only
controls when the workflow starts, not whether the apply step
requires approval.

### Bootstrap: enabling CI apply on a fresh project

The `tf-ci-apply` SA has to exist before any workflow can impersonate
it, so the first apply that creates it is necessarily local:

1. Operator runs `tofu apply` locally to land the `tf-ci-apply` SA,
   the `roles/owner` binding, the env-scoped WIF binding, and the
   provider's `attribute.environment` mapping.
2. Operator copies the new output value into the GitHub repo
   variable: `GCP_APPLY_SA = $(tofu output -raw ci_apply_service_account_email)`.
3. Operator creates the `gcp` GitHub deployment environment in the UI
   with the protection rules above.
4. From this point on, dispatching `terraform-apply.yml` via
   `gh workflow run terraform-apply.yml` re-plans against current
   state, surfaces the diff in the job log, pauses for environment
   approval if there is a diff, and applies the approved plan.

## Artifact Registry: preview-env images

The `projects` Artifact Registry repository (Docker, regional in
`us-east4`) holds preview-environment images per
[ADR-0006](../../docs/adr/0006-public-preview-environments-via-cloudflare-tunnel.md).
Image paths look like:

```
us-east4-docker.pkg.dev/rockingham-homelab/projects/<workload>:<tag>
```

The repository name `projects` mirrors the public preview subzone
`projects.jackhall.dev` so an operator reading either path knows
they're looking at the same surface. Cleanup policies delete
untagged blobs after 7 days and tagged versions after 90 days —
preview tags churn naturally with PR lifecycle, the cleanup just
keeps the floor stable.

Two service accounts back the pull/push split. Both roles are
**repository-scoped**, not project-wide — neither SA can reach
anything else in `rockingham-homelab`:

| Service account                  | Role                              | Used by                                   |
|----------------------------------|-----------------------------------|-------------------------------------------|
| `tf-ci-arc-push` (default ID)    | `roles/artifactregistry.writer`   | ARC-pool workflows (push)                 |
| `tf-ci-cluster-pull` (default ID)| `roles/artifactregistry.reader`   | In-cluster workloads (pull)               |

### Push: ARC → AR via WIF

A dedicated WIF provider `github-arc` lives in the same
`github-actions` pool as the existing plan/apply providers but with
a wider `attribute_condition` matching any repository in
`var.arc_push_repository_allowlist` (defaults: `RaptGroup/homelab`
and `RaptGroup/zipmenu-public`; extend to brazostech repos when
those exist). The push SA's `workloadIdentityUser` bindings are
per-repo principalSets keyed on `attribute.repository`, so the
allowlist is enforced at both the pool boundary and the
SA-binding level — defense in depth.

The existing `github` provider (locked to `RaptGroup/homelab` for
the plan/apply SAs) is unchanged. Widening that provider's repo
gate would also widen `tf-ci-apply`'s reachable token set
(apply's principalSet keys on `attribute.environment` alone), so
ARC push gets its own provider rather than relaxing the apply gate.

After the first apply that lands these resources, wire them up in a
workflow with the `google-github-actions/auth@v2` action:

```yaml
permissions:
  id-token: write
  contents: read

steps:
  - uses: google-github-actions/auth@v2
    with:
      workload_identity_provider: ${{ vars.GCP_ARC_WIF_PROVIDER }}
      service_account:            ${{ vars.GCP_ARC_PUSH_SA }}
  - run: gcloud auth configure-docker us-east4-docker.pkg.dev --quiet
  - run: docker push us-east4-docker.pkg.dev/${{ vars.GCP_PROJECT_ID }}/projects/<workload>:<tag>
```

Set these GitHub **Actions repository variables** to the values
printed by `tofu output`:

| Repository variable     | Value                                                  |
|-------------------------|--------------------------------------------------------|
| `GCP_ARC_WIF_PROVIDER`  | `tofu output -raw arc_workload_identity_provider`      |
| `GCP_ARC_PUSH_SA`       | `tofu output -raw arc_push_service_account_email`      |
| `GCP_AR_REPO_URL`       | `tofu output -raw artifact_registry_repository_url`    |

### Pull: cluster → AR via in-namespace ESO generator

Talos has no GKE-style workload identity, so the cluster authenticates
to AR with a JSON key for `tf-ci-cluster-pull`. The key value lives in
GSM (container TF-managed here, value uploaded out of band — same
pattern as `argocd-repo-ssh-key`, `arc-app-private-key`, and
`talos-cluster-secrets`). Inside the cluster, an ESO
`GCRAccessToken` generator exchanges the key for a short-lived
OAuth access token every 30 minutes; the resulting
`kubernetes.io/dockerconfigjson` Secret is what Pods reference as
`imagePullSecrets`. See
[`kubernetes/apps/ar-canary/`](../../kubernetes/apps/ar-canary)
for the canary deployment that exercises this path end-to-end.

After the first apply, mint and upload the JSON key (one-time;
re-run for rotation):

```sh
gcloud iam service-accounts keys create /tmp/cluster-pull.json \
  --iam-account=$(tofu output -raw cluster_pull_service_account_email) \
  --project=$(tofu output -raw project_id)
gcloud secrets versions add $(tofu output -raw cluster_pull_sa_key_secret_id) \
  --project=$(tofu output -raw project_id) \
  --data-file=/tmp/cluster-pull.json
shred -u /tmp/cluster-pull.json
```

The cluster→GCP WIF path (no key at all) would require publishing
the Talos cluster's OIDC discovery document to a public endpoint
and configuring a WIF pool with the cluster as a trusted identity
provider — a meaningfully larger project deliberately out of scope
for #125. The repo-scoped reader role bounds blast radius if the
key leaks, and the 30-minute dockerconfigjson rotation bounds how
long any stolen Pod-mounted credential stays usable.

## Outputs

| Output                                | Used by                                                          |
|---------------------------------------|------------------------------------------------------------------|
| `lab_zone_name_servers`               | Operator → registrar (manual)                                    |
| `lab_zone_name`                       | `terraform/bootstrap/` cert-manager `ClusterIssuer` config       |
| `cert_manager_sa_email`               | `terraform/bootstrap/` (creates the SA key K8s Secret)           |
| `eso_sa_email`                        | `terraform/bootstrap/` (creates the SA key K8s Secret)           |
| `project_id`                          | Anything that needs to qualify GSM secret refs                   |
| `project_number`                      | Some GCP APIs / IAM bindings require the numeric form            |
| `tfstate_bucket`                      | Other TF roots' backend blocks (hardcoded; this is just a sanity output) |
| `ci_workload_identity_provider`       | `GCP_WIF_PROVIDER` Actions repository variable                   |
| `ci_service_account_email`            | `GCP_CI_SA` Actions repository variable                          |
| `ci_apply_service_account_email`      | `GCP_APPLY_SA` Actions repository variable                       |
| `arc_workload_identity_provider`      | `GCP_ARC_WIF_PROVIDER` Actions repository variable               |
| `arc_push_service_account_email`      | `GCP_ARC_PUSH_SA` Actions repository variable                    |
| `artifact_registry_repository_url`    | `GCP_AR_REPO_URL` Actions repository variable; image-path prefix |
| `cluster_pull_service_account_email`  | Operator → `gcloud iam service-accounts keys create` (key mint)  |
| `cluster_pull_sa_key_secret_id`       | Operator → `gcloud secrets versions add` (key upload)            |
