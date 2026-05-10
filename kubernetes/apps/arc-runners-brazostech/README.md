# `kubernetes/apps/arc-runners-brazostech/`

GitHub Actions Runner Controller (ARC) scale set targeting
[`https://github.com/brazostech`](https://github.com/brazostech).
Workflows opt in with `runs-on: [self-hosted, brazostech]`.

Same shape as the RaptGroup pool — same chart, same controller, same
GitHub App. The only difference is which GitHub App installation the
listener authenticates as: this pool uses the brazostech-org
installation, the RaptGroup pool uses the RaptGroup-org installation.

> **Scale Computing is intentionally out of scope.** The boundary is
> enforced server-side by GitHub: the `Rockingham Homelab ARC` App is
> not installed on the Scale Computing org, so its installation token
> can't reach any Scale Computing repo even from inside this pool's
> runners. There is no client-side "deny" knob to maintain.

## Shape

```
kubernetes/apps/arc-runners-brazostech/
├── application.yaml                      # multi-source ArgoCD Application
├── helm-values.yaml                      # gha-runner-scale-set values for this pool
└── manifests/
    ├── namespace.yaml                    # arc-runners-brazostech Namespace
    ├── external-secret.yaml              # GitHub App credentials synced from GSM
    └── homepage-card-service.yaml        # ExternalName Service carrying gethomepage.dev/* annotations
```

See `kubernetes/apps/arc-runners-raptgroup/README.md` for the
source-layout rationale, the GitHub App + GSM topology, and the
generic operational details — both pools follow the same shape. This
README only covers what's specific to the brazostech pool.

## Installation scope (least privilege)

The brazostech installation runs with `repository_selection: selected`,
mirroring the RaptGroup pool. See
`kubernetes/apps/arc-runners-raptgroup/README.md` for the rationale and
the procedure for widening the allowlist when a new workflow targets
self-hosted runners.

No brazostech repo currently has a `runs-on: self-hosted` workflow, so
the allowlist is whatever minimum the App needs to remain installed at
the org level. The pool's listener authenticates against the *org*
(`https://github.com/brazostech`), so the org-level installation itself
is what makes the scale set work — the per-repo allowlist gates which
repos' workflows can dispatch to it.



The scale-set installation ID for this pool is unique:

| GSM secret ID                     | Used by              |
|-----------------------------------|----------------------|
| `arc-installation-id-brazostech`  | this pool            |

`arc-app-id` and `arc-app-private-key` are shared with the RaptGroup
pool. The `ExternalSecret` here pulls all three keys into the
`arc-runners-brazostech-github-config` K8s Secret in this namespace;
`helm-values.yaml` references that Secret by name via
`githubConfigSecret`.

## Labels and `runs-on:`

The chart auto-registers `self-hosted` and the scale set's release name
(`arc-runners-brazostech`); `scaleSetLabels` appends `linux,
brazostech`. Full GitHub-side label set:

```
{self-hosted, linux, brazostech, arc-runners-brazostech}
```

Workflows can target this pool with any of:

```yaml
runs-on: [self-hosted, brazostech]
runs-on: [self-hosted, linux, brazostech]
runs-on: arc-runners-brazostech
```

`brazostech` is the canonical label — short, scope-named, distinct from
`raptgroup`.

## Capacity and pod shape

Identical to the RaptGroup pool: `minRunners: 0`, `maxRunners: 4`,
500m CPU / 1Gi RAM / 10Gi ephemeral, no container mode, ephemeral pods.

## Homepage card

`homepage-card-service.yaml` is the same `ExternalName`-Service trick
as the RaptGroup pool, with `href` pointing at
`https://github.com/brazostech` and the `gethomepage.dev/name` set to
`Runners — brazostech`.

## Verifying after first sync

```sh
kubectl -n arc-runners-brazostech get secret arc-runners-brazostech-github-config
kubectl -n arc-runners-brazostech get pod -l app.kubernetes.io/component=runner-scale-set-listener
kubectl -n arc-runners-brazostech get autoscalingrunnersets
```

Smoke job:

```yaml
jobs:
  hello:
    runs-on: [self-hosted, brazostech]
    steps:
      - run: echo "hello from $HOSTNAME"
```

The pool scales 0 → 1 on dispatch, runs the job, and scales back to 0
within a minute or two of completion.

## Disaster recovery

Same as the RaptGroup pool: stateless apart from the GSM credentials,
which are already off-machine. Re-running the GSM uploads and
re-syncing the Application is the entire DR procedure.
