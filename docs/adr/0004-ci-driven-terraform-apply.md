# ADR-0004: CI-driven `terraform/gcp/` apply, env-gated and WIF-scoped

- **Status:** Accepted (amended 2026-05-13 — generalised pattern to `terraform/cloudflare/`)
- **Date:** 2026-05-10

## Context

Up to this point, every `tofu apply` against `terraform/gcp/` was an
operator action on a workstation with `gcloud` ADC. CI ran `tofu plan`
only — the plan SA (`tf-ci-plan`) holds `roles/viewer` and is
structurally incapable of mutating anything. `terraform/gcp/README.md`
called this out explicitly:

> The workflow never runs `tofu apply` — apply stays operator-only on a
> workstation with ADC.

That stance was load-bearing while the CI plumbing (Workload Identity
Federation, `attribute_condition` repo lock, `GCP_BILLING_ACCOUNT`
secret) was still being shaken out. With it stable, the operator-only
constraint has costs:

- Every TF change requires the operator at a workstation with ADC
  before the change can land in GCP. There is no way to recover the
  cluster from a fresh laptop without first reproducing the local
  toolchain.
- The diff between "what was reviewed in the PR plan" and "what the
  operator's local apply produced" is implicit. The PR shows a plan
  generated against the same state, but the actual apply happens
  against a state that may have changed in the interval.
- Bootstrap-from-scratch instructions in the README still work, but
  routine adds (a new GSM secret, a new SA) carry workstation friction
  that has nothing to do with reviewing the change.

The constraint that has not changed: any path that lets CI apply needs
a stronger boundary than "the workflow is on the main branch." A leaked
OIDC token, a misconfigured workflow, or a malicious PR that inserts a
new workflow file must not be able to mint apply credentials. The
existing repo-locked WIF provider is a necessary boundary but not a
sufficient one for `roles/owner`.

GitHub deployment environments provide the missing layer. An
environment carries deployment-branch restrictions (only `main` can
deploy) and required reviewers (apply must be human-approved at run
time), and the OIDC token issued for a job with `environment: <name>`
includes the environment name as a claim that GCP's WIF can key on.
The pieces compose: the WIF binding can require the environment claim,
which only `main`-branch workflows that opt into the environment can
produce, which only fires after a reviewer approves.

## Decision

**Apply `terraform/gcp/` from a CI workflow whose apply credentials are
gated by a `gcp` GitHub deployment environment, with apply-time WIF
impersonation scoped to OIDC tokens that carry that environment claim.**
Concretely:

1. **Two service accounts, one per phase.**
   - `tf-ci-plan` keeps `roles/viewer` and remains the only SA
     impersonable from any plan-style workflow (no environment
     restriction). Pre-existing.
   - `tf-ci-apply` is new, holds `roles/owner` on the project, and
     can only be impersonated by jobs that present an OIDC token
     whose `environment` claim equals `gcp`.
2. **Env-scoped WIF binding.** The `roles/iam.workloadIdentityUser`
   binding on `tf-ci-apply` keys on
   `principalSet://…/attribute.environment/gcp`. Combined with the
   provider's existing `attribute_condition` (which pins `repository`
   to `RaptGroup/homelab`), this is equivalent to the
   `repo:RaptGroup/homelab:environment:gcp` selector GitHub documents
   for env-scoped OIDC.
3. **GitHub environment `gcp`.** Created manually in the UI with:
   - Deployment branch restriction = `main`.
   - Required reviewer = repo owner.
   This is enforced by GitHub before the workflow's apply job receives
   credentials.
4. **Workflow shape.** `.github/workflows/terraform-apply.yml`,
   `workflow_dispatch`-only (Slice 1; `push:main` is a Slice 2
   decision). Two jobs:
   - `plan` runs as `tf-ci-plan`, executes
     `tofu plan -detailed-exitcode -out=tfplan`, and uploads `tfplan`
     as a workflow artifact. Exits clean on `0` (no changes) or `2`
     (changes); fails on anything else.
   - `apply` declares `environment: gcp`, gates on
     `needs.plan.outputs.exitcode == '2'`, re-auths as
     `tf-ci-apply`, downloads the `tfplan` artifact, and runs
     `tofu apply tfplan`.
