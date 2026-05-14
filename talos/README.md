# Talos

Machine configuration for the `rockingham` Talos cluster.

## Layout

- `patches/cluster/<topic>.yaml` — cluster-level machine config patches
  applied to every control plane (e.g. kube-apiserver flags). Same
  content goes onto every CP because Talos's `cluster:` section is
  cluster-wide.
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

## Worker disk layout

Workers have a 2 TB NVMe (`/dev/nvme0n1`). Talos's default `EPHEMERAL` volume
auto-grows to consume the whole disk, leaving no free space for Longhorn.
Each `worker-*.yaml` patch caps `EPHEMERAL` at **200 GiB** and declares a
`UserVolumeConfig` named `longhorn` that claims the remainder (~1.8 TiB),
mounted at `/var/mnt/longhorn` as XFS.

Note: on Talos v1.13 the `iscsi_tcp` kernel module is **built into** the
kernel image, so `lsmod | grep iscsi_tcp` returns nothing. Functionality is
confirmed via `/sys/module/iscsi_tcp` and the `ext-iscsid` service from the
`iscsi-tools` extension. The patch still declares `machine.kernel.modules`
as a no-op safety net in case a future Talos version ships it as a loadable
module.

### Resizing after the fact

Shrinking `EPHEMERAL` requires wiping it (XFS cannot shrink). For a worker
that was installed before the cap landed:

```sh
talosctl --nodes <ip> apply-config --file talos/_out/worker-XX.yaml
talosctl --nodes <ip> reset --system-labels-to-wipe EPHEMERAL --reboot --graceful=false
```

This loses containerd image cache + pod ephemeral state on that worker only.
Cordon and drain first.

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
#    Order matters: cluster-level patches go first so per-node patches
#    can still override anything they need to.
talosctl machineconfig patch talos/_out/controlplane.yaml \
  --patch @talos/patches/cluster/oidc-issuer.yaml \
  --patch @talos/patches/nodes/cp-01.yaml \
  -o talos/_out/cp-01.yaml
```

Workers don't run kube-apiserver, so the cluster-level patch is a no-op
on `talos/_out/worker.yaml` — including it is harmless but only the
control-plane configs need it.

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

## OIDC issuer for cluster→GCP WIF

Default `--service-account-issuer` is cluster-internal
(`https://kubernetes.default.svc.cluster.local`), which is unreachable
from outside the LAN. GCP STS needs to fetch the cluster's OIDC
discovery document + JWKS to validate the projected K8s SA tokens it
exchanges for federated access tokens, so the issuer URL has to point
at a publicly-reachable endpoint.

The chosen pattern: a public-read GCS bucket served at
`https://storage.googleapis.com/rockingham-homelab-oidc`. Cheapest URL
shape with a valid TLS cert (no Cloud LB, no custom DNS, no ACM
rotation). The bucket and its `/.well-known/openid-configuration`
object are TF-managed in `terraform/gcp/`; the `/openid/v1/jwks`
object is operator-uploaded out of band because its contents come
from the live cluster.

`patches/cluster/oidc-issuer.yaml` sets the apiserver flags. It is
applied alongside the per-node CP patches in the
`talosctl machineconfig patch` command above. Workers don't run
kube-apiserver, so it's a no-op there.

### Rolling the issuer onto a running cluster

This is a hard cut — changing `--service-account-issuer` invalidates
every existing projected SA token in the cluster, so anything holding
an old-issuer JWT (in-cluster controllers, webhook clients) gets
auth errors until kubelet refreshes its token (~80% of token expiry,
typically <1 h for default 1 h tokens, much faster for short-lived
projections). Plan the window:

1. Regenerate the patched cp configs locally with the new
   `--patch` flag (the command in "First-time generation" above).
2. Apply to each control plane in turn. Talos restarts the apiserver
   automatically:

   ```sh
   for ip in 192.168.1.245 192.168.1.246 192.168.1.247; do
     talosctl --nodes "$ip" apply-config \
       --file talos/_out/cp-XX.yaml
   done
   ```

   (Substitute the correct per-node file for each `$ip`.)

3. Once the apiserver on at least one CP is back up, fetch the JWKS
   that ships the cluster's current signing public keys and push it
   to the OIDC bucket:

   ```sh
   kubectl get --raw /openid/v1/jwks > /tmp/jwks.json
   gcloud storage cp /tmp/jwks.json \
     gs://rockingham-homelab-oidc/openid/v1/jwks \
     --content-type=application/json \
     --cache-control='public, max-age=300'
   rm -f /tmp/jwks.json   # shred isn't on macOS; APFS/ext4 make file-level overwrite unreliable anyway — FileVault/LUKS is the gate
   ```

4. Verify external resolvers see the discovery doc and JWKS:

   ```sh
   curl -s https://storage.googleapis.com/rockingham-homelab-oidc/.well-known/openid-configuration | jq .
   curl -s https://storage.googleapis.com/rockingham-homelab-oidc/openid/v1/jwks | jq .
   ```

   The discovery doc's `issuer` field must match the URL it was
   fetched from. The JWKS must contain at least one key whose `kid`
   matches the `kid` in a freshly-minted projected SA token:

   ```sh
   kubectl create token default -n default --duration=10m \
     --audience=//iam.googleapis.com/projects/$(gcloud projects describe rockingham-homelab --format='value(projectNumber)')/locations/global/workloadIdentityPools/cluster/providers/talos \
     | cut -d. -f1 | base64 -d 2>/dev/null | jq .kid
   ```

5. After every Talos secret rotation (`talosctl gen secrets` →
   re-apply), re-run step 3. The JWKS is the only operator-side
   refresh needed — the discovery doc is static and TF-managed.

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
