# ADR-0007: Observability as a self-hosted Prometheus + Loki + Alloy stack

## Status

Accepted (2026-05-14).

## Context

The `rockingham` cluster has, until now, two pieces of in-cluster
observability: **Hubble UI** for live network-flow visualisation, and
**metrics-server** to back `kubectl top`. Everything else is `kubectl logs`
across pods and stitching the story together by hand. There is no
time-series view of node or addon health, no aggregated log surface across
the six nodes, no alerting when something fails, and no signal at all that
reaches the operator when they are not actively watching the cluster.

A previously-recorded plan framed full observability as a Tier-2 learning
deep-dive deferred to "later." That window is closing for a concrete
reason: real application developers are about to land in their own
namespaces (the audience-B half of the cluster's mission). The decisions
made now — what telemetry exists at the cluster level, what contract
developers use to plug into it, what surface they see when debugging their
own services — will shape how every app on this cluster gets instrumented.
Shipping nothing means each developer invents their own observability and
the cluster ends up with no coherent answer to "where do I look at my
service?"

The constraints in tension are real but tractable at this scale:

- **Single operator, six nodes.** Whatever lands has to be operable by one
  person without dedicating Sundays to it. Anything more elaborate than a
  homelab needs (Mimir, Cortex, a horizontally-scaled Prometheus
  fleet) is overkill.
- **Existing patterns to respect.** ArgoCD app-of-apps under
  `kubernetes/apps/` (ADR-0001) is how addons land. Cilium Gateway API
  (ADR-0002) is how ingress works. `*.lab.jackhall.dev` (ADR-0003) is the
  LAN-only surface. Longhorn (ADR-0005) is the named, non-default
  `StorageClass` for valuable singleton state. New observability work
  should plug into these — not stand up parallel infrastructure.
- **Audience split.** Audience A is the operator today; audience B is the
  app developer arriving in `lab.*` namespaces shortly. The cluster-level
  shape has to serve A immediately *and* hand B a frictionless
  instrument-your-app contract without B having to do cluster-side
  configuration.
- **No traced workloads yet.** The first traced workload is somewhere on
  the horizon, not in this PRD. Building Tempo + the trace pipeline today
  means paying steady-state cost for zero immediate signal; deferring it
  but leaving the OTLP receiver hook in place pre-pays the integration.
- **Public surface is unwanted.** The operator is the only Grafana user
  for the foreseeable future, on the LAN. A reviewer-style "share a URL
  with someone on cellular" need is what ADR-0006's `projects` surface
  exists for; observability is a different surface with different
  reachability needs.

Two broad shapes exist for landing observability on a small Kubernetes
cluster: hand the data to a hosted vendor (Grafana Cloud, Datadog, New
Relic, etc.) or self-host the stack on the cluster itself. Within
self-hosting there is a further split — pull in a "one chart for the whole
LGTM bundle" rollup (e.g. `grafana/lgtm-distributed`) or compose the
stack from per-component charts (kube-prometheus-stack, Loki, Alloy)
managed as independent Argo Applications.

## Decision

Run a **self-hosted observability stack on `rockingham`**, scoped to
metrics and logs for the initial cut, composed of three independently
versioned Argo Applications sharing a single `observability` namespace.
Concretely:

1. **Self-hosted, not Grafana Cloud.** Prometheus, Loki, Grafana,
   Alertmanager, and Alloy all run on `rockingham`. No
   metrics or logs leave the cluster. The lab is the wrong scale and the
   wrong shape for a hosted vendor's pricing (per-active-series billing
   on a cluster that exists partly to host whatever future developers
   want to instrument is open-ended cost), and self-hosting the LGTM
   stack is itself part of the operator's learning surface for this
   cluster.

