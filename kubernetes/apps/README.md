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
`git@github.com:jvcorredor/homelab.git`. The repo is private; ArgoCD
authenticates with the deploy key ESO syncs from GSM into a labelled
`repository` Secret in the argocd namespace. URLs are matched verbatim,
so an HTTPS form here will fail with `authentication required` even
though the credential is in place.

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
