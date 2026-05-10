---
title: ArgoCD
description: The GitOps controller that reconciles every addon under kubernetes/apps/ — installed by Terraform, then self-manages its own chart.
---

[ArgoCD](https://argo-cd.readthedocs.io/) is the cluster's GitOps
controller. Every addon under
[`kubernetes/apps/`](https://github.com/RaptGroup/homelab/tree/main/kubernetes/apps)
exists in the cluster because ArgoCD reconciles it from this repo. It is
the last thing `terraform/bootstrap/` installs and the first thing the
operator interacts with after the bootstrap finishes.

## Why Terraform installs it

ArgoCD cannot reconcile itself before it exists, and an empty cluster
has no controller capable of installing it. Terraform owns the
"hand the cluster off to ArgoCD" seam — see
[Platform / Why Terraform](/homelab/platform/#why-these-four-are-bootstrapped-via-terraform)
and
[ADR-0001](https://github.com/RaptGroup/homelab/blob/main/docs/adr/0001-iac-strategy.md)
for the full rationale. After the first `tofu apply`, Terraform's role
in ArgoCD's lifecycle is over: chart upgrades happen through a normal PR
(see [Self-management](#self-management) below).

## Where the config lives

Two directories, two responsibilities:

- [`terraform/bootstrap/argocd.tf`](https://github.com/RaptGroup/homelab/blob/main/terraform/bootstrap/argocd.tf)
  — the initial Helm release, the namespace, the GSM-backed repository
  credential, and the two `Application` manifests (self-managed +
  root).
- [`kubernetes/bootstrap/argocd/`](https://github.com/RaptGroup/homelab/tree/main/kubernetes/bootstrap/argocd)
  — the Helm `values.yaml` and the self-managed `Application` template.
  Both files are also referenced *post-bootstrap*: the self-managed
  `Application` reads `values.yaml` via `$values`, so a PR editing
  `values.yaml` reaches the cluster on the next ArgoCD sync without a
  Terraform run.

| Knob | Value |
|---|---|
| Namespace | `argocd` |
| Helm chart | `argo-proj/argo-cd` (chart version `9.5.13`) |
| UI hostname | `argocd.lab.jackhall.dev` |
| TLS | Terminated at the [`lab` Gateway](/homelab/applications/lab-gateway/), `server.insecure: true` inside the pod |
| Repo URL | `git@github.com:RaptGroup/homelab.git` (SSH; deploy key synced from GSM by ESO) |
| Tracked revision | `main` |

The `HTTPRoute` and `Gateway` attachment for the UI live under
[`kubernetes/apps/argocd/`](https://github.com/RaptGroup/homelab/tree/main/kubernetes/apps/argocd),
**not** in `terraform/bootstrap/`. Once ArgoCD is up, the routing layer
in front of it is just another addon directory like any other.

## Self-management

ArgoCD watches an `Application` named `argocd` that points back at the
same Helm chart Terraform bootstrapped it from. The chart version comes
from `terraform/bootstrap/variables.tf`; the values come from
`kubernetes/bootstrap/argocd/values.yaml` via the multi-source `$values`
ref:

```yaml
sources:
  - repoURL: https://argoproj.github.io/argo-helm
    chart: argo-cd
    targetRevision: ${chart_version}
    helm:
      valueFiles:
        - $values/kubernetes/bootstrap/argocd/values.yaml
  - repoURL: ${repo_url}
    targetRevision: ${target_revision}
    ref: values
```

This is what makes the Terraform-vs-ArgoCD boundary work for the one
service that lives on both sides: **values changes are PRs**, not
Terraform applies. Bumping the ArgoCD chart version is the only edit
that still requires a Terraform run, because the version is templated
into the `Application` manifest at apply time.

## The root app-of-apps

A second `Application` — the root — watches the
[`kubernetes/apps/`](https://github.com/RaptGroup/homelab/tree/main/kubernetes/apps)
directory and turns every subdirectory into its own `Application`. This
is the seam that makes "drop a directory and push" the entire workflow
for adding an addon: no Terraform, no ApplicationSet generators, no UI
clicks. The mechanism is plain app-of-apps, deliberately not
`ApplicationSet`, because the directory-per-addon convention maps to one
manifest per child app and is easier to read than the equivalent
generator config.

## Operational entry points

- **UI** — [`https://argocd.lab.jackhall.dev`](https://argocd.lab.jackhall.dev/),
  reachable from any device using AdGuard Home for DNS (see
  [Split-horizon DNS](/homelab/networking/split-horizon-dns/)). The UI
  is the canonical view of which Applications are healthy, what's out
  of sync, and what each child sync touched.
- **Initial admin password** — auto-generated into the
  `argocd-initial-admin-secret` Secret in the `argocd` namespace on
  first install. Read it once with `kubectl -n argocd get secret
  argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64
  -d`, log in, then rotate.
- **Homepage card** — the dashboard shows ArgoCD app counts via the
  `accounts.homepage` API-key account configured in `values.yaml`. The
  account has `role:readonly` cluster-wide and is restricted to
  `apiKey` (no UI login), so a leaked token is bounded to read-only
  API access.

## How addons interact with ArgoCD

For every addon under [`kubernetes/apps/`](https://github.com/RaptGroup/homelab/tree/main/kubernetes/apps):

1. The addon directory holds an `application.yaml` (and usually a
   `helm-values.yaml`).
2. The root app-of-apps notices the new directory on the next sync and
   creates the child `Application`.
3. The child `Application` syncs the addon's manifests with
   `ServerSideApply=true` and `CreateNamespace=true`.

Two child `Application`s deserve special mention:

- **The repo credential** — `terraform/bootstrap/argocd.tf` creates an
  `ExternalSecret` named `argocd-repo-homelab` that pulls the SSH deploy
  key from GSM into a labelled `repository` Secret. ArgoCD matches
  Applications to credentials by repo URL automatically; without this
  Secret the root app-of-apps can't clone the repo.
- **`controller.diff.server.side: true`** — set in `values.yaml` so
  diffs go through the kube-apiserver instead of ArgoCD's bundled
  schema. Required because newer API-server fields (e.g. `Deployment.
  status.terminatingReplicas`, beta since k8s 1.32) aren't in Argo's
  shipped schema and would put any addon whose live Deployment
  populates them into `ComparisonError`. See issue
  [#40](https://github.com/RaptGroup/homelab/issues/40) for the
  trigger.

## More

[`terraform/bootstrap/README.md`](https://github.com/RaptGroup/homelab/blob/main/terraform/bootstrap/README.md)
covers the run book — what to do on a partial apply, how to bump the
chart version, and the `tofu output argocd_initial_admin_secret`
shortcut for the first login.