2. **kube-prometheus-stack for metrics + alerts, separate Loki, separate
   Alloy.** The metrics half lands as the **kube-prometheus-stack**
   chart (Prometheus, Grafana, Alertmanager, node-exporter,
   kube-state-metrics, and the bundled dashboard library). Logs land as
   the **`grafana/loki`** chart in single-binary mode, and log
   collection lands as the **`grafana/alloy`** chart as a DaemonSet.
   Each is its own Argo Application under
   `kubernetes/apps/{kube-prometheus-stack,loki,alloy}/`, so the Loki
   chart can be bumped without dragging Prometheus along (and
   vice-versa). The `observability` namespace is declared once, in the
   `kube-prometheus-stack` Application's `manifests/`, and the other two
   Applications attach to it. **Tempo and tracing are deferred to Phase
   3** — Alloy's OTLP receiver (gRPC 4317, HTTP 4318) is enabled on day
   one as a documented but unrouted endpoint, so the day a traced
   workload arrives the integration is a Tempo install and a route
   change, not a stack redesign.

3. **`ServiceMonitor` as the canonical developer metrics contract;
   auto-log-collection as the canonical logs contract.** A developer
   exposes `/metrics` in Prometheus format on their Service and drops a
   namespace-scoped `ServiceMonitor` next to it; Prometheus auto-discovers
   it with no cluster-side configuration. This is enforced by setting
   `serviceMonitorSelectorNilUsesHelmValues: false` plus all four
   selectors (`serviceMonitorSelector`, `podMonitorSelector`,
   `ruleSelector`, plus their `*NamespaceSelector` counterparts) to `{}`
   — wide-open discovery across every namespace. The override is
   commented in `helm-values.yaml` naming the
   "only-chart-labelled-ServiceMonitors-are-discovered" footgun so a
   future chart bump can't silently reintroduce it. The logs equivalent
   is **zero-action**: Alloy auto-discovers every pod's stdout/stderr
   via Kubernetes metadata and ships it to Loki labelled by namespace,
   pod, and container. A developer does nothing to get logs into Loki.

4. **Mutual-trust tenancy.** No per-tenant query isolation in Prometheus
   or Loki. Every authenticated Grafana user sees every namespace's
   metrics and every namespace's logs. The operator and any
   future developer landing in `lab.*` are mutually trusted parties
   investigating cluster health together; bolting label-proxies or
   Mimir-style multi-tenancy onto a six-node homelab to enforce a
   tenancy boundary that does not socially exist is overhead without
   benefit. **The day a real threat model demands isolation, the
   primitives to enforce it (per-tenant Loki, a label-enforcer in front
   of Prometheus, etc.) are well-trodden and can be added without
   reshaping the rest of the stack.**

5. **Anonymous Grafana viewers + admin-only login.** Grafana is
   configured with `auth.anonymous.enabled: true` and `org_role:
   Viewer`. A LAN visitor at `https://grafana.lab.jackhall.dev` sees
   dashboards immediately, no login. Editing (creating dashboards,
   modifying alerts, touching datasources) requires the admin login;
   the admin password is sourced via ESO from the
   `grafana-admin-password` GSM container — matching the existing
   secret-management pattern in this repo. **SSO is deferred until
   there are 3+ regular Grafana editors.** A GitHub OAuth or generic
   OIDC integration is a documented next step the day that trigger
   fires; configuring it now adds ceremony (provider, secret, callback
   URL, token rotation) for a one-user case where the admin password
   pattern is already paying its own way.

6. **Retention windows: 30 days metrics, 14 days logs.** Prometheus
   keeps 30 days of metrics
   (`prometheus.prometheusSpec.retention: 30d`) on a 100 GB
   Longhorn-backed PVC. Loki keeps 14 days of logs
   (`limits_config.retention_period: 336h` with
   `compactor.retention_enabled: true`) on a 100 GB Longhorn-backed
   PVC. These windows cover the "did this start two weeks ago?"
   investigation pattern without committing to long-term cold storage
   on this cluster. Longer retention is a remote-write-to-object-store
   problem solved separately if it ever becomes load-bearing.

