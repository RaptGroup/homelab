# `kubernetes/apps/`

One directory per ArgoCD-managed addon. The root `Application` watches this
folder; dropping a new directory here is how a new addon gets into the
cluster (see ADR-0001 / CONTEXT.md).

## Per-app layout

```
kubernetes/apps/<name>/
├── application.yaml     # the ArgoCD Application
├── helm-values.yaml     # values passed to the chart
└── manifests/           # optional: raw Gateway/HTTPRoute/ExternalSecret/etc.
```

`spec.source.{repoURL,chart,targetRevision}` in `application.yaml` is the
canonical pointer to the chart — both Argo and the lint pipeline read it
from there.

When `spec.source.repoURL` points back at this repo (path-based addons
that ship raw manifests instead of a chart), use the SSH form
`git@github.com:RaptGroup/homelab.git`. The repo is currently public, so
authenticated clones aren't strictly required — the SSH path is retained
for forward-compat with any future private repo (e.g. a temporarily-private
fork during an incident, or a separate secrets repo). ArgoCD authenticates
with the deploy key ESO syncs from GSM into a labelled `repository` Secret
in the argocd namespace. URLs are matched verbatim, so an HTTPS form here
will skip the credential even though it's in place — keep the SSH form
consistent across every Application.

## Linting

Every PR that touches this directory runs `helm template` + `kubeconform`
per affected app via `.github/workflows/apps-lint.yml`. The same checks
run locally:

```sh
# every app
scripts/lint-apps.sh

# specific app(s)
scripts/lint-apps.sh kubernetes/apps/adguard-home
```

Requires `helm`, `kubeconform`, and `yq` (mikefarah) on `$PATH`. Schemas
for Cilium, cert-manager, Gateway API, and ESO CRDs are pulled from the
[datreeio/CRDs-catalog](https://github.com/datreeio/CRDs-catalog) at run
time.

The lint also enforces that every `Gateway` and every `Service` of
`type: LoadBalancer` emitted by an app — whether from a chart's rendered
output or from raw `manifests/` — carries an `lbipam.cilium.io/ips`
annotation. Without the pin, Cilium hands out the first free address from
the pool, and merge order ends up deciding which addon lands on which
IP — exactly the failure mode that broke AdGuard Home's `.200` when
Hubble UI grabbed it first. Pick the next free address from CONTEXT.md's
"LB pool" table when adding a new `Gateway` or `LoadBalancer` `Service`.
