---
title: CI workflows
description: The three GitHub Actions workflows that gate PRs and publish this site, plus how they pick up self-hosted runners via ARC.
---

The repo has three workflows in
[`.github/workflows/`](https://github.com/RaptGroup/homelab/tree/main/.github/workflows).
Two of them run on every relevant PR and gate the merge; the third
publishes this site on every push to `main`. None of them apply
infrastructure — `tofu apply` and `argocd app sync` remain operator
actions on a workstation with ADC. The point of CI in this repo is to
catch broken manifests and broken Terraform *before* a human runs the
apply.

| Workflow | Trigger | Runner | What it gates |
|---|---|---|---|
| [`apps-lint`](#apps-lint) | PR touching `kubernetes/apps/**`, the workflow file, or `scripts/lint-apps.sh` | GitHub-hosted | Each affected addon renders cleanly and validates against Kubernetes + CRD schemas. |
| [`terraform-plan`](#terraform-plan) | PR touching `terraform/**` or the workflow file | GitHub-hosted | `tofu fmt`, `tofu validate`, and `tofu plan` succeed on every changed root; the plan is posted as a sticky PR comment. |
| [`deploy-docs`](#deploy-docs) | Push to `main` touching `docs/**` or the workflow file (plus manual `workflow_dispatch`) | GitHub-hosted | This site is rebuilt with Astro and published to GitHub Pages. |

Self-hosted [ARC runners](/homelab/applications/arc/) exist in the
cluster but **no repo workflow currently targets them**. The runners
are provisioned for personal projects under
[`RaptGroup`](https://github.com/RaptGroup) and the operator's
[`brazostech`](https://github.com/brazostech) org; this homelab repo
deliberately stays on GitHub-hosted runners so a broken cluster cannot
break its own CI. See [ARC integration](#arc-integration) below for
the contract that lets other repos opt in.

## `apps-lint`

[`.github/workflows/apps-lint.yml`](https://github.com/RaptGroup/homelab/blob/main/.github/workflows/apps-lint.yml)
catches manifest-shape bugs before ArgoCD ever sees them. Two jobs:

- **`detect`** computes the set of affected addons from `git diff`,
  filtering paths under `kubernetes/apps/<name>/` (top-level files in
  `kubernetes/apps/` — the README — do not trigger the lint). If the
  workflow itself or `scripts/lint-apps.sh` changed, **every** addon
  is re-linted to prove the pipeline still works.
- **`lint`** fans out over the detected addons via a matrix and runs
  `scripts/lint-apps.sh <app>` per cell with `fail-fast: false`, so
  one broken addon doesn't mask another.

### What `scripts/lint-apps.sh` does

For each affected `kubernetes/apps/<name>/`:

1. Read the chart coordinates from `application.yaml` (supporting both
   `spec.source` and `spec.sources[]` multi-source Applications).
2. `helm template <name> <chart> --repo <url> --version <v> -f helm-values.yaml --include-crds`
   to render the manifests the cluster would see. OCI repos are folded
   into an `oci://<host>/<chart>` URL since `helm --repo` doesn't
   accept them.
3. `kubeconform -strict -summary` against the rendered output, using
   the [datreeio CRD catalog](https://github.com/datreeio/CRDs-catalog)
   for the CRDs the cluster ships (Cilium, cert-manager, Gateway API,
   External Secrets). A small `SKIP_KINDS` list covers resources whose
   schemas aren't in the catalog (`Application`, `AppProject`,
   `AutoscalingRunnerSet`) or aren't validated on principle
   (`CustomResourceDefinition`).
4. If the addon ships raw manifests under `manifests/`, those are
   `kubeconform`-validated too.
5. A `yq` pass scans rendered Gateways and LoadBalancer Services for
   the `lbipam.cilium.io/ips` annotation and fails if any are
   missing. Without the pin, Cilium's LB IPAM hands out the first
   free address from the pool and a new addon can silently steal an
   IP another addon depends on. The check is presence-only — pool
   membership and value format are Cilium's concern.

Running it locally is identical to running it in CI:

```bash
scripts/lint-apps.sh                       # all addons
scripts/lint-apps.sh kubernetes/apps/foo   # one addon
```

It requires `helm`, `kubeconform`, and `yq` (mikefarah). No cluster
access is needed — `helm template` is offline once the chart is
cached.

## `terraform-plan`

[`.github/workflows/terraform-plan.yml`](https://github.com/RaptGroup/homelab/blob/main/.github/workflows/terraform-plan.yml)
runs on PRs that touch `terraform/**`. The structure mirrors
`apps-lint`: a `detect` job computes the affected roots (`gcp`,
`bootstrap`) and a matrix runs per root.

For each affected root the job runs `tofu fmt -check`, `tofu init
-lockfile=readonly`, `tofu validate`, and `tofu plan -detailed-exitcode`.
The plan output is posted as a [sticky PR
comment](https://github.com/marocchino/sticky-pull-request-comment),
one per root, capped at ~60k chars to stay under GitHub's PR comment
limit. Exit code 2 (changes detected) is the normal state on a
TF-touching PR and does **not** fail the job — the reviewer reads the
plan.

The `bootstrap` root needs special handling: its `k8s`/`helm`/`kubectl`
providers point at a local kubeconfig that doesn't exist in CI, and
the cluster is LAN-only anyway. The workflow writes a stub kubeconfig
so provider validation passes and skips `-refresh` on plan; the
config-level diff is still useful for review.

Authentication is OIDC-based — the workflow exchanges a GitHub-issued
token for a GCP service-account impersonation via Workload Identity
Federation. The pool, provider, and plan-only `tf-ci-plan` service
account are documented in
[Cloud / Workload Identity Federation](/homelab/cloud/gcp/#workload-identity-federation);
the trust is locked to `RaptGroup/homelab` on the provider's
`attribute_condition` and the SA is `roles/viewer` only, structurally
incapable of applying.

CI-side wire-up: the repository variables `GCP_WIF_PROVIDER` /
`GCP_CI_SA` and the secret `GCP_BILLING_ACCOUNT` are set manually
after the first `terraform/gcp/` apply. The workflow's `Verify CI
configuration` step fails loud with the exact `tofu output` commands
to run if any are missing.

## `deploy-docs`

[`.github/workflows/deploy-docs.yml`](https://github.com/RaptGroup/homelab/blob/main/.github/workflows/deploy-docs.yml)
publishes this site. It runs on every push to `main` that changes
`docs/**` (and on manual `workflow_dispatch`):

1. `withastro/action@v6` builds `docs/` with Astro and uploads the
   artifact.
2. `actions/deploy-pages@v5` deploys it to the `github-pages`
   environment.

Pages concurrency is grouped to `pages` with
`cancel-in-progress: false` so two rapid pushes don't trample each
other's deploys — the second waits for the first to finish. The
deployed URL is whatever GitHub Pages reports back via
`steps.deployment.outputs.page_url` (currently
[`raptgroup.github.io/homelab`](https://raptgroup.github.io/homelab/)).

There is no preview deploy on PRs — the site is rebuilt on merge and
docs PRs are reviewed against the rendered markdown in the diff.

## ARC integration

The cluster's [ARC runners](/homelab/applications/arc/) sit idle until
a workflow with a matching `runs-on:` lands in one of the orgs the
GitHub App is installed on. Two scale sets, two orgs:

| Scale set | Target org | Canonical `runs-on:` |
|---|---|---|
| `arc-runners-raptgroup` | [`RaptGroup`](https://github.com/RaptGroup) | `[self-hosted, raptgroup]` |
| `arc-runners-brazostech` | [`brazostech`](https://github.com/brazostech) | `[self-hosted, brazostech]` |

The full label set per pool and the alternative `runs-on:` forms are
on the [ARC runners page](/homelab/applications/arc/#runs-on-label-conventions).

### Where the credentials come from

A workflow scheduled to a pool runs in an ephemeral pod whose lifetime
is bounded by one job. The credentials chain that lets the pool's
listener register that pod with GitHub is:

```
Google Secret Manager (terraform/gcp/)
    │   arc-app-id, arc-app-private-key,
    │   arc-installation-id-{raptgroup,brazostech}
    ▼
External Secrets Operator  (ClusterSecretStore/gsm)
    │   ExternalSecret per pool → K8s Secret in the pool's namespace
    ▼
gha-runner-scale-set chart  (githubConfigSecret)
    │
    ▼
listener pod → GitHub API → ephemeral runner pods
```

App ID and private key are shared across both pools; the installation
ID is per-org and is what scopes a pool to one set of repos. The
[Cloud / Secret Manager](/homelab/cloud/gcp/#secret-manager) table
lists each container by ID; the
[External Secrets Operator](/homelab/platform/external-secrets/) page
covers the GSM↔ESO bridge in general; the
[ARC runners](/homelab/applications/arc/#one-app-two-installations)
page covers the App-and-installations model and why rotating either
piece is a GSM update plus a listener restart.

The access boundary is server-side: the App is installed on
`RaptGroup` and `brazostech`, **not** on Scale Computing (the
operator's employer). Even from inside a brazostech runner pod, an
installation token cannot reach a Scale Computing repo. There is no
client-side allow/deny list to maintain.

### How another repo opts in

Three steps, from the perspective of a repo in `RaptGroup` or
`brazostech`:

1. Confirm the homelab GitHub App is installed on the target org
   (operator action, one-time).
2. Add the desired `runs-on:` to the workflow — e.g. `runs-on:
   [self-hosted, raptgroup]`.
3. Open the PR. On dispatch, the pool's listener scales 0 → 1, the
   ephemeral pod runs the job, and the pod is torn down within a
   minute or two of completion.

`maxRunners: 4` per pool is a deliberate ceiling. Workloads bursty
enough to need more concurrency are better served by paying for
GitHub-hosted runners than by sizing the homelab around CI peaks.

## Adding a new workflow

The mental model for "what gates a PR" in this repo:

- **`kubernetes/apps/<name>/` changes** → `apps-lint` re-renders and
  re-validates that addon. New CRDs that aren't in the datreeio catalog
  need a `SKIP_KINDS` entry in `scripts/lint-apps.sh`; new LB-bearing
  resources need the `lbipam.cilium.io/ips` annotation or the lint
  fails.
- **`terraform/**` changes** → `terraform-plan` posts a plan comment
  per affected root. A new root means a new entry in the `candidates`
  list in the workflow's `detect` job; the matrix and PR comment shape
  flow from there automatically.
- **`docs/**` changes** → no PR gate; the site rebuilds on merge.
  Reviewers see the rendered markdown in the diff.
- **Talos config, smoke scripts, READMEs outside `kubernetes/apps/`**
  → no automated check. Reviewers verify by hand; changes that affect
  the cluster are applied by the operator.

Conventions to keep new workflows consistent with the existing three:

- Use `pull_request` with a tight `paths:` filter so unrelated PRs
  don't trigger the workflow. The `detect` jobs above show the
  "compute affected subset from `git diff`, fan out via matrix"
  pattern when a workflow needs to lint multiple independent things.
- Set a `concurrency.group` keyed on the head ref with
  `cancel-in-progress: true` so a force-push supersedes the in-flight
  run. The `deploy-docs` workflow is the exception — Pages deploys
  are serialised, not cancelled.
- Default to GitHub-hosted runners. Targeting `self-hosted` on a repo
  in this homelab would create a circular dependency: a broken cluster
  would break its own CI. The ARC pools exist for *other* repos in
  `RaptGroup` and `brazostech`.
- If the workflow needs to authenticate to GCP, reuse the WIF pool —
  add a new plan-only service account with the narrowest roles the
  workflow needs and a `workloadIdentityUser` binding scoped to this
  repo. Do not mint long-lived JSON keys.

## More

- [`scripts/lint-apps.sh`](https://github.com/RaptGroup/homelab/blob/main/scripts/lint-apps.sh)
  — the script behind `apps-lint`.
- [Cloud / Workload Identity Federation](/homelab/cloud/gcp/#workload-identity-federation)
  — the WIF pool, provider trust scope, and plan-only `tf-ci-plan` SA
  the `terraform-plan` workflow authenticates against.
- [`terraform/gcp/README.md`](https://github.com/RaptGroup/homelab/blob/main/terraform/gcp/README.md#ci-github-actions-auth)
  — operator run book for the WIF pool, including how to extract the
  values for `GCP_WIF_PROVIDER` and `GCP_CI_SA`.
- [ARC runners](/homelab/applications/arc/) — the in-cluster pools
  themselves.
