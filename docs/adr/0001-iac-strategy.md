# ADR-0001: IaC strategy — thin Terraform plus ArgoCD app-of-apps

- **Status:** Accepted
- **Date:** 2026-05-10

## Context

The cluster has to come up from "empty Talos" to a self-managing addon
platform with a single, well-understood path for adding the next thing.
Two distinct surfaces need infrastructure-as-code:

- **GCP-side resources** — the Cloud DNS zone for `lab.jackhall.dev`,
  service accounts for cert-manager and ESO, Google Secret Manager
  entries, the Terraform state bucket. These are conventional cloud
  resources and Terraform handles them well.
- **Cluster-side resources** — the CNI, the certificate issuer, the
  secrets operator, ArgoCD itself, plus every addon that follows. These
  are Kubernetes objects that benefit from continuous reconciliation,
  not one-shot apply.

There is a chicken-and-egg seam: ArgoCD cannot manage itself before it
exists, and several addons (Cilium, cert-manager, ESO) must be present
before ArgoCD has anything to reconcile against. Something has to run
the bootstrap.

The operator is one person at homelab scale, with prior production
experience using Terraform for cloud resources and ArgoCD for
Kubernetes state.

## Decision

Use **Terraform for the bootstrap and GCP, ArgoCD for everything else.**
Concretely:

1. Two — and only two — Terraform roots:
   - `terraform/gcp/` owns GCP resources (DNS zone, SAs, GSM secrets,
     GCS state bucket).
   - `terraform/bootstrap/` owns the cluster-side chicken-and-egg
     pieces in this fixed order: Gateway API CRDs → Cilium →
     cert-manager → External Secrets Operator (with the GSM bootstrap
     SA key as the one Terraform-managed Kubernetes `Secret`) →
     local-path-provisioner → ArgoCD → the root `Application`.
2. ArgoCD self-manages via an `Application` it watches itself, so chart
   upgrades happen through a PR.
3. A single root `Application` watches `kubernetes/apps/`; adding an
   addon means dropping a `kubernetes/apps/<name>/` directory with an
   `application.yaml` plus `helm-values.yaml` and pushing.
4. After bootstrap, Terraform is touched only to add a new bootstrap
   component or a new GCP resource. Day-to-day work is ArgoCD PRs.
5. All cloud resources live in a single GCP project,
   `rockingham-homelab`, so teardown is atomic and the homelab's blast
   radius is project-bounded.

## Consequences

**Positive**

- Adding an addon is a directory drop and a push; no Terraform run.
- ArgoCD provides drift detection, sync history, and a UI for free.
- Terraform state stays small and rarely-touched, which keeps PR review
  of TF changes meaningful.
- Atomic GCP teardown: deleting the project removes everything.
- Cluster recovery from total loss is two `terraform apply` runs plus
  ArgoCD reconciling the rest.

**Negative**

- Two systems to learn and operate. A reader needs to know where a
  given resource is owned (TF for bootstrap, ArgoCD for everything
  else) and not edit it in the wrong place.
- The ESO bootstrap SA key is the one `Secret` Terraform's Kubernetes
  provider creates. Rotating it requires a Terraform apply, not just a
  PR.
- Components installed by Terraform (Cilium, cert-manager, ESO,
  ArgoCD itself) must not also be tracked by an ArgoCD `Application`,
  or both controllers will fight over the same objects. The boundary
  has to be respected by convention.
- Bootstrap order is encoded as `depends_on` between Helm releases.
  Re-running the bootstrap on a fresh cluster relies on that ordering
  being correct; if it's wrong, failures are confusing.

## Alternatives considered

### Pure Terraform (TF manages every Kubernetes resource)

Rejected. Modeling every addon, every CRD instance, every Helm release
in TF turns the state file into the entire cluster. Routine changes
become Terraform applies; review of `terraform plan` for K8s-shaped
diffs is painful; there is no continuous reconciliation, no UI, and no
sync history. This stops being IaC and becomes "imperative apply by
another name."

### Pure ArgoCD-from-zero (no Terraform on the cluster side)

Rejected. The bootstrap problem doesn't go away — something still has
to install Gateway API CRDs, Cilium, cert-manager, ESO, and ArgoCD
itself onto an empty Talos cluster. Replacing the Terraform bootstrap
root with `kubectl apply -f ...` scripts trades a typed, planned tool
for shell, with worse drift behaviour and no plan output. Since the
GCP side needs Terraform anyway, dropping it from the cluster side
saves nothing.

### Pulumi

Rejected. Same shape as Terraform but in Python or TypeScript. Existing
operator familiarity is with Terraform; the niches that matter here
(Cloud DNS, the Kubernetes provider, the Helm provider) are best
represented in the Terraform ecosystem. There is no homelab-scale
problem Pulumi solves better.

### Crossplane (manage GCP resources via Kubernetes CRDs, end-to-end ArgoCD)

Rejected. Crossplane needs a running cluster before it can manage any
GCP resource — but the GCP DNS zone, service accounts, and GSM secrets
are inputs to bringing the cluster up (DNS-01, ESO bootstrap key).
That is the chicken-and-egg this repo was trying to avoid, not solve.
On top of that, Crossplane introduces controllers, providers, and
package management that Terraform handles with a plain CLI. Net
operational tax is meaningful and the homelab does not generate the
churn that would justify it.