5. **No drift between reviewed plan and applied plan.** The apply job
   applies the exact `tfplan` binary the plan job produced. A
   second-pass plan in the apply job could legitimately diverge from
   the first if state changed between them, which would defeat the
   approval.
6. **Naming convention.** Environment names mirror Terraform root
   names. The `gcp` environment gates `terraform/gcp/`; if the
   `bootstrap` root ever grows a CI apply, it gets a `bootstrap`
   environment with its own approver list.

The bootstrap order — `tf-ci-apply` SA must exist before any workflow
can impersonate it — is documented in `terraform/gcp/README.md` and
deliberately unchanged here: the operator runs `tofu apply` once
locally to create the SA and the env-scoped WIF binding, sets the
`GCP_APPLY_SA` repo variable, creates the environment in the GitHub
UI, and from then on apply runs in CI.

## Consequences

**Positive**

- TF changes that produce a clean PR plan can land in GCP without
  workstation friction. Cluster recovery from a fresh laptop becomes
  "open the repo, dispatch the workflow, approve."
- The plan reviewed in the PR and the plan applied in CI are the same
  bytes — the apply job applies the artifact from the plan job, not a
  re-derived second plan.
- `roles/owner` is reachable only via a token that carries the
  `environment: gcp` claim. A workflow that omits the environment, or
  a workflow on a branch other than `main`, cannot mint an apply
  credential even if it successfully checks out the repo.
- Required reviewer on the `gcp` environment puts a human in the
  approval path at run time, not just at PR review. A merged-but-bad
  change still pauses for explicit dispatch + approval before
  reaching GCP.
- The plan/apply SA split means a token compromised mid-plan cannot
  apply.

**Negative**

- Two SAs to keep in mind. Adding a future Terraform root that needs
  CI apply means another SA, another env-scoped WIF binding, and
  another environment in the GitHub UI. The pattern is regular but
  the per-root tax is real.
- The `gcp` environment lives in the GitHub UI. There is no
  Terraform resource for "GitHub deployment environment" in this
  repo, so the protection rules (branch restriction, required
  reviewer) are documented but not codified. A reviewer who removes
  the protection rules in the UI silently weakens the boundary; the
  TF side has no visibility into the GitHub environment state.
- Bootstrap ordering grows one step. The first apply on a fresh GCP
  project is still local (chicken/egg: the apply SA does not yet
  exist), and the operator has to remember to set `GCP_APPLY_SA` and
  create the environment before the workflow can succeed end-to-end.
- `roles/owner` is broad. Narrower predefined roles either don't
  cover everything in this root (the WIF pool/provider, project IAM
  bindings, the tfstate bucket) or split coverage across so many
  bindings that the boundary stops being meaningful at homelab scale.
  The boundary that matters is the impersonation gate, not the IAM
  role inside the SA.
- The plan binary is portable across runs only as long as the
  OpenTofu version and the lockfile-pinned providers match between
  the plan and apply jobs. Both jobs pin `TOFU_VERSION` and use
  `-lockfile=readonly`, so this holds — but a careless edit to one
  job that drifts the version is a foot-gun the workflow will not
  catch until apply.

## Alternatives considered

### Keep apply operator-only

Rejected. This was the prior position and it works, but the cost of
"operator at a workstation" for routine changes (a new GSM secret, a
new addon SA) is paid every time the cluster grows. The boundary that
made operator-only the right answer — that CI couldn't be trusted with
apply credentials — is solvable with env-scoped WIF; not solving it
ports the friction forward indefinitely.

### CI apply gated only by branch (no environment)

Rejected. The repo-lock on the WIF provider plus a
`push:main`-only workflow trigger does keep apply credentials out of
PR forks and feature branches. But the boundary collapses if a
future workflow file on `main` accidentally (or maliciously) does the
WIF auth and runs `tofu apply` — there's no per-job gate, no required
reviewer, and no way to make the apply SA structurally unreachable
from a workflow that doesn't opt in. Environments add a per-job
authorization step that branches alone cannot.

