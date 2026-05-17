---
title: Observability stack
description: How kube-prometheus-stack, Loki, and Alloy fit together — the self-hosted metrics-and-logs stack on rockingham.
---

The **observability stack** is the lab's self-hosted answer to "where
do I look at my cluster — and my service?" It is three Argo
Applications sharing one `observability` namespace, giving the
operator a time-series view of cluster health and a searchable log
surface across all six nodes, and giving application developers a
frictionless contract for instrumenting their own apps.

The load-bearing decisions — self-hosted over Grafana Cloud,
per-component charts over an LGTM rollup, `ServiceMonitor` as the
developer contract, mutual-trust tenancy, anonymous viewers, the
30-day / 14-day retention windows, LAN-only reach — are recorded in
[ADR-0007](https://github.com/RaptGroup/homelab/blob/main/docs/adr/0007-observability-as-self-hosted-stack.md).
This page narrates how the pieces fit; the ADR explains why.

## The three components

| Component | Role | Page |
|---|---|---|
| **kube-prometheus-stack** | Prometheus (metrics + alert evaluation), Grafana (the front door), Alertmanager (alert routing), node-exporter, kube-state-metrics | [kube-prometheus-stack](./kube-prometheus-stack/) |
| **Loki** | Stores and serves logs — the searchable log backend | [Loki](./loki/) |
| **Alloy** | Per-node DaemonSet that tails every pod's stdout and ships it to Loki; also hosts the OTLP receiver | [Alloy](./alloy/) |

Each is its **own** Argo Application under `kubernetes/apps/`, not a
single LGTM-rollup release. The chart versions move independently —
Loki can be bumped without dragging Prometheus along — and Argo
reports health per component rather than as one coarse signal.

## How the data flows

```
                       metrics                         logs
                          │                              │
  every pod / node ───────┤              every pod ───────┤
  (/metrics + a            │              (stdout/stderr)  │
   ServiceMonitor)         ▼                               ▼
                      Prometheus                    Alloy DaemonSet
                   (scrape · 30d TSDB                (one pod per node,
                    · alert rules)                    tails /var/log)
                          │                               │
              ┌───────────┤                               ▼
              ▼           ▼                              Loki
        Alertmanager    Grafana ◄─────────────────────  (14d log store)
        (routes alerts) (dashboards + Explore — the one routed surface)
              │
              ▼
   Discord + healthchecks.io  (alert pipeline — see below)
```

Two collection paths, one query surface. Prometheus **pulls** metrics
from anything advertising a `ServiceMonitor`; Alloy **pushes** logs
into Loki. Grafana queries both — its Explore view correlates a
metric spike against the log lines from the same window in one pane.

## The `observability` namespace

All three Applications live in a single `observability` namespace,
declared once in the kube-prometheus-stack Application's `manifests/`
so Loki and Alloy attach to it without a duplicate manifest. Its Pod
Security Admission is set to `privileged` — node-exporter needs host
networking and hostPath mounts, and Grafana's chart-shipped init
container chowns its PVC as root; the stricter profiles would
admission-block the stack on first sync.

## Surfaces and reach

**Grafana is the only externally-routed surface**, at
`grafana.lab.jackhall.dev` on the central [`lab` Gateway](./lab-gateway/),
LAN-only via AdGuard's wildcard rewrite
([ADR-0003](https://github.com/RaptGroup/homelab/blob/main/docs/adr/0003-public-domain-dns-tls-split-horizon.md)).
Anonymous LAN visitors are Viewers; editing requires the admin login.
Prometheus and Alertmanager are ClusterIP-only — raw UIs via
`kubectl port-forward`.

This is distinct from [Hubble UI](./hubble-ui/), which stays exactly
as it is. Hubble answers live flow-forensic questions ("what is
talking to what right now, and what is being dropped?"); the
observability stack answers time-series questions ("what is the trend
of drops over the last week?"). The stack scrapes Hubble's metrics so
the Cilium dashboard works — it does not replace Hubble UI.

## Alerting

Prometheus evaluates the chart-bundled alert rules plus any
`PrometheusRule` a developer drops in their own namespace. Firing
alerts reach Alertmanager. From there the **alert pipeline** routes
actionable alerts to a **Discord** webhook, and a `Watchdog`
heartbeat continuously pings **healthchecks.io** as a dead-man's
switch that survives a fully-dead Prometheus. The Discord and
healthchecks.io receivers ship in their own stack slice; see
[CONTEXT.md](https://github.com/RaptGroup/homelab/blob/main/CONTEXT.md)
for the pipeline's current status.

## Scope: metrics and logs now, traces in Phase 3

The initial cut is **metrics and logs**. Distributed tracing — Tempo
and the full trace pipeline — is deferred to **Phase 3**, to land
once a real traced workload arrives. The hook is pre-paid: Alloy's
OTLP receiver (`alloy.observability.svc:4317` / `:4318`) is live from
day one as a documented but unrouted endpoint, so Phase 3 is a Tempo
install and a route change rather than a stack redesign.

## For application developers

If you are landing an app in a `lab.*` namespace, the
[Observability for developers](/homelab/platform/observability-for-developers/)
page is the one-page contract: how to expose metrics with a
`ServiceMonitor`, the zero-action log guarantee, writing a
`PrometheusRule` for your own SLOs, the documented OTLP endpoint, and
the Scratch → code dashboard workflow.

## More

[ADR-0007](https://github.com/RaptGroup/homelab/blob/main/docs/adr/0007-observability-as-self-hosted-stack.md)
records the full decision tree and the alternatives rejected
(Grafana Cloud, the LGTM rollup, per-tenant isolation, SSO, longer
retention, a public Grafana). Each component's repo-side README — for
[kube-prometheus-stack](https://github.com/RaptGroup/homelab/blob/main/kubernetes/apps/kube-prometheus-stack/README.md),
[Loki](https://github.com/RaptGroup/homelab/blob/main/kubernetes/apps/loki/README.md),
and [Alloy](https://github.com/RaptGroup/homelab/blob/main/kubernetes/apps/alloy/README.md)
— carries the operator runbook and smoke tests.
