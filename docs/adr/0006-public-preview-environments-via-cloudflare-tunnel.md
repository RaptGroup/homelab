# ADR-0006: Public preview environments via Cloudflare Tunnel

- **Status:** Accepted; amended 2026-05-12 (see [Amendment](#amendment-2026-05-12-records-in-apex-zone-not-a-delegated-subzone)) and 2026-05-13 (see [Amendment](#amendment-2026-05-13-cost-10mo-for-wildcard-cert))
- **Date:** 2026-05-11

## Context

The homelab has so far had one north-south surface: `*.lab.jackhall.dev`,
LAN-only, fronted by the central `lab` Cilium Gateway, reachable only
from LAN devices that point manual DNS at AdGuard Home. That is the
right shape for the steady-state addons (dashboard, ArgoCD UI, Hubble
UI) — they don't want to be on the internet, and the per-device DNS
configuration is acceptable for the small set of devices that need
them. ADR-0003 covers that surface end-to-end.

The work coming next does not fit that mould. Branch builds out of
Skaffold-driven dev namespaces (and PR previews from those same
repositories) need a URL that:

- A reviewer can click from a phone or a laptop that has never been
  configured for the lab — no AdGuard DNS, no VPN, no `/etc/hosts`.
- Carries a publicly-trusted TLS certificate the browser does not
  complain about.
- Does not require punching inbound holes through the Optimum gateway
  or exposing the LAN's L2 surface to the internet.
- Comes up and tears down on the timescale of a PR (minutes to hours),
  not the timescale of an addon (weeks to forever).

This is a deliberately different surface from `*.lab.jackhall.dev`:
public on purpose, ephemeral on purpose, and reached by people who
have no relationship with the LAN.

Two reasonable shapes exist for landing inbound traffic into a bare-metal
cluster behind a residential ISP:

- **GCP-native:** a small GCE bastion in `rockingham-homelab` with a
  WireGuard or IAP-TCP tunnel back to a worker, fronted by an HTTPS
  GCLB with a Google-managed cert. Reuses the GCP project that already
  exists, keeps the request path inside infra this repo already owns
  via Terraform.
- **Cloudflared:** a `cloudflared` Deployment in-cluster, dialled
  outbound to Cloudflare's edge, with TLS terminated at the edge and
  cleartext HTTP forwarded across the tunnel to a ClusterIP Service
  inside the cluster. No inbound ports. No bastion to own.

The end states are functionally similar — a reviewer's HTTPS request
lands at an in-cluster Gateway — but the operational shapes diverge:

- The GCP-native path costs roughly **$25/mo steady-state** (small e2
  VM + the GCLB's per-rule and data-processed charges) and adds **a
  bastion to own** — patching, IAM, firewall rules, SSH/IAP auth,
  monitoring. Call it 1–2 days of initial setup and a recurring
  obligation thereafter.
- The Cloudflared path costs **$0** at homelab volume (the free
  Cloudflare tier covers it), adds **one Deployment to the cluster**,
  and offloads TLS termination, DDoS handling, and the edge IP to
  Cloudflare. The recurring obligation is "keep the `cloudflared` Helm
  release current" — same shape as every other addon.

The lab is a single-operator concern. The bastion's tax is not paid for
by the bastion delivering more capability than the tunnel does; both
end at the same in-cluster Gateway. The GCP path is the more "purist"
answer (no third party in the request path, no soft dependency on
Cloudflare staying in business), but it pays steady-state cost and
steady-state ownership for parity, not for capability.

Public DNS for the preview surface also splits cleanly from the
existing setup. `lab.jackhall.dev` is a Cloud DNS zone NS-delegated
from the apex; its CAA pins issuance to Let's Encrypt only, which is
exactly what cert-manager needs and exactly what the cluster is
issuing today. A second subzone for previews can be delegated to
Cloudflare and managed there; certs for it issue via Cloudflare's
contracted CAs, not via cert-manager. That puts the two surfaces on
two separate cert-issuance paths and two separate CAA policies, which
is the correct factoring — they are different surfaces serving
different audiences with different threat models.

The naming shape for preview hostnames is constrained by the CA/B
Forum's prohibition on nested wildcards. A certificate for
`*.projects.jackhall.dev` covers `foo.projects.jackhall.dev` but does
**not** cover `foo.bar.projects.jackhall.dev`. Multi-label preview
names like `<svc>.<ns>.projects.jackhall.dev` would force either
per-namespace wildcards (one cert per preview namespace, which defeats
the simplicity goal) or per-host certs (per-PR ACME round-trips,
which is exactly what `*.lab.jackhall.dev` was set up to avoid).
Collapsing the label to `<svc>-<ns>.projects.jackhall.dev` keeps every
preview hostname under one wildcard.

The preview workload itself is untrusted in the way a long-lived addon
is trusted. A PR build is, by construction, code that has not landed
yet. The preview Gateway must not become a path for a misbehaving
preview to reach the LAN-only Gateway, the kube API, the LAN, or
neighbour preview namespaces; the per-namespace footprint must also be
bounded so a single preview cannot exhaust cluster resources.

## Decision

Run **public preview environments through a Cloudflare-Tunnel-fronted
`projects` Cilium Gateway, with a flat single-label hostname
convention and per-preview-namespace hardening applied at deploy time
by the wrapper that creates the namespace.** Concretely:

1. **Subzone.** `projects.jackhall.dev` is a new DNS subzone,
   **NS-delegated from the Cloud DNS apex `jackhall.dev` to a
   Cloudflare-managed zone.** The delegation NS records live in the
   apex zone (managed in `terraform/gcp/`); the records inside
   `projects.jackhall.dev` live in Cloudflare. The apex CAA record
   (ADR-0003) pins issuance to Let's Encrypt; the `projects` subzone
   gets its **own CAA record** allowing Cloudflare's contracted CAs.
   The apex pin is unchanged; this is an explicit override scoped to
   the subzone only.

   *(Amended 2026-05-12: CF's subdomain-zone path requires the parent
   zone to be on CF authoritative DNS too, so the apex moves to CF
   and `projects.*` lives as records inside the CF apex zone — not a
   separate NS-delegated subdomain zone. See
   [Amendment](#amendment-2026-05-12-records-in-apex-zone-not-a-delegated-subzone)
   and ADR-0003's matching amendment.)*
2. **Flat naming.** Preview hostnames follow
   `<svc>-<ns>.projects.jackhall.dev` — one label deep, with the
   namespace baked into the leftmost label by a `-` rather than a
   `.`. One wildcard cert (`*.projects.jackhall.dev`, managed at
   Cloudflare's edge) covers every preview hostname. Per-host ACME
   round-trips do not happen; per-namespace wildcards do not happen.
3. **Central `projects` Gateway.** A single Cilium `Gateway` named
   `projects` lives in `gateway-system` alongside the existing
   `lab` Gateway:
   - Listener: `*.projects.jackhall.dev` on **port 80, protocol
     HTTP**. TLS terminates at Cloudflare's edge; the hop from
     `cloudflared` to the Gateway's ClusterIP is cleartext inside
     the tunnel and never crosses the LAN.
   - `allowedRoutes.namespaces.from: Selector`, with a
     namespaceSelector requiring the label
     `projects.jackhall.dev/enabled=true`. Namespaces that do not
     carry the label cannot attach an HTTPRoute to this Gateway. The
     wrapper applies the label as part of creating a preview
     namespace; nothing else does.
   - **No LB-pool IP.** The `projects` Gateway is exposed only via a
     ClusterIP `Service`. `cloudflared` targets that ClusterIP. The
     Gateway never appears on `192.168.1.200–.230`, so no LAN client
     can reach a preview by accident or by scanning, and the LB pool
     stays a LAN-only construct.
4. **`cloudflared` Deployment.** One Helm release under
   `kubernetes/apps/cloudflared/` running the `cloudflared`
   container, configured with an ingress rule that forwards
   `*.projects.jackhall.dev` to the `projects` Gateway's ClusterIP.
   The tunnel credential is a `cloudflared`-issued token, stored in
   Google Secret Manager and synced into the namespace by ESO — same
   pattern as every other secret in the repo. No inbound port
   forwarding on the Optimum gateway; the tunnel dials outbound from
   the cluster.
5. **Per-preview-namespace hardening, wrapper-applied.** Every
   preview namespace ships, at creation time, with:
   - A `ResourceQuota` bounding total CPU, memory, and pod count
     so a runaway preview cannot starve the cluster.
   - A `LimitRange` giving every container a default request and
     limit, so workloads that omit `resources` do not get
     unbounded scheduling.
   - A `CiliumNetworkPolicy` that allows ingress only from the
     `projects` Gateway and `cloudflared`, and allows egress only to
     kube DNS and the public internet — not to the kube API, not to
     other preview namespaces, not to addon namespaces, not to the
     LAN.
   - A namespace annotation
     `projects.jackhall.dev/expires-at=<RFC3339-timestamp>` set by
     the wrapper; a small **TTL reaper** CronJob in a
     `projects-system` namespace deletes any preview namespace
     past its expiry.
   These four resources are templated and applied by the wrapper
   that creates the namespace — **not by a custom controller**.
   There is no `PreviewEnvironment` CRD, no reconciler watching the
   `projects.jackhall.dev/enabled` label. The wrapper is the source
   of truth; if the wrapper did not create the namespace, the
   hardening is not there and the Gateway's namespaceSelector
   refuses to attach routes regardless.
6. **Two wrappers, one shape.** The wrapper exists in two forms,
   both producing the same per-namespace bundle (namespace +
   hardening + workload manifests + HTTPRoute):
   - A **local `just` recipe** for operator-driven previews
     (`just preview-up <repo> <branch>` / `just preview-down`),
     running against the operator's kubeconfig.
   - A **PR-driven GitHub Actions workflow** that runs on the ARC
     pool (`runs-on: [self-hosted, linux, raptgroup]` /
     `brazostech`), creating a preview on PR open, refreshing it on
     push, and deleting it on PR close. ARC's cluster-reaching
     credential boundary (see CONTEXT.md "ARC") is the same
     boundary that gates preview creation.
   Both wrappers do exactly the same thing — render the bundle,
   `kubectl apply`, post the preview URL — so the preview shape is
   identical regardless of who started it.
7. **No auth gate, deliberately.** Cloudflare Access can sit in
   front of any `*.projects.jackhall.dev` hostname and require a
   login. **Not configured in this ADR.** The threat model for the
   current use case is "share a URL with a reviewer for a few
   hours"; a login wall is friction without benefit. The day an
   actually-sensitive preview workload shows up, CF Access is the
   pre-cleared answer — it does not require any change to the
   Gateway, the tunnel, or the wrapper; it is configured at
   Cloudflare and applies on a per-hostname basis. Recording that
   deferral here so the future "should we add auth?" decision has a
   starting point.

## Consequences

**Positive**

- Reviewers get a real URL with a browser-trusted cert and no
  configuration on their device. The preview is reachable from a
  phone on cellular, a guest laptop, or a colleague's machine.
- No inbound ports on the Optimum gateway. The cluster reaches
  Cloudflare; Cloudflare reaches the reviewer. The lab's "no inbound
  exposure" stance from ADR-0003 is preserved for the LAN-only
  surface — `*.projects.jackhall.dev` is a separate Gateway with a
  separate cert chain, not an exception punched into the LAN one.
- Steady-state cost is $0 and steady-state ownership is one Helm
  release. The same operational shape as every other addon.
- One wildcard cert covers every preview. Adding a new preview is
  creating a namespace with the right label; no per-host issuance,
  no per-namespace cert.
- The `projects` Gateway's namespaceSelector is a structural gate,
  not a convention. A namespace without
  `projects.jackhall.dev/enabled=true` cannot attach a route to the
  preview Gateway even if its HTTPRoute manifest declares it as a
  parentRef. Misconfiguration mode is "preview doesn't show up,"
  not "preview accidentally publishes from a non-preview
  namespace."
- The per-namespace hardening bundle gives every preview a
  per-namespace resource ceiling, a default request/limit, an
  egress firewall, and an expiry — none of which depend on the
  preview workload doing anything correctly.
- The wrapper-applied-not-controller-managed choice means there is
  no custom controller to operate, no CRD to keep current, and no
  reconciler drift to debug. The cost of a missed update (a
  namespace created out-of-band by a stray `kubectl create`) is
  bounded: the namespaceSelector keeps it off the Gateway, the
  TTL reaper does not see an expiry annotation and never deletes
  it, but it also has no quota or network policy. A stray
  preview-shaped namespace is a one-line `kubectl delete` rather
  than a debugging session.
- LAN exposure of preview workloads is structurally impossible. The
  `projects` Gateway has no LB-pool IP; the only path in is via
  `cloudflared`. Even if a reviewer leaks the URL, the LAN does not
  see the preview.

**Negative / ongoing**

- Hard dependency on Cloudflare. If Cloudflare is down or the
  account is locked out, every preview is unreachable. This is
  acceptable because previews are by definition non-critical and
  short-lived — the LAN-only surface (ADR-0003) carries no
  Cloudflare dependency, so cluster operations continue.
- Third party in the public request path. Cloudflare terminates TLS
  and sees plaintext for every preview. The preview workloads are
  not sensitive by construction, but this is a real change in
  trust surface compared to the LAN-only path where no third party
  is involved.
- The CAA override at `projects.jackhall.dev` widens the set of
  CAs that can issue for that subzone. The apex CAA pin to Let's
  Encrypt is untouched, so this does not affect
  `lab.jackhall.dev` or anything else under the apex; the wider
  CAA is scoped to the subzone only.
- Two DNS providers in play: Cloud DNS for everything under
  `jackhall.dev` and `lab.jackhall.dev`, Cloudflare for everything
  under `projects.jackhall.dev`. Adding a new public preview
  hostname is a Cloudflare-side operation (handled by the
  wrapper); adding a new internal lab hostname is a Cloud-DNS-side
  operation. The split is clean (per subzone) but the operator
  has to remember which side a given record lives on.
- The TTL reaper is a small piece of always-on cluster code (a
  CronJob) that lives outside the wrapper. It is the only piece of
  preview infrastructure that is not wrapper-applied; if it stops
  running, preview namespaces accumulate. Mitigated by the
  CronJob being trivial (a `kubectl delete` driven by an
  annotation) and by Homepage surfacing preview-namespace count so
  drift is visible.
- The per-namespace hardening bundle is duplicated by both
  wrappers. If the bundle changes (e.g. a new NetworkPolicy rule),
  both wrappers have to be updated, or they will diverge.
  Mitigated by keeping the bundle as a single set of YAML
  templates that both wrappers consume — the `just` recipe and the
  GitHub workflow render the same files.
- `cloudflared` runs as a long-lived Deployment talking outbound to
  Cloudflare. Its token is a credential; rotation is on the
  operator. Stored in GSM and synced via ESO so the rotation
  pattern is the same as every other secret.
- Cloudflare Access is deferred. The day a preview workload needs
  an auth wall, the decision to add CF Access has to actually be
  made — and a reviewer who shares a URL before CF Access is on
  is sharing a publicly-reachable URL.

## Alternatives Considered

### GCP-native bastion + GCLB

Rejected on cost-for-parity grounds. The end state is the same — a
reviewer's HTTPS request lands at an in-cluster Gateway — but the
GCP path adds ~$25/mo and a bastion to own (patching, IAM, SSH/IAP,
monitoring) for no additional capability. The "no third party in
the request path" property is real but is paid for steadily, every
month, in dollars and operator attention. The lab is single-operator
and the preview surface is by-construction non-sensitive; spending
steady-state cost to avoid a soft dependency on Cloudflare is the
wrong direction here. If a future workload's threat model changes
that calculus, the GCP path is still on the table — `projects`
Gateway shape, namespaceSelector, wrapper, hardening bundle, and
TTL reaper are all reusable; only the front door changes.

### Reuse the LAN-only `lab` Gateway and expose previews on `*.lab.jackhall.dev`

Rejected. `*.lab.jackhall.dev` is LAN-only by design (ADR-0003); a
reviewer on cellular cannot reach it. Punching `*.lab` through to
the internet (whether via tunnel or GCLB) would force the wildcard
that today covers internal addons to also cover untrusted PR
previews, which collapses the security split between "things on the
LAN" and "things on the internet" into one cert and one Gateway.
Keeping the surfaces and their certs distinct is exactly the point.

### Multi-label preview hostnames (`<svc>.<ns>.projects.jackhall.dev`)

Rejected. The CA/B Forum baseline prohibits nested wildcards: a
single `*.projects.jackhall.dev` wildcard does not cover
`foo.bar.projects.jackhall.dev`. Multi-label names would require
either per-namespace wildcards (one cert per preview namespace,
which defeats the "one wildcard, every preview" simplicity goal)
or per-host issuance (per-PR ACME round-trips and rate-limit
exposure). Flattening the label with a `-` collapses both names
into one wildcard and removes the issuance question.

### Per-preview-namespace controller (CRD-driven preview environments)

Rejected at this scale. A `PreviewEnvironment` CRD plus a controller
that watches the
`projects.jackhall.dev/enabled` label and applies the hardening
bundle is the "correct" answer for a fleet of preview environments
managed by a team. At homelab scale it adds: a controller to
operate, a CRD to keep current, RBAC to maintain, and reconciler
drift to debug — for the same end-state YAML that two wrapper
scripts apply directly. The wrapper-applied path scales linearly
with preview count in a way that is fine for tens of previews per
week; it would warrant a second look at hundreds.

### `ngrok` or a similar tunnel-as-a-service

Rejected. ngrok and peers solve the same outbound-tunnel problem
Cloudflare Tunnel solves, with comparable shape. The deciding
factor is that Cloudflare already runs the public-DNS-and-edge
combination needed here: NS-delegating a subzone to Cloudflare
gives the wildcard cert (issued by CF's contracted CAs against the
CAA override) and the tunnel endpoint in a single pane of glass,
under one account, with one billing relationship. ngrok adds a
fourth provider (alongside Cloud DNS, GCS, Let's Encrypt) for a
function Cloudflare folds into the providers we are already
adding. No capability is unique to ngrok.

### Tailscale Funnel

Rejected for the same reasons it was rejected in ADR-0003 for the
LAN-only surface: every reviewer would need a Tailscale install.
That breaks the "phone on cellular" and "colleague's laptop" cases
that motivated public previews in the first place. Tailscale
remains useful as a future, separate decision for operator remote
access; it is not the right answer for "how do reviewers get to a
preview?"

## Amendment 2026-05-12 (records in apex zone, not a delegated subzone)

The original Decision point 1 framed `projects.jackhall.dev` as a
separate Cloudflare-managed subdomain zone NS-delegated from the
Cloud DNS apex. Implementing that revealed a Cloudflare constraint:

**CF's "Connect a domain" flow rejects subdomains, and the
subdomain-zone path on every plan (Free, Pro, Business) requires the
parent zone to be on Cloudflare authoritative DNS too.** The only
path that keeps the apex elsewhere is CF Business plan's "Partial
(CNAME) Setup" at \$200/mo — which inverts the cost-for-parity
argument that ruled out the GCP-native alternative in the first
place (the GCP path was rejected at \$25/mo + bastion ownership; CF
Business is \$200/mo for less capability).

The amended shape: **the apex `jackhall.dev` moves to Cloudflare,
and `projects.*` records live as records inside the CF apex zone —
no separate subdomain zone.** ADR-0003 carries the matching
amendment for the apex move; this ADR's preview-surface shape is
what changes here.

1. **No subzone.** There is no `projects.jackhall.dev` zone as a
   separate Cloudflare resource. The records that ADR-0006's
   original framing put inside a subzone — CAA exception for CF's
   contracted CAs, wildcard CNAME for the tunnel — are now
   records at the `projects.jackhall.dev` *name* inside the CF
   apex `jackhall.dev` zone. CF Universal SSL covers wildcards
   under the apex, so issuance for `*.projects.jackhall.dev`
   continues to work as ADR-0006 intended.

2. **CAA exception.** The apex CAA in the CF apex zone is
   `letsencrypt.org` (mirrors the old Cloud DNS apex, see ADR-0003's
   amendment). A separate CAA at the `projects.jackhall.dev` name
   inside that same zone allows `pki.goog` and `letsencrypt.org` —
   CF's contracted CAs for Universal SSL issuance. The CAA walk
   for `<preview>.projects.jackhall.dev` hits this `projects` CAA
   record before reaching the apex CAA, so issuance is gated to
   CF's contracted CAs for this surface only, exactly as the
   original ADR intended.

3. **No NS delegation for `projects`.** Without a separate subzone,
   there is no NS delegation record to publish at the apex level
   for `projects.jackhall.dev`. The TF resource that originally
   represented that delegation (`apex_projects_delegation` in
   `terraform/gcp/`) does not exist. `terraform/cloudflare/`
   publishes records directly at `projects.*` names; resolution
   resolves them within the same apex zone, no inter-zone hop.

4. **Wildcard CNAME.** `*.projects.jackhall.dev → <tunnel-uuid>.cfargotunnel.com`,
   `proxied = true`. Published as a record at the `*.projects`
   name in the CF apex zone, not in a separate zone. CF terminates
   TLS at the edge using the apex zone's Universal SSL wildcard
   cert; the tunnel hop is cleartext HTTP from cloudflared to the
   `projects` Gateway's ClusterIP, identical to the original ADR.

5. **What stays.** The central `projects` Cilium Gateway,
   namespace-selector gating on `projects.jackhall.dev/enabled=true`,
   the in-cluster `cloudflared` Deployment, the per-namespace
   hardening bundle (ResourceQuota + LimitRange +
   CiliumNetworkPolicy + TTL annotation), the two-wrapper model,
   and the deferred CF Access auth gate are **all unchanged**. The
   amendment is scoped to the DNS structure only.

**Two-provider split, revisited.** ADR-0006's original "Negative
consequence" list called out a "two DNS providers in play: Cloud
DNS for apex+lab, Cloudflare for projects." Post-amendment, the
provider split is by **surface**, not by zone count: Cloud DNS
serves the `lab.jackhall.dev` records (cert-manager continues to
publish ACME TXT records there), CF serves the apex zone (which
contains both the lab NS delegation and the projects.* records).
Operationally identical — the operator still has to remember
which provider holds which records — but cleaner in TF state
shape: one zone per provider rather than two zones split across
providers.

## Amendment 2026-05-13 (cost: $10/mo for wildcard cert)

The 2026-05-12 amendment moved `projects.*` records into the CF apex
zone and asserted, in passing, that "CF Universal SSL covers wildcards
under the apex, so issuance for `*.projects.jackhall.dev` continues to
work as ADR-0006 intended." The implementation pass against #126's
tracer-bullet (PR #143) demonstrated end-to-end **HTTP** delivery —
operator → CF Anycast → tunnel → cloudflared → projects Gateway →
nginx Pod returns 200 — but **HTTPS to the same hostname failed at
CF's edge** with `alert handshake failure` before reaching cloudflared
at all.

**Root cause.** CF Universal SSL on the Free plan covers depth-1 names
only: `<apex>` and `*.<apex>`. The CA/Browser Forum's nested-wildcard
prohibition means `*.jackhall.dev` does **not** cover
`<anything>.<anything>.jackhall.dev`. Our preview hostnames are
`<svc>-<ns>.projects.jackhall.dev` — two labels deep — so Universal
SSL has no cert that can serve them and CF rejects the TLS handshake
at the edge. The 2026-05-12 amendment's claim that wildcards "under
the apex" issue automatically was correct for the *one*-label case
(`*.jackhall.dev`) but wrong for the two-label case this surface
actually uses.

**Three options were enumerated:**

| | Cost | URL pattern | Code/ADR delta |
|---|---|---|---|
| **A. Activate ACM, order wildcard** | $10/mo | unchanged | small TF + ADR amendment |
| B. Drop `.projects.` infix | $0 | every preview URL changes | meaningful; abandons projects-as-namespace identity |
| C. Per-host DNS records | $0 | every preview URL changes | wrapper does CF API calls per preview-up; more operational complexity |

**Decision: Option A — activate ACM and order an advanced wildcard.**

- **B** rejected: the `<svc>-<ns>.projects.jackhall.dev` shape is the
  whole point of this ADR's flat-naming decision. Dropping the
  `.projects.` infix and using `<svc>-<ns>.jackhall.dev` would put
  preview hostnames on the apex alongside `lab.jackhall.dev` and
  whatever the operator might publish at apex in future, collapsing
  the "previews are a separate surface" property that ADR-0006 spent
  five pages building.
- **C** rejected: per-host DNS records means the wrapper does a CF
  API call on every `preview-up` to publish (and on every
  `preview-down` to clean up) a CNAME plus a per-host cert. The
  wrapper's contract today is `kubectl apply` against a templated
  bundle; bolting on per-preview-CF-API-state crosses an operational
  boundary the wrapper-applied-not-controller-managed choice in this
  ADR was specifically designed to avoid.
- **A** accepted: $10/mo for the ACM pack, no wrapper changes, no URL
  changes. Math still favours this over the GCP-native alternative
  ADR-0006 originally rejected — **$10/mo (ACM) ≪ ~$25/mo (GCLB +
  bastion) + bastion ownership**. The "no third party in request
  path" property remains the GCP path's only unique capability, and
  it remains insufficient on its own to flip the decision.

**Implementation.** `terraform/cloudflare/main.tf` adds a
`cloudflare_certificate_pack.projects_wildcard` resource:
`type = "advanced"`, `hosts = ["projects.jackhall.dev",
"*.projects.jackhall.dev"]`, `validation_method = "txt"`,
`validity_days = 90`, `certificate_authority = "google"`. DNS-01
validation is auto-served by CF inside the apex zone (which CF owns),
so no operator interaction is needed for validation or renewal. The
Google CA matches the `pki.goog` entry in the existing projects CAA
exception; `lets_encrypt` would also satisfy CAA but Google is CF's
default for ACM and issues faster.

**Token permission widening (prereq).** The CF API token in GSM
(`cloudflare-api-token`) was scoped to `Zone: Edit` + `DNS: Edit`
under the zone policy. `cloudflare_certificate_pack` calls the
certificate-pack API surface, which requires the **`SSL and
Certificates`** permission group — separate from `Zone` and `DNS`.
The operator widens the existing token in-place (no rotation; token
value unchanged) before `tofu apply`. Final zone-scope permissions:
`Zone: Edit`, `DNS: Edit`, `SSL and Certificates: Edit`.

**Steady-state cost update.** ADR-0006's original Consequences list
asserted "Steady-state cost is $0." That is downgraded to **$10/mo
for ACM**, $0 for tunnel + DNS — total $10/mo. Still less than half
the GCP-bastion alternative rejected upstream, no bastion to own, and
the operational shape (one Helm release + one Terraform-managed
resource) is unchanged.

**What stays.** Every shape decision in the original ADR and the
2026-05-12 amendment is unchanged: flat `<svc>-<ns>` naming, the
central `projects` Gateway with namespaceSelector gating, the
in-cluster `cloudflared` Deployment, the per-namespace hardening
bundle, the two-wrapper model, deferred CF Access. Only the
edge-cert provenance changes: Universal SSL → ACM-issued wildcard.
