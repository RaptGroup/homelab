---
title: local-path-provisioner
description: The cluster-default StorageClass — Rancher local-path-provisioner carving PVCs out of a node's local disk. Phase 1 storage; Longhorn is deferred.
---

[local-path-provisioner](https://github.com/rancher/local-path-provisioner)
is the cluster's default `StorageClass`. Every PVC that doesn't name a
specific class gets a node-local directory under `/opt/local-path-provisioner`
on whichever worker the consuming Pod schedules to. It is the simplest
working storage backend, and it is the lab's deliberate Phase 1 choice
— **Longhorn for replicated block storage is the Phase 2 deferral**,
gated on a Talos extensions upgrade and a separate UserVolume patch.

## Why Terraform installs it

Two reasons. First, ordering: ArgoCD addons that ship a PVC need a
default `StorageClass` to bind against, and an empty Talos cluster
ships none. Without local-path in place before ArgoCD reconciles its
first PVC-using addon (AdGuard Home was the trigger, see
[issue #28](https://github.com/jvcorredor/homelab/issues/28)), the
addon hangs in `Pending`. Second, the install needs two non-Helm,
non-manifest knobs that are easier to express in Terraform than as a
sibling Helm release: marking the class default with the
`storageclass.kubernetes.io/is-default-class` annotation, and labelling
the `local-path-storage` namespace `pod-security.kubernetes.io/enforce:
privileged` so the helper Pods can use `hostPath` (see
[The PSA carve-out](#the-psa-carve-out) below).

## Where the config lives

[`terraform/bootstrap/local-path.tf`](https://github.com/jvcorredor/homelab/blob/main/terraform/bootstrap/local-path.tf)
is the complete picture:

- The upstream `deploy/local-path-storage.yaml` from
  `rancher/local-path-provisioner v0.0.32`, fetched via `data.http`
  and applied as a multi-document `kubectl_manifest`. The official
  Helm chart is community-maintained and lags releases; the upstream
  YAML is the canonical install path.
- The `is-default-class` annotation on the resulting `StorageClass`.
- The PSA `privileged` labels on the `local-path-storage` namespace.

## Operational entry points

| Resource | Purpose |
|---|---|
| `StorageClass/local-path` | The cluster default. Any PVC without a `storageClassName` binds here. |
| `Namespace/local-path-storage` | Where the provisioner Deployment and helper Pods run. PSA `privileged`. |
| `tofu output default_storage_class` | Prints `local-path` — used as a sanity check during the bootstrap apply. |

Health check the operator runs after a bootstrap or upgrade:

```sh
kubectl get storageclass local-path
kubectl -n local-path-storage get pods
```

The `StorageClass` should be marked `(default)` and the provisioner
Deployment should be `Ready`.

## How addons consume storage

Addon PVCs target the default `StorageClass` implicitly:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: <addon>-data
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
  # storageClassName intentionally omitted → default → local-path
```

Provisioning is lazy: when the consuming Pod schedules, the provisioner
spawns a short-lived helper Pod on that node, the helper creates a
directory under `/opt/local-path-provisioner/...`, and the PVC binds.
Current consumers in the lab are AdGuard Home (config + query log) and
ArgoCD (Redis cache).

The trade-offs of "local disk" are not abstracted away:

- **Single-node durability.** A PVC is bound to one node's disk; if
  that node is down, the workload waiting on the PVC stays
  `ContainerCreating`. For Phase 1 this is acceptable — the lab has
  no replicated-state addon today.
- **No `ReadWriteMany`.** local-path is RWO only. Anything that needs
  multi-writer storage waits for Phase 2.
- **Helper Pods, not driver-managed.** Provisioning happens through
  spawned Pods rather than a CSI sidecar, which is what makes the PSA
  carve-out below necessary.

## The PSA carve-out

The cluster-default Pod Security admission level is `baseline`, which
forbids `hostPath` volumes. local-path's helper Pod uses `hostPath` to
create the backing directory on the node, so without the explicit
namespace label it would be rejected at admission time inside its own
namespace:

```
helper-pod-create-pvc-… is forbidden:
violates PodSecurity "baseline": hostPath volumes
```

Surfaced when AdGuard Home (the first PVC-using addon) hit it. The fix
is to label `local-path-storage` `privileged` for the three PSA modes
(`enforce`, `audit`, `warn`); every other namespace stays at
`baseline`. The blast radius of `privileged` is bounded to the one
namespace where the helper Pod can actually run — local-path-provisioner's
binary uses the downward API to spawn helpers in its own namespace
(`helperPod.Namespace = p.namespace`), so there is no path by which a
workload in another namespace inherits the carve-out.

## Phase 2: Longhorn

Replicated block storage is the planned upgrade — see the
[storage-strategy](https://github.com/jvcorredor/homelab/blob/main/docs/adr/)
discussion in CONTEXT and the relevant ADR when written. Longhorn
needs:

1. The `iscsi-tools` Talos system extension installed on every worker
   (a Talos image rebuild + reboot).
2. The `UserVolume` patch on each worker to carve out the disk space
   Longhorn manages.
3. Migration of existing local-path PVCs to Longhorn-backed equivalents
   (or accepted data loss for caches like ArgoCD Redis).

Until that lands, local-path stays the cluster default and any addon
that needs replicated storage is deferred along with the upgrade.

## More

[`terraform/bootstrap/local-path.tf`](https://github.com/jvcorredor/homelab/blob/main/terraform/bootstrap/local-path.tf)
documents the helper-Pod / PSA reasoning inline; it's the canonical
source for *why* the namespace is privileged. The recovery procedure
for a failed apply is in
[`terraform/bootstrap/README.md`](https://github.com/jvcorredor/homelab/blob/main/terraform/bootstrap/README.md#recovery-from-a-partial-apply).
