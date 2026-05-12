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

### `projects.jackhall.dev`

The DNS subzone used for **public preview environments** of PR / branch
builds (`<svc>-<ns>.projects.jackhall.dev`). NS-delegated from the apex
`jackhall.dev` zone in Cloud DNS to a Cloudflare-managed zone; the
records inside the subzone live at Cloudflare, not in Cloud DNS.

Distinct from `lab.jackhall.dev` on every axis worth tracking:

- **Audience.** `lab` is LAN-only, for the operator and configured
  devices. `projects` is public, for reviewers on cellular, guest
  laptops, and colleagues.
- **DNS provider.** `lab` lives in Cloud DNS. `projects` lives at
  Cloudflare.
- **Cert chain.** `lab` uses a Let's Encrypt wildcard issued by
  cert-manager via DNS-01 against Cloud DNS, pinned by the apex CAA.
  `projects` uses Cloudflare's edge wildcard, issued by Cloudflare's
  contracted CAs; the subzone carries its **own CAA record** that
  overrides the apex Let's-Encrypt-only pin for the subzone only.
- **Front door.** `lab` is reached via the `lab` Cilium Gateway at
  `192.168.1.201` on the LAN. `projects` is reached via Cloudflare
  Tunnel → `cloudflared` → the `projects` Cilium Gateway's ClusterIP.
  Nothing on the LB pool serves preview traffic.

See ADR-0006.

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

### `projects` Gateway

The second cluster Gateway, alongside `lab`. Lives in `gateway-system`,
serves `*.projects.jackhall.dev` over **HTTP on port 80** (TLS
terminates at Cloudflare's edge; the in-cluster hop is cleartext inside
the `cloudflared` tunnel). Lives in
[`kubernetes/apps/projects-gateway/`](./kubernetes/apps/projects-gateway);
`cloudflared` reaches it via the auto-generated Service
`cilium-gateway-projects` in `gateway-system`.

