---
title: Loki
description: Single-binary log aggregation backend — the searchable log surface across all six nodes, queried from Grafana.
---

[Loki](https://grafana.com/oss/loki/) is the lab's log aggregation
backend — the searchable store behind "show me every log line from
the `argocd` namespace in the last hour" without `kubectl logs`ing
pods by hand. It is the logs half of the self-hosted observability
stack ([ADR-0007](https://github.com/RaptGroup/homelab/blob/main/docs/adr/0007-observability-as-self-hosted-stack.md)),
one of the three Argo Applications — alongside
[kube-prometheus-stack](./kube-prometheus-stack/) and
[Alloy](./alloy/) — that make up the [Observability stack](./observability/).

Loki **stores and serves** logs; it does not collect them.
[Alloy](./alloy/) is the collector that ships every pod's stdout into
Loki. Loki on its own is an empty, queryable store.

## Where it runs

A single multi-source ArgoCD `Application` in the shared
`observability` namespace: the `grafana/loki` chart (pinned at
`6.55.0`) plus this repo's `helm-values.yaml`.

```
kubernetes/apps/loki/
├── application.yaml   # multi-source ArgoCD Application
└── helm-values.yaml   # grafana/loki chart values — single-binary mode
```

Source lives at
[`kubernetes/apps/loki/`](https://github.com/RaptGroup/homelab/tree/main/kubernetes/apps/loki).
There is no `manifests/` directory — the `observability` namespace is
owned by the [kube-prometheus-stack](./kube-prometheus-stack/)
Application, and Loki is ClusterIP-only, so there is no `Namespace`
manifest and no `HTTPRoute`.

## Single-binary mode

Loki runs in **single-binary mode** (`deploymentMode: SingleBinary`):
one process running every Loki module, backed by a filesystem object
store on one PVC. This is the chart-recommended shape for installs
under roughly 1 TB/day — comfortably the right size for a six-node
homelab. The chart's default `SimpleScalable` mode (separate
read/write/backend tiers) is explicitly zeroed to nil replicas, and
the nginx gateway, memcached caches, and canary are all disabled —
they exist to serve multi-tier Loki and are dead weight for one
binary.

`auth_enabled` is `false`: a single-tenant homelab needs no
`X-Scope-OrgID` tenancy. This matches ADR-0007's mutual-trust tenancy
model — every Grafana user sees every namespace's logs.

## Retention and storage

ADR-0007 sets log retention to **14 days**. Three knobs in
`helm-values.yaml` enforce it together: a `retention_period` of
`336h`, the compactor's `retention_enabled` (the compactor is what
actually deletes — without it the horizon is advisory), and a
`retention_delete_delay` grace window.

Chunks and the tsdb index sit on a **100 GB PVC** with
`storageClassName: longhorn`
([ADR-0005](https://github.com/RaptGroup/homelab/blob/main/docs/adr/0005-longhorn-as-named-non-default-storageclass.md)
— singleton, valuable, must survive a node drain). Auto-delete of the
PVC on a StatefulSet prune is forced off, so an Argo prune cannot take
14 days of logs with it.

## Querying from Grafana

Loki is provisioned as a Grafana datasource at
`http://loki.observability.svc:3100` — wired from
kube-prometheus-stack's `helm-values.yaml`, since Grafana lives in
that chart. In Grafana's **Explore** view, pick the Loki datasource
and write [LogQL](https://grafana.com/docs/loki/latest/query/):

```logql
{namespace="argocd"} |= "error"
```

Logs are labelled `namespace`, `pod`, `container`, and `job` by
[Alloy](./alloy/). The same Grafana is the front door for both metrics
and logs, so a metric spike and the log lines from that window
correlate in one pane.

## More

The repo-side README at
[`kubernetes/apps/loki/README.md`](https://github.com/RaptGroup/homelab/blob/main/kubernetes/apps/loki/README.md)
covers the single-binary tier-zeroing in detail, the schema-config
backdating that lets pre-install pod logs ingest, the PVC resize path,
and the full smoke-test sequence.
