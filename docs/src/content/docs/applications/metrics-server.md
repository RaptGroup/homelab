---
title: metrics-server
description: The Kubernetes Metrics API extension server — backs kubectl top, HPA, and Homepage's cluster CPU/RAM widget.
---

[metrics-server](https://github.com/kubernetes-sigs/metrics-server) is
the small extension API server that scrapes kubelet's
`/metrics/resource` endpoint on every node and exposes the result as
the `metrics.k8s.io/v1beta1` API. Without it, `kubectl top` returns
"Metrics API not available," `HorizontalPodAutoscaler` can't read
resource utilisation, and Homepage's cluster widget can't draw its
CPU/RAM bars. With it, all three Just Work.

## Where it runs

A single Deployment in the `metrics-server` namespace, plus the
`v1beta1.metrics.k8s.io` `APIService` registration that points the
aggregation layer at it. No UI, no LAN exposure, no secrets to sync —
the entire addon is the chart and a values file:

```
kubernetes/apps/metrics-server/
├── application.yaml     # multi-source ArgoCD Application
└── helm-values.yaml     # metrics-server chart values, tuned for Talos
```

Source lives at
[`kubernetes/apps/metrics-server/`](https://github.com/RaptGroup/homelab/tree/main/kubernetes/apps/metrics-server).

## What it unlocks

Three concrete consumers in this lab:

- **`kubectl top nodes` / `kubectl top pods`** — the operator's
  go-to "what's hot right now" check during incident triage. The CLI
  reads from `metrics.k8s.io` directly; nothing else has to be
  installed.
- **`HorizontalPodAutoscaler`** — any HPA that scales on `cpu` or
  `memory` (the two built-in metrics) reads from the same API. No
  HPAs ship with the lab today, but the moment one does, this is
  what feeds it.
- **Homepage's Kubernetes widget** — the cluster summary card on
  [`dashboard.lab.jackhall.dev`](https://dashboard.lab.jackhall.dev/)
  draws its cluster-wide and per-node CPU/RAM bars from this API.
  Without metrics-server the widget renders an "ensure you have
  metrics-server installed" string instead of bars.

## Talos-specific tuning

Talos issues kubelet serving certs from its own machine-CA, not from
the cluster CA that metrics-server validates against by default. Two
non-default args land in `helm-values.yaml` to make the scrape work
on this cluster:

| Arg                                                       | Why                                                                                                                                                       |
|-----------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------|
| `--kubelet-insecure-tls`                                  | Skip kubelet cert validation. Standard workaround on bare-metal Talos clusters; the alternative is plumbing the Talos machine-CA bundle into metrics-server, which is more surface than a read-only scrape warrants. |
| `--kubelet-preferred-address-types=InternalIP,Hostname`   | Chart default also lists `ExternalIP` in the middle. No node here has an `ExternalIP` (the cluster is LAN-only), so dropping it removes a dead lookup.    |

The full arg list lives in `defaultArgs:` (which the chart concatenates
with `args:`) so the resulting kubelet-flag set is explicit in Git —
no need to read the chart to know what's actually being passed.

## Why this isn't kube-prometheus-stack

metrics-server is **not** part of the
[observability stack](./observability/), and the distinction is worth
being explicit about. metrics-server is a strictly smaller thing, and
the two run side by side:

|                  | metrics-server                                     | kube-prometheus-stack                                                     |
|------------------|----------------------------------------------------|---------------------------------------------------------------------------|
| Purpose          | Resource metrics for HPA / `kubectl top` / widgets | Full TSDB + scrape config + alerting + Grafana                            |
| API              | `metrics.k8s.io/v1beta1` extension API             | Prometheus HTTP API + custom CRDs                                         |
| Storage          | In-memory ring buffer (~1 minute of data)          | PVC-backed Prometheus TSDB                                                |
| Footprint        | One Deployment, 100m CPU / 200Mi RAM               | Prometheus, Alertmanager, node-exporter, kube-state-metrics, Grafana, etc |
| Maintenance      | None — no dashboards, no rules                     | Dashboards, rules, recording, retention                                   |

metrics-server stays the lightweight resource-metrics floor —
`kubectl top`, HPA, the Homepage widget — with no pipeline to
maintain. It does not go away now that the
[observability stack](./observability/) has shipped: Prometheus does
not serve the `metrics.k8s.io` API that `kubectl top` and HPA read.
[Hubble UI](./hubble-ui/) covers live network-flow visibility on the
same "free, no extra pipeline" footing. The three coexist, each
answering a different question.

## Verifying after first sync

```sh
# Extension APIService registered and reachable.
kubectl get apiservice v1beta1.metrics.k8s.io
# → AVAILABLE   True

# Node-level metrics flowing.
kubectl top nodes
# → six rows, non-zero CPU/RAM

# Homepage cluster widget recovers.
curl -fsS https://dashboard.lab.jackhall.dev/api/widgets/kubernetes | jq .
# → HTTP 200, no "ensure you have metrics-server installed" string
```

`kubectl top` on a freshly-synced metrics-server can take up to a
full scrape interval (15s, per `--metric-resolution`) before it
returns a non-empty row — first call sometimes responds with
"metrics not yet available." Retry once.

## More

The repo-side README at
[`kubernetes/apps/metrics-server/README.md`](https://github.com/RaptGroup/homelab/blob/main/kubernetes/apps/metrics-server/README.md)
covers the full Talos-tuning rationale, the `kube-prometheus-stack`
comparison in more depth, and the disaster-recovery story (the addon
is stateless — re-syncing the Application is the entire procedure;
the metrics buffer rebuilds within one scrape interval).