ADR-0006 calls for a ClusterIP-only Service so the Gateway never
appears on the LB pool. **Cilium 1.16 (the cluster's current version)
cannot deliver that property** — its Gateway controller always
generates `type: LoadBalancer` for a Gateway resource, and
`CiliumGatewayClassConfig` (parametrized GatewayClass, 1.18+) only
supports `LoadBalancer` / `NodePort` for the generated Service. The
manifest therefore omits `lbipam.cilium.io/ips` per the issue's "no
LB pool IP annotation" instruction; Cilium assigns whatever's free
from `lab-pool` and the existing `lab-l2-workers` policy ARP-announces
it on workers. A LAN client that knows the IP and crafts a `Host:`
header can technically reach a preview workload — the public-DNS
path via Cloudflare is the intended route, and there's no AdGuard
rewrite for `*.projects.jackhall.dev`. Restoring the structural-
impossibility property is a follow-up (Cilium 1.18+ upgrade, or a
labelled L2-announcement opt-out).

`allowedRoutes.namespaces.from: Selector` with a namespaceSelector
requiring the label `projects.jackhall.dev/enabled=true`. Only
namespaces created by the preview-env wrapper carry the label, so the
Gateway will refuse to attach an HTTPRoute from any other namespace —
the gate is structural, not by convention.
[`scripts/lint-apps.sh`](./scripts/lint-apps.sh)'s LB-pin check treats
`from: Selector` as the marker for "this Gateway isn't on the LB pool
by design" and skips the pin requirement on it.

See ADR-0006.

### `cloudflared`

The outbound Cloudflare Tunnel connector that fronts the `projects`
Gateway. One `Deployment` in the `cloudflared` namespace
([`kubernetes/apps/cloudflared/`](./kubernetes/apps/cloudflared))
running the `cloudflare/cloudflared` container with the per-tunnel
connector token sourced via ESO from the GSM container
`cloudflare-tunnel-token`. The tunnel's ingress rules are
remote-managed (`config_src = "cloudflare"`), so the pod itself takes
only the token — the forward target is set at the CF side by
[`terraform/cloudflare/`](./terraform/cloudflare). Single replica;
`maxUnavailable: 0` keeps the connector alive across image bumps.

Deployed as raw manifests, not the upstream `cloudflare-tunnel-remote`
Helm chart: that chart bakes the token into values with no
"use an existing Secret" knob, which would put a long-lived
credential in git. Raw manifests keep the secret on the GSM → ESO
path that every other credential in this repo uses.

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

Deferred. Longhorn is added as a **named, non-default** `StorageClass`;
`local-path` stays the cluster default. Workloads opt in with
`storageClassName: longhorn` when they need node-portable storage —
singleton stateful apps with valuable data that must survive node drain.
Self-replicating apps (YugabyteDB, NATS, etc.) stay on `local-path` with
pod anti-affinity; layering replication under them is write amplification
for guarantees the app already provides.

Requires a Talos system-extension upgrade pass (`siderolabs/iscsi-tools`,
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

### `projects` (Artifact Registry repository)

The Docker-format Artifact Registry repository
(`us-east4-docker.pkg.dev/rockingham-homelab/projects`) that holds
preview-environment images. Region `us-east4` (Ashburn, VA) is
closest of the four US GCP regions to the Rockingham homelab and
to the GitHub-hosted runners that do most preview pushes. Image
paths look like:

```
us-east4-docker.pkg.dev/rockingham-homelab/projects/<workload>:<tag>
```

The repo name `projects` deliberately matches the public preview
subzone `projects.jackhall.dev` — image path and DNS hostname share
the same label, so an operator reading either knows they're
looking at the same surface. Cleanup policies delete untagged
blobs after 7 days and tagged versions after 90 days.

### `tf-ci-arc-push` and `tf-ci-cluster-pull` (Artifact Registry SAs)

The two service accounts that move images in and out of the
`projects` AR repo. Both are **repo-scoped** —
`roles/artifactregistry.{writer,reader}` is bound at the
repository level, not the project — so a leak does not reach
anything else in `rockingham-homelab`. Provisioned by
`terraform/gcp/`:

- **`tf-ci-arc-push`** — `roles/artifactregistry.writer` on the
  `projects` repo. Impersonable from any workflow whose
  `repository` OIDC claim is in
  `var.arc_push_repository_allowlist` (defaults: `RaptGroup/homelab`
  and `RaptGroup/zipmenu-public`). Auth path is GitHub OIDC →
  the `github-arc` WIF provider (separate from the
  RaptGroup/homelab-locked `github` provider used by
  plan/apply) → per-repo `workloadIdentityUser` binding. No
  key material anywhere.
- **`tf-ci-cluster-pull`** — `roles/artifactregistry.reader` on
  the `projects` repo. Consumed by in-cluster workloads. A JSON
  key lives in the GSM container `tf-ci-cluster-pull-key`
  (value uploaded out of band, same pattern as
  `argocd-repo-ssh-key`) and is exchanged in-cluster by an ESO
  `GCRAccessToken` generator for a short-lived dockerconfigjson
  rotated every 30 minutes; see [`ar-canary`](#ar-canary). The
  long-lived credential is the SA key in GSM. Full
  cluster→GCP WIF (no key at all) would need a publicly-reachable
  Talos OIDC discovery endpoint plus a WIF pool trusting it —
  deliberately out of scope for #125.

### `ar-canary`

The canary namespace that exercises the AR cluster-pull path
end-to-end while the preview-env baseline is still in flight.
Runs the `ExternalSecret` + `GCRAccessToken` + dockerconfigjson
chain that the preview-env baseline will eventually template
into every preview namespace; lives under
`kubernetes/apps/ar-canary/` and gets deleted in the PR that
lands that baseline. See ADR-0006 / #125.

### Preview-environment workflow

The path a branch / PR build takes to become a public preview at
`<svc>-<ns>.projects.jackhall.dev`. Two wrappers, one shape:

- **Local `just` recipe** — `just preview-up <repo> <branch>` /
  `just preview-down`, run from the operator's workstation against
  the cluster kubeconfig. Used for ad-hoc previews of work in
  progress.
- **PR-driven GitHub Actions workflow** — runs on an ARC pool
  (`runs-on: [self-hosted, linux, raptgroup]` or `brazostech`,
  per [`arc-runners-raptgroup`](#arc-runners-raptgroup) /
  [`arc-runners-brazostech`](#arc-runners-brazostech)). Creates a
  preview on PR open, refreshes it on push, deletes it on PR
  close. ARC's selected-repo allowlist is the boundary that
  controls which repos can create previews.

Both wrappers render and apply the same per-namespace bundle:

1. Namespace with the `projects.jackhall.dev/enabled=true` label
   and a `projects.jackhall.dev/expires-at` annotation.
2. `ResourceQuota` + `LimitRange` capping per-preview compute.
3. `CiliumNetworkPolicy` allowing ingress only from the
   `projects` Gateway and `cloudflared`, and egress only to kube
   DNS and the public internet.
4. The workload's manifests, plus an `HTTPRoute` attaching to the
   `projects` Gateway.

A small TTL-reaper CronJob in `projects-system` deletes any
preview namespace whose `expires-at` has passed. There is no
custom controller; the wrapper is the source of truth.

See ADR-0006.

### Environment-per-root convention

GitHub deployment environment names mirror Terraform root names:
`gcp` ↔ `terraform/gcp/`. If the `bootstrap` root grows a CI apply
in the future, it gets a `bootstrap` environment with its own
approver list, its own apply SA, and its own
`terraform-apply-bootstrap.yml` workflow. One environment per root
keeps approver policies decoupled across roots that have very
different blast radii.
