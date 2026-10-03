# Talos

Machine configuration for the `rockingham` Talos cluster.

## Layout

- `patches/cluster/<topic>.yaml` — shared machine config patches applied
  to every node, both control planes and workers, before any per-node
  patch. Use for node-level documents every node should carry
  (`filesystem-trim.yaml`); `cluster:`-section fields (e.g. kube-apiserver
  flags) also live here and simply have no effect on workers.
- `patches/nodes/<hostname>.yaml` — per-node machine config patches
  (hostname, static address, install disk, VIP membership).
  Version-controlled.
- `_out/` — generated artifacts. Gitignored. Contains `secrets.yaml`,
  `talosconfig`, base `controlplane.yaml` / `worker.yaml`, and per-node
  patched configs.

## Cluster

- Name: `rockingham`
- Control plane endpoint: `https://192.168.1.240:6443` (shared VIP)
- Nodes (install disk `/dev/nvme0n1`, NIC `eno1` on every node):
  - `cp-01` — `192.168.1.245` (carries the `.240` VIP)
  - `cp-02` — `192.168.1.246` (carries the `.240` VIP)
  - `cp-03` — `192.168.1.247` (carries the `.240` VIP)
  - `worker-01` — `192.168.1.241`
  - `worker-02` — `192.168.1.242`
  - `worker-03` — `192.168.1.243`

