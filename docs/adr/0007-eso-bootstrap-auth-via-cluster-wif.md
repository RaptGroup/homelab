# ADR-0007: ESO bootstrap GCP auth via cluster Workload Identity Federation

- **Status:** Accepted
- **Date:** 2026-05-14

## Context

The bootstrap-time GCP credential that External Secrets Operator (ESO)
uses to read Google Secret Manager has, since the bootstrap root
existed, been a JSON Service Account key minted by Terraform and
written directly into the cluster as a `Secret`. The relevant code in
[`terraform/bootstrap/external-secrets.tf`](../../terraform/bootstrap/external-secrets.tf):

```hcl
resource "google_service_account_key" "eso" { … }

resource "kubernetes_secret" "eso_gcp_sa" {
  metadata { name = "gcp-sm-credentials"; namespace = "external-secrets" }
  data     = { "credentials.json" = base64decode(google_service_account_key.eso.private_key) }
}
```

The `ClusterSecretStore` named `gsm` references that `Secret` via
`auth.secretRef`. The file's comment is explicit:

> This is the ONLY K8s Secret Terraform creates directly — every other
> credential flows through ESO from GSM.

That property exists because ESO is the gate every other credential
passes through; **you cannot bootstrap ESO via ESO**. Every other GCP
credential in the platform — cert-manager's DNS-01 SA key,
`cloudflared`'s tunnel token, the Artifact Registry pull token — lands
in-cluster as an `ExternalSecret` synced from GSM. The bootstrap ESO
credential is the seed that makes the rest of the chain possible.

That made the JSON-key shortcut **load-bearing for bootstrap order**,
not merely a convenience. #139's equivalent shortcut for the AR pull
path (`tf-ci-cluster-pull` JSON key in GSM) had no such ordering
constraint and was straightforward to retire by moving to Workload
Identity Federation against the cluster's own OIDC issuer. The ESO
seed credential is different: there is no in-cluster mechanism that
can pre-populate it before ESO itself is running.

Three things changed between when the shortcut was introduced and
today:

1. **#139 landed a cluster→GCP WIF path end-to-end.** The cluster's
   service-account-issuer is set to a publicly-reachable URL fronted
   by a GCS bucket; the JWKS is published there; a
   `google_iam_workload_identity_pool_provider` in `terraform/gcp/`
   trusts that issuer. The infrastructure to do WIF for a *second*
   workload (ESO, in addition to AR-pull) is already in place — only
   the `workloadIdentityUser` binding for `external-secrets@…` and
   the `ClusterSecretStore`'s `auth.workloadIdentityFederation` block
   are missing.

2. **ESO's GCP-SM provider supports the self-hosted WIF shape
   natively.** `auth.workloadIdentityFederation` with a
   `serviceAccountRef` pointing at a K8s ServiceAccount and an
   explicit `audience` mapping the cluster's WIF provider is the
   documented non-GKE pattern. No external sidecar, no projected-token
   plumbing the operator has to maintain.

3. **The platform's posture on long-lived GCP keys hardened.** After
   #139, the ESO seed key is the **last** long-lived GCP SA key on
   the cluster. Every claim of "the platform is keyless against GCP"
   has to carry an explicit "except this one" footnote until it is
   gone.

The cost of moving ESO onto WIF is concentrated in bootstrap ordering.
Today, `terraform/gcp/` and `terraform/bootstrap/` run back-to-back
non-interactively; the operator runs `tofu apply` in `gcp/` then
`tofu apply` in `bootstrap/` and the cluster comes up. The JWKS upload
that #139 added is **operator-attended and out-of-band** — done once
per cluster lifetime, before AR-canary needs it. AR-canary tolerates
that ordering because it runs only after ArgoCD has reconciled
`kubernetes/apps/`, well after bootstrap completes.

ESO is upstream of all of that. If ESO needs WIF at bootstrap time,
the JWKS must be live in the bucket **before** `terraform/bootstrap/`
runs, not before `kubernetes/apps/ar-canary/` reconciles. That moves
the JWKS upload from "a thing to remember before merging the AR-canary
PR" to "a hard precondition of the bootstrap root succeeding."

The fresh-cluster path tightens the constraint further. On a
brand-new cluster the Talos signing keys don't exist until `talos/`
runs and `secrets.yaml` is generated. The cluster's OIDC discovery
document cannot be published until those keys exist. So the
fresh-cluster bootstrap sequence has to become:

```
terraform/talos/  →  Talos secrets exist (signing keys generated)
                  →  operator uploads OIDC discovery doc + JWKS to GCS
                  →  terraform/gcp/    (WIF pool provider exists already)
                  →  terraform/bootstrap/  (ESO comes up against WIF)
```

