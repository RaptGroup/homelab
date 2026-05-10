# `kubernetes/apps/arc-runners-raptgroup/`

GitHub Actions Runner Controller (ARC) scale set targeting
[`https://github.com/RaptGroup`](https://github.com/RaptGroup) — the
operator's personal-projects GitHub org. Workflows opt in with
`runs-on: [self-hosted, raptgroup]`.

The scale-set chart is the runner half of the two-chart pattern; the
controller half lives in `kubernetes/apps/arc-controller/`. This addon
provides the per-scope namespace, the listener pod, and the
ephemeral-runner pool itself.

> **Why a `RaptGroup` org at all.** ARC's chart can't serve user-account
> scopes — only repository, organisation, and enterprise URLs are
> accepted. Personal repos that need cluster-reaching CI get
> transferred into `RaptGroup` rather than maintaining one repo-scoped
> scale set per repo.

## Shape

```
kubernetes/apps/arc-runners-raptgroup/
├── application.yaml                      # multi-source ArgoCD Application
├── helm-values.yaml                      # gha-runner-scale-set values for this pool
└── manifests/
    ├── namespace.yaml                    # arc-runners-raptgroup Namespace
    ├── external-secret.yaml              # GitHub App credentials synced from GSM
    └── homepage-card-service.yaml        # ExternalName Service carrying gethomepage.dev/* annotations
```

Three Application sources — chart, repo (for the values reference), and
the `manifests/` path — because the root app-of-apps watches
`**/application.yaml` only, so the `manifests/` directory needs an
explicit path source rather than relying on root pickup.

## GitHub App + GSM topology

One GitHub App (`Rockingham Homelab ARC`) backs both runner pools, with
two installations — one per target org. App ID and private key are
shared; only the installation ID differs:

| GSM secret ID                     | Shape       | Used by                          |
|-----------------------------------|-------------|----------------------------------|
| `arc-app-id`                      | App ID      | both pools (TF-managed)          |
| `arc-app-private-key`             | PEM         | both pools (TF-managed)          |
| `arc-installation-id-raptgroup`   | Install ID  | this pool                        |
| `arc-installation-id-brazostech`  | Install ID  | `arc-runners-brazostech` pool    |

The containers are TF-managed in `terraform/gcp/main.tf`; only the
*values* are uploaded out of band. The `ExternalSecret` here projects
the three values into a single K8s Secret
(`arc-runners-raptgroup-github-config`) with the keys the
`gha-runner-scale-set` chart's "Variation C" expects:
`github_app_id`, `github_app_installation_id`, `github_app_private_key`.

`helm-values.yaml` references that Secret by name via
`githubConfigSecret`, so credential rotation is a GSM update plus a
listener-pod restart — no chart change needed.

## Installation scope (least privilege)

The RaptGroup installation runs with `repository_selection: selected`, not
`all`. The install token the listener mints can only mint repo tokens for
the allowlisted repos, which caps the blast radius if the App's private
key ever leaked.

Current allowlist:

| Repo                       | Why                                              |
|----------------------------|--------------------------------------------------|
| `RaptGroup/homelab`        | Controls the cluster; default destination for future cluster-reaching workflows. |
| `RaptGroup/zipmenu-public` | Has a live `runs-on: self-hosted` workflow (`amplify-publish.yml`). |

Adding a new repo means doing the GitHub UI step *at the same time* as the
workflow change — otherwise the runner picks up the job and fails on token
mint:

1. github.com → RaptGroup org → Settings → GitHub Apps → `Rockingham
   Homelab ARC` → Configure → Repository access → Only select repositories
   → add the repo.
2. Land the workflow change with `runs-on: [self-hosted, raptgroup]`.
3. No ArgoCD reconcile is needed — the listener re-uses the existing App
   credentials.

## Labels and `runs-on:`

The chart auto-registers `self-hosted` and the scale set's release name
(`arc-runners-raptgroup`); `scaleSetLabels` appends the rest. The full
GitHub-side label set is therefore:

```
{self-hosted, linux, raptgroup, arc-runners-raptgroup}
```

Workflows can target this pool with any of:

```yaml
runs-on: [self-hosted, raptgroup]
runs-on: [self-hosted, linux, raptgroup]
runs-on: arc-runners-raptgroup
```

The `raptgroup` label is the canonical one — short, scope-named, and
distinct from `brazostech`.

## Capacity and pod shape

| Knob                | Value                                                             |
|---------------------|-------------------------------------------------------------------|
| `minRunners`        | `0` — scale to zero when idle                                     |
| `maxRunners`        | `4` — anything bursty enough to need more should pay GitHub-hosted|
| Per-runner requests | 500m CPU / 1Gi RAM / 10Gi ephemeral                               |
| Container mode      | None (runners run jobs directly)                                  |
| Pod lifetime        | Ephemeral — one job per pod, then teardown                        |

DinD / Kubernetes container mode is intentionally avoided. Image builds
in CI will move to a planned buildkit VM rather than enabling
privileged DinD inside the cluster.

## Homepage card

The chart doesn't ship a Service of its own (the listener and runner
pods don't expose HTTP), so the dashboard card is driven by an
`ExternalName` Service whose only job is to carry the
`gethomepage.dev/*` annotations. The `externalName` value is irrelevant
because nothing dials the Service — the card href points at
`https://github.com/RaptGroup` directly.

## Verifying after first sync

```sh
# Listener pod up, ESO has populated the GitHub App credentials.
kubectl -n arc-runners-raptgroup get secret arc-runners-raptgroup-github-config
kubectl -n arc-runners-raptgroup get pod -l app.kubernetes.io/component=runner-scale-set-listener

# AutoscalingRunnerSet healthy.
kubectl -n arc-runners-raptgroup get autoscalingrunnersets

# Runner registered on github.com/RaptGroup → Settings → Actions → Runners.
# (UI-only, no kubectl assertion.)
```

A simple smoke job:

```yaml
jobs:
  hello:
    runs-on: [self-hosted, raptgroup]
    steps:
      - run: echo "hello from $HOSTNAME"
```

The pool scales 0 → 1 on dispatch, runs the job, and scales back to 0
within a minute or two of completion.

## Disaster recovery

Stateless apart from the GSM credentials, which are already off-machine.
Re-running the GSM uploads (App ID / private key / installation ID) and
re-syncing the Application is the entire DR procedure. Ephemeral runner
pods don't carry state between jobs.