7. **LAN-only reach via `grafana.lab.jackhall.dev`; no Cloudflare
   Tunnel.** Grafana is exposed by a raw `HTTPRoute` under the
   `kube-prometheus-stack` Application's `manifests/`, attaching to the
   central `lab` Cilium Gateway by cross-namespace `parentRef`,
   hostname `grafana.lab.jackhall.dev`. AdGuard's wildcard rewrite
   (`*.lab.jackhall.dev → 192.168.1.201`, ADR-0003) resolves it for
   LAN devices configured to use AdGuard. cert-manager's existing
   `*.lab.jackhall.dev` DNS-01 wildcard covers the cert. **Prometheus
   and Alertmanager are ClusterIP-only** — raw UIs reachable by
   `kubectl port-forward` when needed; no HTTPRoute, no LAN surface.
   The `projects` Cloudflare-Tunnel surface from ADR-0006 is for
   reviewer-targeted preview workloads, not for cluster operator
   tooling, and Grafana does not need a phone-on-cellular reachability
   property to do its job.

All four stateful PVCs in this stack — Prometheus, Alertmanager, Grafana
SQLite, and Loki — carry `storageClassName: longhorn`, fitting ADR-0005's
"singleton, valuable, must survive node drain" heuristic. Losing
Prometheus's TSDB on a worker reboot is exactly the failure mode
Longhorn exists to prevent for this workload class.

## Consequences

**Positive**

- Audience A (the operator) gets, on day one: a Grafana dashboard per
  cluster addon, a node-level dashboard for all six nodes, a single
  searchable log surface labelled by namespace/pod/container,
  Alertmanager routing to a Discord webhook, and a
  `Watchdog`-via-healthchecks.io dead-man's switch that survives a
  fully-dead Prometheus. None of those previously existed.
- Audience B (future app developers) gets a frictionless instrumentation
  contract: `ServiceMonitor` for metrics, nothing at all for logs,
  `PrometheusRule` for per-namespace SLOs, and a documented (though not
  yet active) OTLP push endpoint at `alloy.observability.svc:4317/:4318`
  for the day they reach for tracing. No developer waits for the
  operator to add a scrape config, label a namespace, or grant
  cross-namespace permissions.
- One Grafana is the front door for both metrics and logs — debugging
  doesn't context-switch between tools, and the in-Grafana Explore view
  correlates a metric spike against the logs from the same time window
  in one pane.
- Three independent Argo Applications mean a Loki chart bump is decoupled
  from a Prometheus chart bump. The blast radius of upgrading any one
  component is bounded.
- The OTLP receiver on Alloy being live from day one means Phase 3
  (Tempo + traces) is a Tempo install and a route addition, not a
  fan-out instrumentation change every developer has to make.
- The stack's four stateful PVCs ride on Longhorn (ADR-0005), so a node
  drain or pod reschedule doesn't lose metrics or logs history. Per-PVC
  recurring snapshots and weekly backups (Longhorn's defaults to GCS via
  the S3 interop API) cover catastrophic loss.

**Negative / ongoing**

- Three Helm releases to keep current instead of one (Datadog/Grafana
  Cloud would be zero). Chart-version bumps are operator-driven; the
  recurring obligation is the same shape as every other addon in
  `kubernetes/apps/` but it does exist.
- Grafana on this stack is single-instance SQLite (not the chart's
  Postgres-HA path). A node-drain blip on the Grafana pod is a brief
  503; users either retry or wait. Acceptable for a one-operator,
  occasional-visitor surface — explicitly not acceptable if Grafana
  becomes a real-time dashboard customers depend on, which it will not
  on this cluster.
- Retention is bounded at 30 days for metrics and 14 days for logs.
  Investigating "did this start three months ago?" requires deciding
  *now* (before that window expires) to extend retention or to wire up
  remote-write to an object store; neither is in scope for this stack.
- Mutual-trust tenancy means a misconfigured `ServiceMonitor` from one
  namespace can scrape another namespace's `/metrics` if it happens to
  match the labels — there is no namespace-isolation enforcement at
  Prometheus's discovery layer. Acceptable because every party landing
  workloads on this cluster is the operator or someone the operator has
  knowingly let in; **not acceptable** the day a non-trusted party
  arrives, at which point per-tenant Loki or a Prometheus label-enforcer
  is the documented next step.