### CI apply with a long-lived JSON key

Rejected. The whole reason this repo's CI uses WIF is to avoid
distributing JSON SA keys. A key for an owner-level SA stored as a
GitHub secret is exactly the failure mode WIF was adopted to prevent
— exfiltration risk plus rotation tax. The env-gated WIF path
delivers stronger isolation (per-job claim, not per-secret value)
with no key material at rest.

### `terraform plan` then human runs `terraform apply` from the plan binary on a workstation

Rejected. This is a mechanical optimization of the operator-only flow
that solves none of its problems: the workstation is still in the
loop, ADC is still required, and the only thing saved is "typing
`tofu plan` again." The valuable property — that the bytes applied
are the bytes reviewed — is achievable inside CI by handing the
`tfplan` artifact between jobs, which is what this ADR does.

### Use a GitHub-hosted reviewer-required PR check instead of an environment

Rejected. PR-level required-reviews already gate merge to `main`, but
they don't gate run-time credential issuance. An environment with
required reviewers fires when the workflow asks for the credentials,
not when the PR is reviewed; a PR can be reviewed and merged on
Friday and the apply held until Monday with no further code change.
That decoupling is the point.

## Amendment — 2026-05-13: generalised to `terraform/cloudflare/`

The original ADR scoped the pattern to `terraform/gcp/`. Per #131,
the same shape is now applied to `terraform/cloudflare/` (added in
#126), with one variation worth recording:

**The `cloudflare` apply SA is not `roles/owner`.** The gcp root
legitimately creates and destroys everything in the project, so
`roles/owner` on `tf-ci-apply` was the only role that didn't either
miss something or split coverage across so many bindings that the
boundary stopped being meaningful. The cloudflare root's GCP-side
surface is much smaller — two GSM bindings (`secretAccessor` on
`cloudflare-api-token`, `secretVersionAdder` on
`cloudflare-tunnel-token`) plus state I/O against the tfstate
bucket — so `tf-ci-apply-cloudflare` holds exactly that and nothing
else. `roles/owner` here would re-create `tf-ci-apply`'s blast
radius for no functional gain.

The rest of the pattern is unchanged:

- Same env-scoped WIF binding shape (`attribute.environment/cloudflare`),
  reusing the existing `github` provider's repo lock; combined gate
  is equivalent to `repo:RaptGroup/homelab:environment:cloudflare`.
- Same plan/apply split: `tf-ci-plan` runs the plan (widened with a
  per-secret `secretAccessor` on `cloudflare-api-token` so the
  Cloudflare provider can be instantiated at plan time), and the
  apply job re-auths as `tf-ci-apply-cloudflare`.
- Same `apply tfplan` artifact handoff — bytes applied are bytes
  reviewed.
- Same `cloudflare` GitHub deployment environment with deployment-
  branch restriction = `main` and required reviewer = repo owner,
  created manually in the UI in parallel to `gcp`.
- Same matrix-based `terraform-plan.yml` for PR plans across all
  roots; new per-root `terraform-apply-cloudflare.yml` mirrors the
  `terraform-apply.yml` shape (one apply workflow per root, keyed to
  its own deployment environment).

**Most of the cloudflare apply boundary is Cloudflare-side.** The CF
API token is scoped at mint time to specific permissions on a single
zone + the account's Tunnel API; narrowing the apply surface happens
there, not in the GCP SA. The GSM container holds the operator-minted
token; rotation is a re-mint + a `gcloud secrets versions add`, never
a TF state mutation.

**Bootstrap order grows one step per added root.** Provisioning the
`tf-ci-apply-cloudflare` SA, its env-scoped WIF binding, its three
IAM bindings, and the `GCP_APPLY_SA_CLOUDFLARE` repo variable is a
one-time operator action documented in `terraform/gcp/README.md`.
The `cloudflare` environment in the GitHub UI is the only piece TF
cannot codify, identical to the situation for `gcp`.

The original ADR's negative consequence about per-root tax is now
observable: two SAs become three, the bootstrap checklist grows, and
the GitHub environments list grows. The pattern is regular, the tax
is real, and at three roots the regularity is more valuable than the
tax is painful.
