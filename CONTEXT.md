# CONTEXT

The canonical vocabulary used across this repo's PRs, ADRs, code, and chat.
If a term shows up in a commit message, an issue, or an agent session and
isn't self-evident, it should be defined here.

This file complements the ADRs under `docs/adr/`: ADRs explain **why** a
decision was made, CONTEXT explains **what we call things**. Where an entry
references a load-bearing decision, it points at the ADR by ID
(ADR-0001 etc.) instead of restating it.

## Cluster and naming

### `rockingham`

The Talos Kubernetes cluster's name. Used as the cluster identity in Talos
config, kubeconfig contexts, and dashboard branding. Not a hostname.

### `lab.jackhall.dev`

The DNS subzone used for every internal cluster service
(`dashboard.lab.jackhall.dev`, `argocd.lab.jackhall.dev`, etc.).
NS-delegated from the apex `jackhall.dev` zone (also in Cloud DNS) to
its own Cloud DNS managed zone.

### `jackhall.dev` (apex)

The apex domain is hosted in Cloud DNS in this repo's GCP project. The
registrar (Squarespace) was pointed at Cloud DNS nameservers when the
lab subzone was delegated, but those NS were applied at the apex
nameserver field rather than as a subdomain delegation, so the apex
has to live in Cloud DNS too — without it, queries at the apex return
REFUSED and Let's Encrypt's CAA walk SERVFAILs while trying to issue
`*.lab.jackhall.dev`. The apex zone holds the CAA record (Let's
Encrypt-only) and the NS delegation for the lab subzone; nothing else
is hosted at `jackhall.dev` itself.

### Split-horizon DNS

`lab.jackhall.dev` resolves to two different answer sets depending on who's
asking:

- **Internal view** — AdGuard Home, running in-cluster, resolves
  `*.lab.jackhall.dev` to LAN IPs in the LB pool. LAN devices configured to
  use AdGuard see this view.
- **Public view** — Google Cloud DNS holds only what ACME needs for DNS-01
  challenges. The internal LAN IPs are never published.

Same names, different answers. See ADR-0003.

### `rockingham-homelab` (GCP project)

The single GCP project that owns every cloud-side resource for the homelab
(DNS zone, service accounts, GSM secrets, TF state bucket). Isolation is
project-level so the homelab's blast radius is bounded.

## Networking

### Cilium (unified networking layer)

A single Helm release covering four roles that would otherwise be separate
addons:

- **CNI** — pod networking (replaces Flannel).
- **kube-proxy replacement** — services and load balancing in eBPF (no
  kube-proxy DaemonSet).
- **LB IPAM + L2 announcements** — assigns `LoadBalancer` service IPs from
  a pool and ARP-announces them on the LAN (replaces MetalLB).
- **Gateway API** — north-south HTTP routing (replaces Envoy Gateway).

This is the only thing that touches the data plane. See ADR-0002.

### LB pool (`192.168.1.200`–`192.168.1.230`)

The range Cilium hands out to `Service`s of type `LoadBalancer` via
`CiliumLoadBalancerIPPool`. Sits above the cluster nodes' static range and
below the broadcast end of the LAN.

Two IPs in the pool are pinned by the AdGuard Home addon and are
load-bearing for the lab's name resolution:

- `.200` — AdGuard Home DNS. The one stable address LAN devices point
  manual DNS at.
- `.201` — AdGuard Home's admin-UI Gateway. AdGuard's seed config
  writes `*.lab.jackhall.dev → 192.168.1.201`; the wildcard rewrite
  resolves AdGuard's own hostname out of the box. Other addons (e.g.
  Hubble UI) bring their own Gateway at a different LB-pool IP and
  the operator adds a per-host rewrite in the AdGuard UI as each
  comes online.

The remaining `.202`–`.230` are first-come-first-served for any future
`LoadBalancer` Service or addon Gateway.

### Static cluster range (`192.168.1.240`–`192.168.1.247`)

The fixed IPs assigned to cluster nodes and the control-plane VIP:

- `.240` — control-plane VIP (shared by `cp-01`/`cp-02`/`cp-03`).
- `.241`/`.242`/`.243` — workers.
- `.245`/`.246`/`.247` — control planes.

Static, set in the per-node Talos patches under `talos/patches/nodes/`.

### Optimum DHCP scope (`192.168.1.11`–`192.168.1.199`)

The Optimum Gateway 6E hands out DHCP leases only in this range, leaving
`.200`–`.254` free for static cluster and LB-pool use.

## DNS reach (LAN-side)

Three labels for **how** a LAN device ends up using AdGuard Home as its
resolver. They show up in conversation when discussing what's possible vs.
what we're actually doing.

### Path A — DHCP-pushed DNS

The Optimum gateway advertises AdGuard Home as the DNS server in DHCP
responses. Every device on the LAN automatically uses it. **Not achievable**
on the Optimum Gateway 6E (no custom-DNS field, no DHCP-disable). Recorded
for completeness only.

### Path B — Bridge mode + downstream router

The Optimum gateway is put in bridge mode and a user-owned router behind it
serves DHCP with a custom DNS field. Achievable but needs hardware. Recorded
as the future escape hatch if Path C gets annoying.

### Path C — Per-device manual DNS (current)

Each device that wants ad-blocking and `*.lab.jackhall.dev` resolution sets
`192.168.1.200` as its DNS server manually. Non-configured devices (guests,
IoT) bypass AdGuard and use Optimum's upstream — they get neither
ad-blocking nor internal name resolution. This is the current steady state.

## Storage

### Phase 1 (local-path)

The current state. `local-path-provisioner` is the default `StorageClass`.
PVCs bind to a directory on whatever node the pod first lands on; volumes
are not portable. Acceptable because every Phase 1 addon (AdGuard Home,
ArgoCD, Homepage) is a singleton.

### Phase 2 (Longhorn)

Deferred. Longhorn becomes the default `StorageClass` once a workload
genuinely needs node-portable replicated storage. Requires a Talos
system-extension upgrade pass (`siderolabs/iscsi-tools`,
`siderolabs/util-linux-tools`), an `iscsi_tcp` kernel module, and a
`UserVolume` patch carving an XFS partition for `/var/mnt/longhorn`.

## ARC (GitHub Actions runners)

Two scale sets, both backed by the same `Rockingham Homelab ARC` GitHub App
with two installations. Workflows pick a pool through the `runs-on:` label.

### `arc-runners-personal`

Targets `https://github.com/jvcorredor`. Workflows opt in with
`runs-on: [self-hosted, linux, personal]`. Backed by the GitHub App
installation on the `jvcorredor` user account.

### `arc-runners-brazostech`

Targets `https://github.com/brazostech`. Workflows opt in with
`runs-on: [self-hosted, linux, brazostech]`. Backed by the GitHub App
installation on the `brazostech` org. **Not** installed on Scale Computing;
that boundary is enforced server-side by GitHub.

Both scale sets default to `minRunners: 0`, `maxRunners: 4`, 500m CPU /
1Gi RAM / 10Gi ephemeral, ephemeral pods, no container mode.

## Repository conventions

### IaC split

Two — and only two — Terraform roots:

- `terraform/gcp/` — GCP-side resources (DNS zone, service accounts, GSM
  secrets, GCS state bucket).
- `terraform/bootstrap/` — Cluster-side bootstrap (Gateway API CRDs, Cilium,
  cert-manager, ESO, local-path, ArgoCD, the root `Application`).

Everything else — addon manifests, Helm values, runtime config — is owned
by ArgoCD via the app-of-apps pattern. Adding an addon is dropping a
directory under `kubernetes/apps/<name>/` and pushing; Terraform is not
touched. See ADR-0001.

### app-of-apps

A single root ArgoCD `Application` watches `kubernetes/apps/`. New
directories under it are picked up automatically. Not `ApplicationSet`.

### `kubernetes/apps/<name>/`

Per-addon directory layout: an `application.yaml` (the ArgoCD
`Application`), a `helm-values.yaml`, and an optional `manifests/` for raw
extras like `Gateway`, `HTTPRoute`, or `ExternalSecret`.
