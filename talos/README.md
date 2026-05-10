# Talos

Machine configuration for the `rockingham` Talos cluster.

## Layout

- `patches/nodes/<hostname>.yaml` — per-node machine config patches (hostname,
  static address, install disk, VIP membership). Version-controlled.
- `_out/` — generated artifacts. Gitignored. Contains `secrets.yaml`,
  `talosconfig`, base `controlplane.yaml` / `worker.yaml`, and per-node
  patched configs.

## Cluster

- Name: `rockingham`
- Control plane endpoint: `https://192.168.1.240:6443` (shared VIP)
- Nodes:
  - `cp-01` — `192.168.1.245`, install disk `/dev/nvme0n1`, NIC `eno1`

## First-time generation

Run from the repo root.

```sh
mkdir -p talos/_out

# 1. Generate cluster secrets (one-time, keep safe).
talosctl gen secrets -o talos/_out/secrets.yaml

# 2. Generate base controlplane.yaml / worker.yaml / talosconfig.
talosctl gen config rockingham https://192.168.1.240:6443 \
  --with-secrets talos/_out/secrets.yaml \
  --output-dir talos/_out/

# 3. Produce the per-node config for cp-01 by patching the base controlplane.
talosctl machineconfig patch talos/_out/controlplane.yaml \
  --patch @talos/patches/nodes/cp-01.yaml \
  -o talos/_out/cp-01.yaml
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
