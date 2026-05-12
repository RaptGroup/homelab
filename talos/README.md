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
- Nodes (install disk `/dev/nvme0n1`, NIC `eno1` on every node):
  - `cp-01` — `192.168.1.245` (carries the `.240` VIP)
  - `cp-02` — `192.168.1.246` (carries the `.240` VIP)
  - `cp-03` — `192.168.1.247` (carries the `.240` VIP)
  - `worker-01` — `192.168.1.241`
  - `worker-02` — `192.168.1.242`
  - `worker-03` — `192.168.1.243`

## Installer image (Image Factory)

Workers run a custom installer built via the
[Talos Image Factory](https://factory.talos.dev) so the `iscsi_tcp` kernel
module and `util-linux` tooling are present for Longhorn (ADR-0005). Control
planes still run the stock installer — Longhorn is workers-only.

- **Schematic** (`customization.systemExtensions.officialExtensions`):
  - `siderolabs/iscsi-tools`
  - `siderolabs/util-linux-tools`
- **Schematic ID:** `613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245`
- **Worker installer image (Talos v1.13.0):**
  `factory.talos.dev/installer/613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245:v1.13.0`
- **Control-plane installer image (stock):**
  `ghcr.io/siderolabs/installer:v1.13.0`

### Rebuilding the schematic

The schematic ID is the SHA-256 of the schematic YAML, so re-uploading the
same file returns the same ID. To regenerate (or change the extension set):

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

### Talos version upgrades

System extensions are baked into the installer, so every Talos minor / patch
bump must re-resolve to a factory URL pinned at the new version (and the
schematic ID above stays valid). Update the URL in this README, then roll
the workers with `talosctl upgrade --image factory.talos.dev/installer/<id>:<new-version>`.

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

GSM keeps every version. Old versions remain accessible by version
number until you explicitly destroy them.

### Restore (new machine, lost local files)

```sh
mkdir -p talos/_out
gcloud secrets versions access latest \
  --secret=talos-cluster-secrets \
  --project=rockingham-homelab \
  > talos/_out/secrets.yaml
chmod 600 talos/_out/secrets.yaml

# Regenerate talosconfig from the restored secrets.
talosctl gen config rockingham https://192.168.1.240:6443 \
  --with-secrets talos/_out/secrets.yaml \
  --output-dir talos/_out/

# Then fetch a fresh kubeconfig from the live cluster.
export TALOSCONFIG=$PWD/talos/_out/talosconfig
talosctl --endpoints 192.168.1.240 --nodes 192.168.1.245 \
  kubeconfig ./talos/_out/kubeconfig
```

### Belt-and-suspenders

GSM is the primary store. Keep a second copy in a password manager
(1Password, Bitwarden) so cluster recovery doesn't depend on GCP being
reachable.