Today's sequence is the same minus the JWKS step. The question is
whether the JWKS upload should be a documented manual precondition
(parallel to "ADC login" and "NS delegation"), or whether bootstrap
should keep the JSON-key path as a fallback for the first run and
self-rotate to WIF afterwards. See [Alternatives Considered](#alternatives-considered)
for the rejected paths.

## Decision

**Move the bootstrap-time `ClusterSecretStore gsm` to
`auth.workloadIdentityFederation` against the cluster's existing WIF
pool. The JWKS upload becomes a documented operator-attended
precondition of `terraform/bootstrap/`, alongside the existing
prerequisites.**

Concretely:

1. **Principal shape.** A K8s `ServiceAccount` in the
   `external-secrets` namespace (call it `external-secrets-gsm`) is
   the workload-identity principal. The `external-secrets@<project>`
   GCP SA gains a `roles/iam.workloadIdentityUser` binding keyed on
   that K8s SA's principal under the existing WIF pool (the same pool
   #139 created). The SA keeps its project-scoped
   `roles/secretmanager.secretAccessor` — that part is unchanged.

2. **CSS auth shape.** `ClusterSecretStore gsm`'s `auth` block
   switches from `secretRef` to `workloadIdentityFederation`, with the
   `serviceAccountRef` pointing at the K8s SA above and the `audience`
   set to the WIF provider's full resource path. The deployment-side
   K8s ServiceAccount that runs the ESO controller pod gets the
   `serviceaccount.tokenrequest` permission needed for ESO to project
   a token for `external-secrets-gsm` at runtime — standard ESO
   pattern, documented upstream.

3. **TF removals.** `google_service_account_key.eso` and
   `kubernetes_secret.eso_gcp_sa` come out of
   `terraform/bootstrap/external-secrets.tf`. The "ONLY K8s Secret
   Terraform creates directly" comment goes with them; the property
   is now *no* K8s Secret created directly. The `external-secrets`
   GCP SA's existing project-level role binding stays.

4. **Bootstrap precondition.** `terraform/bootstrap/README.md`
   acquires a new prerequisite: **OIDC discovery document and JWKS
   published**. The README points to the (existing, #139) operator
   procedure: `kubectl get --raw /openid/v1/jwks` and the
   discovery-doc template, uploaded via `gsutil` to the GCS bucket
   that fronts `oidc.lab.jackhall.dev`. Failure mode if the operator
   skips the step: ESO comes up but the `ClusterSecretStore gsm`
   reports `Ready=False` with a token-exchange error, identical
   diagnosis surface to a malformed JSON key today.

5. **Fresh-cluster sequence.** The documented order for a brand-new
   cluster becomes Talos → JWKS upload → GCP → bootstrap. The JWKS
   upload is operator-attended for the same reason ADC login and NS
   delegation are: it is a one-time configuration of state that lives
   outside the cluster's own apply path. Re-running bootstrap on an
   already-bootstrapped cluster does not re-require the upload — the
   JWKS is durable in GCS until Talos signing keys rotate.

6. **No code change in this ADR.** This decision lands as the ADR
   file plus a `terraform/bootstrap/README.md` prerequisite update.
   The actual TF and `ClusterSecretStore` changes ship in a follow-up
   implementation issue. The PR that delivers this ADR closes #164;
   the follow-up issue is filed and linked.

## Consequences

**Positive**

- The bootstrap ESO credential is no longer a long-lived JSON key.
  After this lands and the follow-up implementation issue ships,
  there is **no long-lived GCP SA key anywhere on the platform** —
  the property #139 established for the AR pull path becomes a
  property of the whole cluster.
- One uniform credential shape across every cluster→GCP workload:
  WIF against the cluster's OIDC issuer, no per-workload SA keys.
  The AR-pull WIF binding (#139) and the ESO-seed WIF binding land
  on the same provider, with the same trust shape, differing only
  in which K8s SA principal they trust.
- Removes the lone "this is the ONLY K8s Secret Terraform creates
  directly" exception in the bootstrap. Every credential in the
  cluster now arrives through ESO or is minted by the cluster
  itself; nothing is written by Terraform.
- The "platform keyless against GCP" claim becomes unqualified.
  Every existing footnote ("…except the ESO seed key") in READMEs
  and ADRs can be deleted.

**Negative / ongoing**

- Bootstrap is no longer a clean two-`tofu apply` sequence on a
  fresh cluster. The Talos→JWKS→GCP→bootstrap chain interleaves a
  manual `gsutil cp` step between two Terraform roots. The step is
  one command, durable for the cluster's lifetime, and already
  exists (introduced by #139); the change is that bootstrap now
  blocks on it instead of AR-canary blocking on it. Operator-attended
  bootstrap is acceptable because bootstrap is by construction a
  low-frequency, operator-attended event (see ADR-0004 — only
  `kubernetes/apps/` is CI-driven; the TF roots remain
  operator-applied).
- ESO acquires a startup-time dependency on the GCP STS endpoint
  being reachable and on the GCS bucket fronting the cluster's OIDC
  discovery document being up. The current `secretRef` path has no
  such dependency: a stale JSON key works offline at startup until
  the first GSM call. The new shape moves the network dependency
  forward to credential acquisition itself. ESO caches the exchanged
  token with TTL, so brief STS or GCS outages are masked for
  already-running pods; an outage spanning the cache window blocks
  new token issuance and any ESO controller restart in that window.
- Re-bootstrapping after a Talos signing-key rotation requires
  re-uploading the JWKS to the bucket. The operator procedure exists
  (#139's recipe) but the rotation cadence — never, in steady state
  — means the procedure is exercised infrequently and risks bit-rot.
  Mitigated by the precondition being documented in
  `terraform/bootstrap/README.md` next to the existing prerequisites
  list, so anyone running bootstrap encounters the requirement
  without having to read an ADR.
- The follow-up implementation issue must land before the next fresh
  bootstrap, or the bootstrap will not converge. The current shortcut
  works today; this ADR plus the implementation issue together
  retire it, but neither alone does.

## Alternatives Considered

### A. Keep the JSON key; document the trade-off in an ADR

The status-quo option. Rationale would have been: the bootstrap ESO
credential is the single remaining long-lived GCP key on the platform;
bootstrap is a low-frequency operator-attended operation; the
alternative adds ordering complexity for a credential that already
sits in TF state and rotates trivially via `tofu apply`.

Rejected because the argument's load-bearing premise — "the WIF path
is hard to engineer" — stopped being true once #139 landed the cluster
OIDC issuer, the JWKS hosting, and the WIF pool provider. The
remaining work to put ESO on the same path is materially smaller than
the work #139 itself absorbed; declining to do it now means
permanently accepting "the platform is keyless against GCP, except for
this one credential" as the terminal state. The marginal cost of
keeping the key (a residual long-lived credential, a documented
exception in every keyless-auth claim, a rotation procedure that the
operator must remember) compounds; the marginal cost of removing it
(the bootstrap-order change documented above) is paid once.

### C. Hybrid — JSON key for bootstrap CSS, second WIF-backed CSS for runtime

Keep the existing `ClusterSecretStore gsm` on `secretRef` for
bootstrap-time use; add a second `ClusterSecretStore gsm-wif` on
`auth.workloadIdentityFederation` for runtime ExternalSecrets;
migrate each ExternalSecret across over time.

Rejected on three grounds. **Per-ExternalSecret choice surface:**
every new ExternalSecret manifest in `kubernetes/apps/` would have to
pick a store, with no structural rule for which to use; "the right
one" is a convention enforced only by review attention. **Drift
risk:** the two stores would diverge in subtle ways (one or the other
gets a `refreshInterval` update, an annotation, a maintenance pin)
and the difference would never be reconciled because nothing
structurally requires them to match. **Residual surface unchanged:**
the JSON key still exists, so the "platform keyless against GCP"
claim still carries the footnote. The hybrid pays option B's
implementation cost and keeps option A's residual risk. Strictly
worse than either pure option.

### B-fallback. WIF in steady state, JSON key for fresh-cluster first run

A variant of B that keeps the existing `google_service_account_key`
resource as a fallback used only on the very first apply against a
brand-new cluster (before any JWKS has been uploaded), then
self-rotates to WIF on subsequent applies. Avoids the
operator-attended interleave between Talos secrets and bootstrap by
letting `terraform/bootstrap/` succeed unattended on a fresh cluster.

Rejected. Two code paths in the bootstrap root (which CSS auth shape
is in force depends on cluster state, not config) is exactly the kind
of conditional that bootstrap roots should not carry — it doubles the
test surface, doubles the recovery procedure, and the "first-run vs
subsequent-run" distinction is silent in `tofu plan` output. The
operator-attended JWKS upload that the chosen option requires is
**already operator-attended for #139's AR-pull path**; bootstrap
inheriting that step rather than working around it preserves a single
deterministic apply path. The "unattended fresh-cluster bootstrap"
property the fallback would preserve is not actually load-bearing —
bootstrap is operator-attended either way (ADC login, NS delegation,
and now JWKS upload all require operator presence).
