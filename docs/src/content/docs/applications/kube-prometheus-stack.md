---
title: kube-prometheus-stack
description: Prometheus, Grafana, Alertmanager, node-exporter, and kube-state-metrics — the metrics-and-alerts half of the self-hosted observability stack.
---

[kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
is the metrics-and-alerts half of the lab's self-hosted observability
stack ([ADR-0007](https://github.com/RaptGroup/homelab/blob/main/docs/adr/0007-observability-as-self-hosted-stack.md)).
A single Helm chart ships Prometheus, Grafana, Alertmanager,
node-exporter, kube-state-metrics, the Prometheus Operator that runs
them, and a bundled Grafana dashboard library. It is one of the three
Argo Applications — alongside [Loki](./loki/) and [Alloy](./alloy/) —
that make up the [Observability stack](./observability/).

## Where it runs

A single multi-source ArgoCD `Application` in the shared
`observability` namespace. The chart
(`prometheus-community/kube-prometheus-stack`, pinned at `85.0.3`) is
source one; the other three sources are this repo —
`helm-values.yaml`, the `manifests/` directory (the `observability`
`Namespace`, the Grafana `HTTPRoute`, and the admin-password
`ExternalSecret`), and the `dashboards/` directory of repo-owned
dashboard JSON.

```
kubernetes/apps/kube-prometheus-stack/
├── application.yaml     # multi-source ArgoCD Application
├── helm-values.yaml     # kube-prometheus-stack chart values
├── manifests/           # observability Namespace, Grafana HTTPRoute, ESO
└── dashboards/          # repo-owned Grafana dashboard JSON (Kustomize-wrapped)
```

Source lives at
[`kubernetes/apps/kube-prometheus-stack/`](https://github.com/RaptGroup/homelab/tree/main/kubernetes/apps/kube-prometheus-stack).
The `observability` `Namespace` is declared here, in the first stack
slice to land, so [Loki](./loki/) and [Alloy](./alloy/) attach to it
without owning a duplicate manifest.

## What it bundles

| Component | Role |
|---|---|
| Prometheus | Time-series database; scrapes targets, evaluates alert rules, 30-day retention |
| Grafana | The query and dashboard front end — the stack's one externally-routed surface |
| Alertmanager | Deduplicates, groups, and routes firing alerts to receivers |
| node-exporter | DaemonSet on every node — host CPU, memory, disk, network metrics |
| kube-state-metrics | Kubernetes object state (Deployments, Pods, PVCs, …) as metrics |
| Prometheus Operator | Runs the stack; turns `ServiceMonitor` / `PrometheusRule` CRs into scrape and rule config |

## Grafana — the one routed surface

Grafana is reached at
[`https://grafana.lab.jackhall.dev`](https://grafana.lab.jackhall.dev/)
via an `HTTPRoute` attached cross-namespace to the central
[`lab` Gateway](./lab-gateway/). TLS and the `*.lab.jackhall.dev`
wildcard cert are the Gateway's job.

Auth follows [ADR-0007](https://github.com/RaptGroup/homelab/blob/main/docs/adr/0007-observability-as-self-hosted-stack.md):
**anonymous LAN visitors are Viewers** — they land on a dashboard
without logging in — and **editing requires the admin login**.
Creating or modifying dashboards, alerts, or datasources all gate
behind admin. The admin password is sourced via ESO from the
`grafana-admin-password` Google Secret Manager container into the
`observability/grafana-admin` `Secret`, the same GSM → ESO pattern
every other credential in this repo uses.

Prometheus and Alertmanager have **no** routed surface — they are
ClusterIP-only. Their raw UIs are reached with `kubectl port-forward`
when needed; Grafana is the intended front door for both.

## The ServiceMonitor discovery contract

Prometheus is configured for **wide-open discovery**: it scrapes any
`ServiceMonitor`, `PodMonitor`, or `Probe`, and evaluates any
`PrometheusRule`, in *every* namespace, with no namespace labelling
or cluster-side config. This is the developer contract from ADR-0007
— see [Observability for developers](/homelab/platform/observability-for-developers/)
for how an app plugs into it.

Making that work means defeating the chart's
**`serviceMonitorSelectorNilUsesHelmValues`** footgun: by default an
empty selector is silently rewritten to "only ServiceMonitors with
this chart's release labels." `helm-values.yaml` flips all four
`*NilUsesHelmValues` knobs to `false` and sets every `*Selector` /
`*NamespaceSelector` to `{}`, with a top-of-file comment naming the
trap so a future chart bump cannot quietly regress it.

## Dashboards as code

`dashboards/` holds repo-owned Grafana dashboard JSON. A
`kustomization.yaml` wraps each file into a ConfigMap labelled
`grafana_dashboard`, which the Grafana sidecar provisions on boot.
Three dashboards ship today: a vendored Cilium/Hubble dashboard, a
6-node overview, and a cluster-and-addon health board.

Grafana shows two folders for these:

- **Homelab** — the repo-owned `dashboards/`, provisioned
  **read-only**. The JSON in Git is the source of truth.
- **Scratch** — an operator-created, **writable** folder for
  in-flight investigations, deliberately **not** in Git.

The promote-a-Scratch-dashboard-to-code workflow is covered on the
[developer page](/homelab/platform/observability-for-developers/#dashboards-scratch--code)
and in full in the repo README.

## Stateful PVCs

Three PVCs, all on `storageClassName: longhorn` per
[ADR-0005](https://github.com/RaptGroup/homelab/blob/main/docs/adr/0005-longhorn-as-named-non-default-storageclass.md)
— singleton, valuable, must survive a node drain:

| Component | Size | Why |
|---|---|---|
| Prometheus | 100 GB | 30-day TSDB; losing it on a worker reboot is the failure Longhorn prevents |
| Alertmanager | 10 GB | Notification dedup state and silences |
| Grafana | 10 GB | SQLite DB — operator drafts and Scratch-folder dashboards |

## Accessing it

Once the device is using AdGuard Home for resolution
([Split-horizon DNS](/homelab/networking/split-horizon-dns/)):

```sh
dig +short grafana.lab.jackhall.dev    # → 192.168.1.201 (the lab Gateway)
```

Open [`https://grafana.lab.jackhall.dev`](https://grafana.lab.jackhall.dev/).
A dashboard renders without a login (anonymous Viewer). Sign in with
the admin credential to edit. Prometheus and Alertmanager, being
ClusterIP-only, are reached by port-forward:

```sh
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090
kubectl -n observability port-forward svc/kube-prometheus-stack-alertmanager 9093:9093
```

## More

The repo-side README at
[`kubernetes/apps/kube-prometheus-stack/README.md`](https://github.com/RaptGroup/homelab/blob/main/kubernetes/apps/kube-prometheus-stack/README.md)
covers the nil-uses-helm-values trap in depth, the dashboards-as-code
and Homelab/Scratch folder mechanics, the admin-credential GSM upload
and rotation procedure, and the full smoke-test sequence.
