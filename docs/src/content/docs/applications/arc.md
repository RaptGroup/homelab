---
title: ARC runners
description: Self-hosted GitHub Actions runners — one ARC controller plus two scale sets backed by one GitHub App with two installations.
---

[Actions Runner Controller](https://github.com/actions/actions-runner-controller)
(ARC) gives the homelab a pool of self-hosted GitHub Actions runners
that scale to zero when idle and run workflow jobs as ephemeral pods on
the cluster. The lab runs three Applications under
[`kubernetes/apps/`](https://github.com/RaptGroup/homelab/tree/main/kubernetes/apps)
that together form one logical system:

- [`arc-controller/`](https://github.com/RaptGroup/homelab/tree/main/kubernetes/apps/arc-controller)
  — the cluster-wide controller (one per cluster).
- [`arc-runners-raptgroup/`](https://github.com/RaptGroup/homelab/tree/main/kubernetes/apps/arc-runners-raptgroup)
  — scale set targeting [`github.com/RaptGroup`](https://github.com/RaptGroup),
  the operator's personal-projects org.
- [`arc-runners-brazostech/`](https://github.com/RaptGroup/homelab/tree/main/kubernetes/apps/arc-runners-brazostech)
  — scale set targeting [`github.com/brazostech`](https://github.com/brazostech).

The split mirrors GitHub's `gha-runner-scale-set` two-chart pattern
upstream: one controller, N independent scale sets, each scoped to one
GitHub-App-installation × `runs-on:` label set. Adding a third pool is
a third `kubernetes/apps/arc-runners-<scope>/` directory; the
controller doesn't change.

## Two-chart shape

The controller chart owns the `AutoscalingRunnerSet` CRD and reconciles
every scale set installed alongside it. It lives in the `arc-systems`
namespace; its ServiceAccount is pinned to `arc-gha-rs-controller`
(via `fullnameOverride` in the controller values) so the scale-set
charts can reference it stably across release renames.

Each scale set chart provides:

- A per-scope namespace (`arc-runners-raptgroup`,
  `arc-runners-brazostech`).
- A listener pod that talks to GitHub's API and provisions ephemeral
  runner pods on demand.
- The runner pool itself (scaled 0 → N as workflow jobs land).
- A `gha-runner-scale-set`–owned Secret containing the GitHub App
  credentials for that pool's installation, populated from GSM by the
  External Secrets Operator.

The controller and the scale sets reconcile in any order so long as
both eventually exist; scale sets sit `OutOfSync` until the controller
SA appears in `arc-systems`.

## One App, two installations

Both pools are backed by the same GitHub App — `Rockingham Homelab
ARC` — with **two installations**, one per target org:

| GSM secret ID                     | Shape       | Used by                        |
|-----------------------------------|-------------|--------------------------------|
| `arc-app-id`                      | App ID      | both pools (TF-managed)        |
| `arc-app-private-key`             | PEM         | both pools (TF-managed)        |
| `arc-installation-id-raptgroup`   | Install ID  | `arc-runners-raptgroup`        |
| `arc-installation-id-brazostech`  | Install ID  | `arc-runners-brazostech`       |

App ID and private key are shared; only the installation ID differs.
The containers are TF-managed in
[`terraform/gcp/`](https://github.com/RaptGroup/homelab/tree/main/terraform/gcp);
the External Secrets Operator syncs each value from Google Secret
Manager into a K8s Secret in the pool's namespace. Each pool's
`ExternalSecret` projects its three values into a single Secret the
chart consumes via `githubConfigSecret`. Rotating the App key is a
GSM update plus a listener restart; rotating an installation ID is
the same.

The two-installation model is the access boundary. The App is **not**
installed on Scale Computing (the operator's employer org), so even
from inside the brazostech runner pods, an installation token can't
reach a Scale Computing repo. There is no client-side "deny" knob to
maintain — the boundary is enforced server-side by GitHub.

## Why a `RaptGroup` org

ARC's chart can't serve user-account scopes. `githubConfigUrl` accepts
a repo, an org, or an enterprise URL — never `https://github.com/<user>`.
Personal repos that need cluster-reaching CI get **transferred into
RaptGroup**, a free GitHub org the operator created for exactly this
purpose, rather than maintaining one repo-scoped scale set per
personal repo.

## `runs-on:` label conventions

The chart auto-registers `self-hosted` plus the scale set's release
name, and `scaleSetLabels` appends the rest. The full label set per
pool:

| Pool                       | Labels                                                          |
|----------------------------|-----------------------------------------------------------------|
| `arc-runners-raptgroup`    | `self-hosted`, `linux`, `raptgroup`, `arc-runners-raptgroup`    |
| `arc-runners-brazostech`   | `self-hosted`, `linux`, `brazostech`, `arc-runners-brazostech`  |

Workflows can target either pool through any of these forms:

```yaml
# personal projects
runs-on: [self-hosted, raptgroup]
runs-on: [self-hosted, linux, raptgroup]
runs-on: arc-runners-raptgroup

# brazostech
runs-on: [self-hosted, brazostech]
runs-on: [self-hosted, linux, brazostech]
runs-on: arc-runners-brazostech
```

The short org-named labels (`raptgroup`, `brazostech`) are the
canonical ones — short, scope-named, distinct.

## Pod shape

| Knob                | Value                                                             |
|---------------------|-------------------------------------------------------------------|
| `minRunners`        | `0` — scale to zero when idle                                     |
| `maxRunners`        | `4` per pool                                                      |
| Per-runner requests | 500m CPU / 1Gi RAM / 10Gi ephemeral                               |
| Container mode      | None — runners run jobs directly                                  |
| Pod lifetime        | Ephemeral — one job per pod, then teardown                        |

DinD / Kubernetes container mode is intentionally avoided. Image
builds in CI will move to a planned buildkit VM rather than enabling
privileged DinD inside the cluster. `maxRunners: 4` is a deliberate
ceiling — anything bursty enough to need more concurrency is better
served by paying for GitHub-hosted runners than by sizing the homelab
around CI peaks.

## Dashboard cards

Neither chart ships a Service of its own (the listener and runner pods
don't expose HTTP), so each pool's namespace ships a placeholder
`ExternalName` Service whose only purpose is to carry the
`gethomepage.dev/*` annotations. Each card's `href` points at the
target org page on GitHub:

- **Runners — RaptGroup** → `https://github.com/RaptGroup`
- **Runners — brazostech** → `https://github.com/brazostech`

The `externalName` value is irrelevant — nothing dials the Service.

## Smoke job

```yaml
jobs:
  hello:
    runs-on: [self-hosted, raptgroup]   # or: brazostech
    steps:
      - run: echo "hello from $HOSTNAME"
```

The targeted pool scales 0 → 1 on dispatch, runs the job, and scales
back to 0 within a minute or two of completion.

## More

The per-addon READMEs at
[`kubernetes/apps/arc-controller/README.md`](https://github.com/RaptGroup/homelab/blob/main/kubernetes/apps/arc-controller/README.md),
[`kubernetes/apps/arc-runners-raptgroup/README.md`](https://github.com/RaptGroup/homelab/blob/main/kubernetes/apps/arc-runners-raptgroup/README.md),
and
[`kubernetes/apps/arc-runners-brazostech/README.md`](https://github.com/RaptGroup/homelab/blob/main/kubernetes/apps/arc-runners-brazostech/README.md)
cover the per-addon manifests, the `fullnameOverride` rationale, and
verification commands.