Every node runs Talos v1.14.0. Workers use a factory image carrying the
`iscsi-tools` and `util-linux-tools` system extensions — the Longhorn
prerequisites, so a future reinstall needs no reimage (see "Installer
images" below). They were dropped in the 2026-08 reset (ADR-0009) and
return ahead of that rebuild. Workers cap `EPHEMERAL` at 200 GiB — a
leftover from carving the disk for Longhorn. The ~1.8 TiB XFS partition
that era created still sits on each worker's disk unused; reclaiming it
means wiping EPHEMERAL (XFS can't shrink), deferred until a storage layer
is rebuilt.

## Filesystem trim

All nodes carry `patches/cluster/filesystem-trim.yaml` — a weekly
`FilesystemTrimConfig`. Talos only enables trim by default on clusters
generated with 1.14; `rockingham` was upgraded, so the document is
explicit here. Trim runs on mounted, trim-capable filesystems; a volume
with different needs overrides the interval with the `trim` block on its
volume document.

## Installer images (Image Factory)

From 1.14, `ghcr.io/siderolabs/installer` is no longer published;
installer images come from the [Image Factory](https://factory.talos.dev).
Workers use a schematic carrying the Longhorn prerequisites:

- `siderolabs/iscsi-tools`
- `siderolabs/util-linux-tools`

Schematic ID:
`613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245`
(the SHA-256 of the schematic YAML, so re-uploading the same file returns
the same ID). To regenerate it or change the extension set:

```sh
cat <<'EOF' > /tmp/schematic.yaml
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/iscsi-tools
      - siderolabs/util-linux-tools
EOF

curl -X POST --data-binary @/tmp/schematic.yaml https://factory.talos.dev/schematics
```

- Workers:
  `factory.talos.dev/metal-installer/613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245:<version>`
- Control planes:
  `factory.talos.dev/metal-installer/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba:<version>`
  (the empty schematic), except `1.13.x` where stock
  `ghcr.io/siderolabs/installer:<version>` is still published.

Both schematics stay valid across Talos versions, so an upgrade only
changes the `:<version>` tag.

## First-time generation

Run from the repo root.

```sh
mkdir -p talos/_out

# 1. Generate cluster secrets (one-time, keep safe).
talosctl gen secrets -o talos/_out/secrets.yaml

# 2. Generate base controlplane.yaml / worker.yaml / talosconfig.
#    The Kubernetes pin keeps a regenerated base on the cluster's running
#    version — the generator's default tracks the newest release and a
#    regenerated config must never bump the cluster by itself.
talosctl gen config rockingham https://192.168.1.240:6443 \
  --with-secrets talos/_out/secrets.yaml \
  --kubernetes-version 1.36.0 \
  --output-dir talos/_out/

# 3. Produce the per-node config for cp-01 by patching the base controlplane.
#    Shared cluster patches go first so per-node patches can still override
#    anything they need to.
talosctl machineconfig patch talos/_out/controlplane.yaml \
  --patch @talos/patches/cluster/filesystem-trim.yaml \
  --patch @talos/patches/cluster/no-default-cni.yaml \
  --patch @talos/patches/nodes/cp-01.yaml \
  -o talos/_out/cp-01.yaml

# Validate before the config goes anywhere near a node.
talosctl validate --mode metal --strict --config talos/_out/cp-01.yaml
```

Repeat step 3 for every node, using `talos/_out/worker.yaml` as the base
for the workers; the shared cluster patches apply to both roles. Also
point the talosconfig at the control planes:

```sh
export TALOSCONFIG=$PWD/talos/_out/talosconfig
talosctl config endpoint 192.168.1.245 192.168.1.246 192.168.1.247
```

Applying a config that switches CNI or disables kube-proxy updates the
manifests Talos advertises but does not remove resources already in the
cluster. `talosctl upgrade-k8s` is the supported prune path from v1.13
(it diffs against the `talos-bootstrap-manifests-inventory` ConfigMap) —
review the plan with `--dry-run` first:

```sh
talosctl upgrade-k8s --dry-run --to <current-kubernetes-version>   # review
talosctl upgrade-k8s --to <current-kubernetes-version>             # prune
```

## Applying to a node in maintenance mode

The node boots from install media, sits in maintenance mode at its DHCP
address, and accepts an insecure config push.

```sh
talosctl apply-config --insecure \
  --nodes 192.168.1.245 \
  --file talos/_out/cp-01.yaml
```

The node installs Talos to `/dev/nvme0n1`, reboots into the installed system,
and starts trying to form a cluster.

## Bootstrapping the first control plane

Only run this once, against the first control plane node, after it has
rebooted into the installed system.

```sh
export TALOSCONFIG=$PWD/talos/_out/talosconfig
talosctl config endpoint 192.168.1.240
talosctl config node 192.168.1.245

talosctl bootstrap
```

Then fetch the kubeconfig:

```sh
talosctl kubeconfig ./talos/_out/kubeconfig
```

## Adding more nodes

For each additional control plane node, write a `patches/nodes/<host>.yaml`
patch (matching its NIC, address, install disk) and repeat the patch +
apply-config steps. Workers use `worker.yaml` as the base instead of
`controlplane.yaml`.

## Upgrading Talos / changing machine config

An upgrade is per node: `talosctl upgrade` hands the node an installer
image and the node cordons and drains itself, swaps the OS image, and
reboots (`--wait` and `--drain` default to on). The A-B boot scheme keeps
the previous kernel/OS entry, so a failed boot rolls back automatically,
and `talosctl rollback` reverts a successful one.

Installer images for both roles are in "Installer images" above — workers
take every hop on the extension schematic, control planes on ghcr for
`1.13.x` and the empty factory schematic from `1.14.x`.

Take the latest patch of each intermediate minor before crossing a minor:
`v1.13.0 -> v1.13.10 -> v1.14.0`.

1. Before the first node, snapshot etcd from a control plane (the file is
   gitignored, so it stays out of the repo):

   ```sh
   talosctl --nodes 192.168.1.245 etcd snapshot talos/_out/etcd-<date>.snapshot
   ```

2. Roll one node at a time, checking health between nodes: a worker canary
   first, then the control planes one at a time (Talos refuses a control
   plane upgrade that would break etcd quorum; roll them one at a time
   anyway), then the remaining workers.

   ```sh
   # control planes: v1.13.0 -> v1.13.10 (ghcr image; still published for 1.13.x)
   talosctl --nodes <cp-ip> upgrade --image ghcr.io/siderolabs/installer:v1.13.10

   # workers: v1.13.0 -> v1.13.10 on the extension schematic
   talosctl --nodes <ip> upgrade \
     --image factory.talos.dev/metal-installer/613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245:v1.13.10

   # control planes: v1.13.10 -> v1.14.0 (empty schematic; ghcr stops at 1.13.x)
   talosctl --nodes <cp-ip> upgrade \
     --image factory.talos.dev/metal-installer/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba:v1.14.0

   # workers: v1.13.10 -> v1.14.0 (extension schematic)
   talosctl --nodes <ip> upgrade \
     --image factory.talos.dev/metal-installer/613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245:v1.14.0
   ```

3. After each node, `talosctl --nodes <ip> version` shows the new version
   and `kubectl get nodes` shows it `Ready`; for control planes also check
   `talosctl --nodes <ip> etcd status`. On a worker,
   `talosctl --nodes <ip> get extensions` should list `iscsi-tools` and
   `util-linux-tools`.

The worker patches pin the installer image for installs
(`patches/nodes/worker-0*.yaml`), so bump them alongside a cluster upgrade
and a rebuilt node comes back on the cluster's version. Control planes
inherit the image from the generated `_out/controlplane.yaml`; regenerate
with a `talosctl` matching the target version.

Other machine config changes go through the same patch-and-apply path.
From 1.14, `talosctl apply-config` no longer reboots by default and most
documents — `FilesystemTrimConfig` included — take effect live; reboot
explicitly for changes that need it, and cordon/drain workers first.

Note (observed on v1.13.0, 2026-08): an upgrade to the *same* version
stages the new boot entry but does not reboot the node — follow up with an
explicit `talosctl --nodes <ip> reboot`.

Kubernetes is not upgraded by an OS upgrade; `talosctl upgrade-k8s` is a
separate operation, and the cluster's Cilium/k8s support gap
(`terraform/bootstrap/variables.tf`) should be read before running it.

## Backing up `secrets.yaml`

`talos/_out/secrets.yaml` holds the cluster CA private key, etcd
bootstrap token, and KMS material. It is the only irreplaceable file
in the lab — losing it means the cluster can never be re-managed and
must be wiped and rebuilt from scratch. `talosconfig` and `kubeconfig`
can both be regenerated from `secrets.yaml`, so they don't need the
same care.

`terraform/gcp/` declares the GSM secret container `talos-cluster-secrets`.
Versions are uploaded out of band — pulling the value through Terraform
would land it in the GCS-backed state file too, doubling the surface
for no real benefit at homelab scale.

### Upload

After `talosctl gen secrets` (first-time generation) and after any
rotation:

```sh
gcloud secrets versions add talos-cluster-secrets \
  --project=rockingham-homelab \
  --data-file=talos/_out/secrets.yaml
```
