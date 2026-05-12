# 5. Longhorn as a named, non-default StorageClass

## Status

Accepted.

## Context

The cluster's Phase 1 storage layer is `local-path-provisioner` as the
default `StorageClass`. PVCs are backed by `hostPath` directories on
whichever node the pod first scheduled to. This was acceptable while every
persistent workload was a singleton with low-value state (AdGuard config,
ArgoCD repo cache, Homepage settings) — node-pinning didn't matter,
because the volume could be recreated from upstream config if the node
died.

Two new workload classes are now in scope:

1. **Singleton stateful apps with valuable data.** Forgejo (git repos),
   single-instance Postgres behind various app stacks, future Vaultwarden
   / Home Assistant / similar. Losing the host node means losing the
   data; "redeploy from upstream" is not a recovery plan. These genuinely
   want node-portable storage that survives a worker drain.

2. **Cloud-native distributed databases and messaging** in Skaffold-driven
   development namespaces — YugabyteDB, NATS JetStream, and similar.
   These replicate at the application layer (Raft / quorum) across
   StatefulSet replicas. They want **local** block storage with pod
   anti-affinity; a second layer of replication beneath them is write
   amplification for guarantees the app already provides.

A previously-recorded plan had Longhorn becoming the **cluster default**
`StorageClass` when Phase 2 began. That plan predated workload class (2)
being a concrete part of the roadmap. Keeping Longhorn as the default
would force the dominant workload by count (per-app StatefulSets in dev
namespaces) to opt out of the default on every PVC, with the silent
failure mode being "I forgot, now my YB tserver writes 9× to disk for no
reason." That's the wrong direction.

## Decision

Install Longhorn as a **named, non-default** `StorageClass`. `local-path`
remains the cluster default. Workloads opt in to Longhorn with
`storageClassName: longhorn` on their PVCs.

The per-workload heuristic at deploy time:

- **Self-replicating distributed app** (YB, NATS, Cassandra, etc.) — omit
  `storageClassName` (lands on `local-path`) and pair with pod
  anti-affinity so the replicas land on distinct workers.
- **Singleton, valuable, must survive node drain** (Forgejo, singleton
  Postgres, Vaultwarden, etc.) — `storageClassName: longhorn`.
- **Singleton cache** (most Redis behind apps) — no PVC at all.
  `emptyDir` or omit the volume; the cache rebuilds on restart.

Longhorn install shape:

- Deployed via ArgoCD under `kubernetes/apps/longhorn/`, **not** added to
  `terraform/bootstrap/`. `local-path` stays the bootstrap-layer default;
  Longhorn is one more app-of-apps addon, gated on a sync wave that
  lands it before any addon that mounts a `longhorn` PVC.
- Default replica count **2**. Survives one worker loss; halves the
  write amplification vs. the upstream default of 3 on a 3-worker
  cluster.
- Workers-only via `nodeSelector` — control planes do not carry
  replicas.
- Backup target: **GCS via the S3 interoperability API**. HMAC key
  provisioned in `terraform/gcp/` alongside existing GSM secrets, synced
  to a Kubernetes `Secret` via ESO, referenced by Longhorn's
  backup-target setting. Per-volume recurring snapshot + weekly backup
  defaults.
- Namespace `longhorn-system` gets
  `pod-security.kubernetes.io/enforce=privileged` — same reason
  `local-path-storage` does (iSCSI sidecars and `hostPath` access).

Talos prerequisites (out-of-band, manual, before the Helm release syncs):

1. Build a Talos factory image with the `siderolabs/iscsi-tools` and
   `siderolabs/util-linux-tools` system extensions.
2. `talosctl upgrade --image <factory-url>` rolling across nodes,
   draining each first.
3. Add a `UserVolume` block to each worker's patch in
   `talos/patches/nodes/worker-*.yaml`, carving an XFS partition out of
   `/dev/nvme0n1`'s free space mounted at `/var/mnt/longhorn`. Apply
   with `talosctl apply-config`.

Once those land, push the `kubernetes/apps/longhorn/` directory and let
ArgoCD sync.

## Consequences

Positive:

- New singleton workloads opt in to node-portable storage with one line
  in the PVC; the existing cluster surface doesn't move.
- Phase 1 PVCs (AdGuard, ArgoCD, Homepage) stay on `local-path` with no
  churn or migration.
- Self-replicating workloads get the storage class they actually want by
  default — no per-StatefulSet override needed, no write-amplification
  footgun.
- Phase 1 → Phase 2 is a strict additive change: `local-path` is
  untouched, Longhorn appears alongside it.

Negative / ongoing:

- Per-app PVCs now require an explicit `storageClassName` decision at
  deploy time (cache → none, distributed DB → `local-path`, valuable
  singleton → `longhorn`). The heuristic is captured in `CONTEXT.md`,
  but it is one more thing to remember.
- Longhorn brings ~6 controller / CSI pods plus a manager DaemonSet on
  every worker — meaningful but not prohibitive overhead.
- iSCSI becomes the data path for Longhorn volumes; a misbehaving worker
  can stall a volume across the cluster. Failure modes differ from
  `local-path` and need operator familiarity.
- Talos system-extension upgrades are now a recurring obligation —
  every Talos version bump requires rebuilding the factory image with
  the same extensions, or iSCSI tooling silently disappears at the next
  upgrade.

## Alternatives Considered

**Flip the cluster default to `longhorn`.** Rejected because the
dominant workload class going forward (self-replicating distributed DBs
in Skaffold dev namespaces) would have to opt *out* of the default on
every PVC. Forgetting that override layers storage replication under
application replication with no operational signal — silent
write-amplification trap. The opt-in direction (default = cheap, named
class = expensive) aligns better with the failure blast radius.

**Don't install Longhorn; use `local-path` everywhere and rely on
backup/restore for the singleton cases.** Rejected because the named
singleton workloads (Forgejo especially) want to survive planned worker
drains without manual restore. The recurring operational cost of "back
up, drain, restore on another node" each time a worker is patched is
higher than the ongoing cost of running Longhorn for those volumes.

**NFS CSI driver to a NAS.** Deferred — no NAS exists yet. When one is
purchased, NFS-CSI becomes a third `StorageClass` for bulk / cold
storage (media, large file shares). It would not replace Longhorn for
transactional singletons (Postgres, Forgejo repos), where block
semantics and local-NVMe read performance matter.

**Rook / Ceph.** Rejected at this scale. Ceph wants more nodes, more
disks per node, and more operational attention than this cluster
justifies. Longhorn sits at the correct point on the
complexity/capability curve for a 6-node homelab.
