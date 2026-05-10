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

Two IPs in the pool are pinned and load-bearing for the lab's name
resolution:

- `.200` — AdGuard Home DNS. The one stable address LAN devices point
  manual DNS at.
- `.201` — central `lab` Cilium Gateway (`kubernetes/apps/lab-gateway/`).
  Every web-exposed addon attaches its HTTPRoute here via
  cross-namespace `parentRefs`. AdGuard's seed config writes
  `*.lab.jackhall.dev → 192.168.1.201`, so every addon hostname
  resolves through the central Gateway by construction — no per-host
  rewrites in the AdGuard UI as new addons come online.

The remaining `.202`–`.230` are first-come-first-served for any future
`LoadBalancer` Service.

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

The GitHub App installation IS the access boundary for cluster-reaching CI,
so both installations run with `repository_selection: selected` — never
`all`. The allowlist is the precise set of repos with workflows that target
a self-hosted runner; adding a new such workflow means adding the repo to
the corresponding install at the same time.

### `arc-systems`

The namespace the ARC controller (`gha-runner-scale-set-controller` chart)
lives in. The `AutoscalingRunnerSet` CRD it owns is cluster-scoped, but the
controller pod, its SA, and its leader-election lease all live here. Each
scale set gets its own per-pool namespace (`arc-runners-raptgroup`,
`arc-runners-brazostech`) so the runner pods, listener, and the ESO-synced
GitHub App Secret are isolated per scope.

### `arc-runners-raptgroup`

Targets `https://github.com/RaptGroup` — the operator's personal-projects
GitHub org. Workflows opt in with `runs-on: [self-hosted, linux, raptgroup]`.
Backed by the GitHub App installation on the RaptGroup org, scoped to a
selected-repo allowlist (currently `RaptGroup/homelab` and
`RaptGroup/zipmenu-public`).

`RaptGroup` exists because ARC's chart can't serve user-account scopes
(only repository, org, or enterprise URLs work). Personal repos that
need cluster-reaching CI get transferred into RaptGroup rather than
maintaining one repo-scoped scale set per repo.

### `arc-runners-brazostech`

Targets `https://github.com/brazostech`. Workflows opt in with
`runs-on: [self-hosted, linux, brazostech]`. Backed by the GitHub App
installation on the `brazostech` org, also pinned to a selected-repo
allowlist. **Not** installed on Scale Computing; that boundary is enforced
server-side by GitHub.

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

## CI/CD

### `gcp` (GitHub deployment environment)

The protected GitHub environment that gates apply credentials for
`terraform/gcp/`. Carries deployment-branch restriction = `main` and
required reviewer = repo owner. The
[`terraform-apply.yml`](.github/workflows/terraform-apply.yml) workflow's
`apply` job declares `environment: gcp`; GitHub holds the job in
`Waiting` until a reviewer approves, and the OIDC token issued for
the job carries `environment: gcp` as a claim that GCP's WIF binding
keys on. Created manually in the GitHub UI — there is no Terraform
resource for "GitHub deployment environment" in this repo. See
ADR-0004.

### `tf-ci-plan` and `tf-ci-apply` (CI service accounts)

The two GCP service accounts CI uses to talk to the
`rockingham-homelab` project. Provisioned by `terraform/gcp/`:

- **`tf-ci-plan`** — `roles/viewer` on the project. Consumed by
  `terraform-plan.yml` (PR plans) and the `plan` job of
  `terraform-apply.yml` (apply-time re-plan). Impersonable from any
  workflow job whose OIDC token's `repository` claim matches
  `var.github_repository`.
- **`tf-ci-apply`** — `roles/owner` on the project. Consumed by the
  `apply` job of `terraform-apply.yml`. Impersonable only from a job
  that declares `environment: gcp`; combined with the provider's
  repo lock, this is equivalent to the
  `repo:RaptGroup/homelab:environment:gcp` selector. Reachable only
  after a reviewer approves the deployment in the GitHub UI.

Plan and apply credentials are deliberately separate so a token
compromised mid-plan cannot apply.

### Environment-per-root convention

GitHub deployment environment names mirror Terraform root names:
`gcp` ↔ `terraform/gcp/`. If the `bootstrap` root grows a CI apply
in the future, it gets a `bootstrap` environment with its own
approver list, its own apply SA, and its own
`terraform-apply-bootstrap.yml` workflow. One environment per root
keeps approver policies decoupled across roots that have very
different blast radii.