- Anonymous Grafana viewers means any LAN device that resolves
  `grafana.lab.jackhall.dev` can see every dashboard, including
  potentially sensitive operational signal (error rates, internal
  service names). Acceptable for a LAN with a known device population
  configured behind manual-DNS-at-AdGuard (ADR-0003); the day Grafana
  needs to be visible to guests or untrusted LAN clients, anonymous
  goes off.
- The Alertmanager Discord receiver, the healthchecks.io watchdog ping
  URL, and the Grafana admin password are three new GSM containers in
  `terraform/gcp/`. Out-of-band operator actions are needed to populate
  the values — same pattern as `cloudflare-api-token` and friends, but
  it is one more secret-pipeline obligation per new external
  integration.
- Cluster-level CPU and memory cost of the stack is non-trivial: a
  Prometheus pod, an Alertmanager pod, a Loki pod, an Alloy DaemonSet
  on every node, kube-state-metrics, node-exporter on every node, and
  Grafana itself. Sized for `rockingham`'s 6 workers; would warrant a
  second look on a 2-node cluster.

## Alternatives Considered

### Grafana Cloud (or another hosted SaaS — Datadog, New Relic, Honeycomb)

Rejected. The pricing models for hosted observability vendors are
per-active-series and per-GB-ingested, and a homelab whose explicit
purpose is to host whatever future workloads developers want to land has
unbounded ingest potential. The vendor cost would scale with developer
activity in a direction that punishes exactly the use case this cluster
exists to support. Beyond cost: every metric and log line leaving the
cluster for a third-party SaaS is a data-egress and privacy decision that
this lab has not made for any other surface. The LAN-only `lab` surface
(ADR-0003) and the public-but-non-sensitive `projects` surface (ADR-0006)
both keep cluster data on cluster infrastructure; sending observability
to Grafana Cloud would be the one workload that leaks every other
workload's telemetry off the cluster.

A secondary factor: self-hosting the LGTM stack is itself part of the
learning surface this cluster is built to deliver. Outsourcing it
removes that learning. The shape this cluster commits to is "run the
thing yourself, document the operational pattern, hand it to a developer
as a contract" — and hosted observability is exactly the wrong direction
for that.

### Full LGTM-stack rollup (e.g. `grafana/lgtm-distributed`)

Rejected. The "one chart for the whole LGTM bundle" path lands all of
Loki + Grafana + Tempo + Mimir + their shared dependencies as a single
Helm release with a single version. The version-coupling is opaque:
bumping the bundle to pick up a Loki fix drags every other component's
upstream-version change along, and the chart's values surface is one big
nested map rather than per-component knobs. Argo's sync-and-health story
is also worse — a single Application that owns everything has a
coarse-grained healthy/unhealthy signal.

The composed approach (one Argo Application per component) trades a
small amount of upfront wiring for **independent version cadence**
(bump Loki without bumping Prometheus), **explicit per-component values
files** (the Prometheus retention knob and the Loki retention knob live
in different files with different comments), and **per-Application
Argo health signals** (Argo tells the operator "Loki is degraded" rather
than "the observability bundle is degraded"). At three components, the
composed shape is strictly better. The day a fourth (Tempo) lands in
Phase 3, it joins as a fourth Application with the same shape — no
chart-version coupling, no nested-values negotiation.

The rollup chart is the correct answer for a "give me a working LGTM
stack on a brand-new cluster as fast as possible" use case, which is not
this one.

### Per-tenant query isolation from day one (label-proxy in front of Prometheus, Mimir multi-tenancy, per-tenant Loki)

Deferred, not rejected outright. The primitives — `label-proxy` for
Prometheus, Mimir's per-tenant API, Loki's `X-Scope-OrgID` header — are
all real and well-trodden. The reason they are not in this ADR is that
isolation enforces a boundary that does not socially exist on this
cluster today. The operator and any developer landing in a `lab.*`
namespace are mutually trusted parties investigating cluster health
together. Forcing a label-proxy on every Grafana query (and the
operational debt of maintaining a per-tenant config) for a boundary that
no one wants on the *other* side of would be pure tax.

