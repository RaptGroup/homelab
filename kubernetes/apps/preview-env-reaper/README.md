# `preview-env-reaper`

Hourly CronJob that deletes preview namespaces whose
`projects.jackhall.dev/expires-at` annotation has passed. ADR-0006's
orphan backstop — the wrapper (`just preview-down` / the PR-close
Actions step) is the primary teardown path, and the reaper exists for
the failure modes where it didn't run: crashed Skaffold sessions,
force-closed PRs, ARC runner deaths mid-teardown, anything that leaves
a labelled namespace behind.

## What it does

1. Lists namespaces cluster-wide with label
   `projects.jackhall.dev/enabled=true`.
2. For each, reads the `projects.jackhall.dev/expires-at` annotation.
   The value is an RFC3339 timestamp set by the wrapper at creation
   time.
3. If the annotation is missing or unparseable: leaves the namespace
   alone (no implicit max age). Logs the reason.
4. If the timestamp is in the future: leaves the namespace alone.
5. If the timestamp is in the past: `kubectl delete namespace <ns>`.

The label gate is enforced in the script — RBAC cannot filter on
labels and `delete namespace` is necessarily a cluster-wide verb.
The script never deletes anything that didn't come back from the
labelled list, so an unlabelled namespace with a stale `expires-at`
annotation is structurally out of scope.

## Shape

| Resource              | Purpose                                                                                                   |
| --------------------- | --------------------------------------------------------------------------------------------------------- |
| `Namespace`           | `projects-system` — the home for cluster-scoped preview-env machinery that isn't a per-preview resource.  |
| `ServiceAccount`      | `preview-env-reaper` in `projects-system`. The only principal that holds the cluster-wide delete verb.    |
| `ClusterRole`         | `list` + `delete` on `namespaces` cluster-wide. Nothing else.                                             |
| `ClusterRoleBinding`  | Binds the ClusterRole to the SA.                                                                          |
| `ConfigMap`           | Holds the `reap.sh` script. Read-only mount at `/scripts` in the CronJob pod.                             |
| `CronJob`             | `0 * * * *` UTC, `concurrencyPolicy: Forbid`. Runs the script in a `bitnamilegacy/kubectl` pod with no rootfs. |

## Image choice

`docker.io/bitnamilegacy/kubectl:1.33.4`. Debian-slim base, ships
`kubectl` plus GNU coreutils — the script needs `date -d <RFC3339>`
to compare the annotation against now, and busybox `date` doesn't
parse the full RFC3339 grammar (offsets, fractional seconds), which
rules out alpine-based alternatives like `alpine/k8s`.

The image lives under `bitnamilegacy/*` because Bitnami's Aug 2025
catalog migration stripped versioned tags from `docker.io/bitnami/*`
and moved free public copies here ([#171](https://github.com/RaptGroup/homelab/issues/171)).
The legacy mirror is frozen at the migration snapshot — `1.33.4` is
the highest tag and won't move. The earlier "bump in lockstep with
the cluster's Kubernetes minor" advice no longer applies via this
image source; with kubectl pinned at 1.33 and the cluster at 1.36+,
the skew is outside the officially-supported ±1-minor window, but the
script only exercises `get namespace` and `delete namespace
--wait=false`, both stable across this range. If a real
incompatibility ever surfaces, rewrite the script to busybox-compatible
date parsing (`awk mktime()` over an RFC3339 split) and switch to
`docker.io/alpine/k8s:<cluster-minor>`.

## Why a CronJob, not a controller

ADR-0006 §5 — there is no `PreviewEnvironment` CRD, no reconciler.
The wrapper applies the bundle, the reaper sweeps stragglers. A
controller for "delete this namespace when the clock passes a
timestamp" is more machinery than the problem warrants.

## Notes on the issue body

The issue (#129) refers to the annotation as `projects.jackhall.dev/ttl`.
The canonical name in ADR-0006 and CONTEXT.md is
`projects.jackhall.dev/expires-at`, and that's what the `projects`
Gateway and the wrapper bundle both reference. The reaper uses
`expires-at`.

## Manual verification

```sh
# Labelled + past expires-at → should be deleted on next run.
kubectl create namespace reaper-test-past
kubectl label  namespace reaper-test-past projects.jackhall.dev/enabled=true
kubectl annotate namespace reaper-test-past \
  projects.jackhall.dev/expires-at=2000-01-01T00:00:00Z

# Labelled + future expires-at → should be left alone.
kubectl create namespace reaper-test-future
kubectl label  namespace reaper-test-future projects.jackhall.dev/enabled=true
kubectl annotate namespace reaper-test-future \
  projects.jackhall.dev/expires-at=2099-01-01T00:00:00Z

# Labelled + no annotation → should be left alone.
kubectl create namespace reaper-test-no-ann
kubectl label  namespace reaper-test-no-ann projects.jackhall.dev/enabled=true

# Trigger an out-of-schedule run.
kubectl -n projects-system create job --from=cronjob/preview-env-reaper reap-now
kubectl -n projects-system logs job/reap-now
```
