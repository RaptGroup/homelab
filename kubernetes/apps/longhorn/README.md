# `kubernetes/apps/longhorn/`

Phase 2 storage. Longhorn is installed as a **named, non-default**
`StorageClass` alongside `local-path` (ADR-0005). PVCs opt in to
node-portable, replicated storage with `storageClassName: longhorn`;
omitting `storageClassName` keeps the existing `local-path` default
intact.

## Shape

```
kubernetes/apps/longhorn/
├── application.yaml       # multi-source ArgoCD Application (sync-wave -10)
├── helm-values.yaml       # charts.longhorn.io / longhorn chart values
└── manifests/
    ├── namespace.yaml     # longhorn-system Namespace (pod-security: privileged)
    └── httproute.yaml     # longhorn.lab.jackhall.dev → longhorn-frontend Service
```

## Which `StorageClass` for what

| Workload shape                                     | `storageClassName`      |
|----------------------------------------------------|-------------------------|
| Self-replicating distributed app (YB, NATS, etc.)  | _omit_ → `local-path`   |
| Singleton stateful app with valuable data          | `longhorn`              |
| Singleton cache (most Redis behind apps)           | no PVC — `emptyDir`     |

Rationale: replication under self-replicating apps is write
amplification for guarantees the app already provides. See ADR-0005
"Decision" for the per-workload heuristic and the alternatives that
were considered and rejected.

## Workers-only scheduling

Every Longhorn pod lands on a worker — none on `cp-0{1,2,3}`. Two
mechanisms, deliberately overlapping:

1. **nodeSelector**: `lab.jackhall.dev/role: worker`. The label is
   set on each worker via `nodeLabels` in `talos/patches/nodes/worker-*.yaml`.
   Applied per-component in `helm-values.yaml` (`longhornManager`,
   `longhornDriver`, `longhornUI`) and to CSI sidecars via
   `defaultSettings.systemManagedComponentsNodeSelector`. Custom
   prefix on purpose — NodeRestriction admission forbids the kubelet
   from self-setting any label under `kubernetes.io/` or
   `node-role.kubernetes.io/`, so the obvious-looking
   `node-role.kubernetes.io/worker` is silently rejected on every
   reconcile (only `node-role.kubernetes.io/control-plane` is
   special-cased by Talos at registration).
2. **taintToleration**: left empty so Longhorn pods do not tolerate the
   default `node-role.kubernetes.io/control-plane:NoSchedule` taint.
   Even if a future label drift makes a control plane match the
   nodeSelector, the taint keeps Longhorn off it.

## Talos prerequisites (issue #121)

Longhorn will not start without:

- The Talos installer rebuilt with `siderolabs/iscsi-tools` and
  `siderolabs/util-linux-tools` extensions on every worker.
- A `UserVolume` block carving an XFS partition at `/var/mnt/longhorn`
  on each worker (the chart's `defaultSettings.defaultDataPath`).

Both are owned by issue #121.

## What's NOT here

- **Backup target.** `defaultSettings.backupTarget` and
  `backupTargetCredentialSecret` are blank; backup wiring (GCS via the
  S3 interop API, HMAC key from `terraform/gcp/`) is issue #123.
- **Existing-PVC migration.** Phase 1 PVCs (AdGuard, ArgoCD, Homepage)
  stay on `local-path` — no migration is performed by this slice.
- **Cluster default flip.** Explicitly rejected in ADR-0005;
  `local-path` keeps the
  `storageclass.kubernetes.io/is-default-class=true` annotation.

## Smoke test

A PVC with `storageClassName: longhorn` should bind on any worker, a
pod mounting it should write data, and deleting the pod + recreating
it on a different worker should preserve the data (replica count is
2, so at least one replica survives any single-worker eviction). The
Longhorn UI at `https://longhorn.lab.jackhall.dev` shows the volume,
its replicas, and which workers each replica lives on.