The day a real non-trusted party lands a workload on this cluster — a
preview environment from an outside contributor that the operator wants
to give "see your own metrics, not mine" access — Mimir or
label-proxy-in-front-of-Prometheus becomes the documented next step.
It does not require any change to the developer-facing `ServiceMonitor`
contract, only to the Grafana datasource configuration and a new
gating layer.

### Grafana SSO (GitHub OAuth or generic OIDC) from day one

Deferred. The current Grafana user population is one operator. A
single-user SSO integration is ceremony — provider setup, callback URL,
token rotation, the GSM/ESO pipeline for the client secret, a CI lint
to catch drift — without behavioural delta versus the
admin-password-via-ESO pattern already in place. **The deferral has a
concrete trigger:** the day there are 3+ regular Grafana editors, the
admin-password-as-shared-secret pattern stops scaling and SSO becomes
the right answer. Until then, anonymous viewers cover the
look-at-a-dashboard case and admin login covers the edit case.

### Longer retention windows (e.g. 90d metrics, 60d logs)

Rejected. 30 days of metrics and 14 days of logs cover every
investigation pattern the operator currently runs (and the patterns
audience-B developers will plausibly run as they land). Doubling either
window doubles the PVC size requirement and the Longhorn replication
load for marginal signal. The "did this start three months ago?"
investigation is a remote-write-to-object-store problem (Loki chunks to
GCS via the boltdb/tsdb shipper, Prometheus remote-write to GCS or
GCM), which is a separate stack-shape decision and explicitly out of
scope for the initial cut.

### Cloudflare Tunnel for Grafana (`grafana.projects.jackhall.dev`)

Rejected. The `projects` Cloudflare-Tunnel surface (ADR-0006) exists to
deliver reviewer-targeted preview workloads to people on phones, on
cellular, with no LAN configuration. Grafana is operator tooling for a
LAN-attached operator with AdGuard already configured; the public
surface gives capability that is not wanted (every Grafana URL hits
Cloudflare's edge, every login lands on a public path, every dashboard
is one CF Access misconfiguration away from being world-readable) at
the cost of a third-party in the request path for a tool that exists to
help the operator see their own cluster. The LAN-only Gateway with the
existing wildcard cert is the correct surface for this workload.

### Hubble UI replaces the need for a separate metrics stack

Rejected. Hubble UI is a **live flow-forensic** view: it answers "what
TCP connections are happening right now between these pods, and which
are being dropped?" Prometheus + Grafana answer **time-series** questions:
"what is the trend of drops over the last seven days, and how does it
correlate with the cert-manager renewal failure that paged me at 03:00?"
These are different question shapes; one does not substitute for the
other. Hubble UI stays exactly as it is; the new stack scrapes Hubble's
metrics endpoints so Cilium-and-Hubble Grafana dashboards work without
standing up a separate observability path for the data plane.

## Cross-references

- **ADR-0001 (IaC strategy):** the three stack components land as Argo
  Applications under `kubernetes/apps/`, not in `terraform/bootstrap/`.
  The Cilium values change that turns on Hubble metrics is the
  bootstrap-time exception ADR-0002 calls out.
- **ADR-0002 (Cilium unified networking):** Grafana's HTTPRoute attaches
  to the central `lab` Cilium Gateway by cross-namespace `parentRef`.
  Hubble's `serviceMonitor.enabled: true` is a Cilium-values bump in
  `terraform/bootstrap/`.
- **ADR-0003 (public domain, DNS-01 wildcard, split-horizon):** the
  `grafana.lab.jackhall.dev` hostname resolves on LAN via AdGuard's
  wildcard rewrite, and the existing `*.lab.jackhall.dev` cert-manager
  wildcard cert covers Grafana with no per-host issuance.
- **ADR-0005 (Longhorn as a named, non-default StorageClass):** all four
  of the stack's stateful PVCs (Prometheus 100 GB, Alertmanager 10 GB,
  Grafana SQLite 10 GB, Loki 100 GB) carry `storageClassName: longhorn`
  because they are singleton, valuable, and must survive a node drain.
- **ADR-0006 (public preview environments via Cloudflare Tunnel):** the
  `projects` Cloudflare-Tunnel surface is a different surface for a
  different audience; Grafana deliberately does not use it.
