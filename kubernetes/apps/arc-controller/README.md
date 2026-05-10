# `kubernetes/apps/arc-controller/`

[Actions Runner Controller](https://github.com/actions/actions-runner-controller)
— the controller half of GitHub's `gha-runner-scale-set` two-chart
pattern. Owns the `AutoscalingRunnerSet` CRD and reconciles every
per-scope scale set installed alongside it. Lives in the `arc-systems`
namespace; the runner pods themselves live in per-scope namespaces
(`arc-runners-raptgroup`, `arc-runners-brazostech`).

The two-chart split is deliberate upstream: one cluster-wide controller,
N independent scale sets, each scale set scoped to one
GitHub-App-installation × `runs-on:` label set. Adding a new pool is a
new `kubernetes/apps/arc-runners-<scope>/` directory; the controller
manifest here doesn't change.

## Shape

```
kubernetes/apps/arc-controller/
├── application.yaml         # multi-source ArgoCD Application (chart + values + extras)
├── helm-values.yaml         # gha-runner-scale-set-controller values
└── manifests/
    └── namespace.yaml       # arc-systems Namespace
```

Multi-source layout because the chart is at
`ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller`
(0.14.1) and the values file lives in this repo. The `manifests/` source
adds only the namespace itself — the chart handles SA, RBAC, leader
election, deployment.

## Why `fullnameOverride: arc-gha-rs-controller`

The scale-set chart's `controllerServiceAccount.name` value has to point
at *this* controller's SA, and Helm's default fullname template is
`<release>-gha-rs-controller`. Argo's release name defaults to the
Application name, so without an override the SA would be
`arc-controller-gha-rs-controller` — and a future rename of either
Application would silently break the cross-chart reference.

Pinning `fullnameOverride: arc-gha-rs-controller` here keeps the SA
name stable. The runner pools' `helm-values.yaml` files reference it
explicitly:

```yaml
controllerServiceAccount:
  namespace: arc-systems
  name: arc-gha-rs-controller
```

Why explicit instead of the chart's default `lookup`-based discovery:
the chart's helm-template-time discovery uses a Helm `lookup`, which
Argo's render can't satisfy (no live cluster context during diff). The
explicit name plus the `fullnameOverride` is the workaround.

## Log level

Chart default is `debug`, which is noisy for steady state. Set to
`info` here. Bump back to `debug` temporarily when chasing an ARC-side
issue (controller crashloops, scale-set provisioning stuck pending,
listener auth errors).

## Verifying after first sync

```sh
# Controller deployment up and AutoscalingRunnerSet CRD installed.
kubectl -n arc-systems get deploy
kubectl get crd autoscalingrunnersets.actions.github.com

# SA name matches what the scale sets reference.
kubectl -n arc-systems get sa arc-gha-rs-controller
# → must exist; no scale set will reconcile without it.

# No errors steady-state.
kubectl -n arc-systems logs deploy/arc-gha-rs-controller-gha-rs-controller \
  --tail=50 | grep -i error
# → empty
```

The two scale-set Applications (`arc-runners-raptgroup`,
`arc-runners-brazostech`) will sit `OutOfSync` until this controller is
healthy — they reconcile in any order so long as the controller is
present.

## Disaster recovery

Stateless. Re-syncing the Application is the entire DR procedure; no
per-pool credentials live in `arc-systems`, those belong to the
respective `arc-runners-<scope>/` namespaces. The ARC controller
recovers from cold start in seconds.
