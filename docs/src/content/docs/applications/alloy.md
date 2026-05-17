---
title: Alloy
description: The per-node log collector — a DaemonSet that tails every pod's stdout and ships it to Loki, plus the Phase 3 OTLP endpoint.
---

[Grafana Alloy](https://grafana.com/docs/alloy/latest/) is the lab's
log collector: a DaemonSet that tails every pod's stdout/stderr on
every node and writes it to [Loki](./loki/). It is the collection
half of the logs pipeline in the self-hosted observability stack
([ADR-0007](https://github.com/RaptGroup/homelab/blob/main/docs/adr/0007-observability-as-self-hosted-stack.md)),
one of the three Argo Applications — alongside
[kube-prometheus-stack](./kube-prometheus-stack/) and [Loki](./loki/)
— that make up the [Observability stack](./observability/).

Alloy is what makes Loki useful: Loki stores logs, Alloy is the agent
that gets them there. It also stands up the cluster's **OTLP receiver**
— a documented endpoint for OpenTelemetry data that goes live as a
trace pipeline in Phase 3.

## Where it runs

A single multi-source ArgoCD `Application` in the shared
`observability` namespace: the `grafana/alloy` chart (pinned at
`1.8.1`) plus this repo's `helm-values.yaml`.

```
kubernetes/apps/alloy/
├── application.yaml   # multi-source ArgoCD Application
└── helm-values.yaml   # grafana/alloy chart values — DaemonSet + River config
```

Source lives at
[`kubernetes/apps/alloy/`](https://github.com/RaptGroup/homelab/tree/main/kubernetes/apps/alloy).
Like [Loki](./loki/) it has no `manifests/` directory — the
`observability` namespace is owned by
[kube-prometheus-stack](./kube-prometheus-stack/), and Alloy is
ClusterIP-only.

## Log auto-collection

Alloy runs as a **DaemonSet** — one pod per node, six on `rockingham`,
including the control-plane nodes (the collector tolerates every
`NoSchedule` taint, because control-plane logs are exactly what you
reach for when the cluster misbehaves). Each pod runs a River pipeline:

1. **Discover** — watch the Kubernetes API for Pods, field-selected
   to *this* node, so the six pods partition the cluster's logs
   instead of all six shipping every line.
2. **Relabel** — turn Kubernetes metadata into Loki labels
   (`namespace`, `pod`, `container`, `job`) and build the on-disk log
   path.
3. **Tail** — read the container log files off the node's `/var/log`,
   tracking read positions on disk so an Alloy restart resumes
   instead of re-shipping.
4. **Unwrap** — strip the containerd CRI log envelope so Loki stores
   the bare message and the real timestamp.
5. **Ship** — write to Loki at
   `http://loki.observability.svc:3100/loki/api/v1/push`.

This is **zero-action** for application developers: drop logs to
stdout and they appear in Grafana, labelled by namespace, pod, and
container. See
[Observability for developers](/homelab/platform/observability-for-developers/#logs-zero-action).

## OTLP receivers — the Phase 3 hook

Alloy also exposes **OTLP receivers** on the `alloy` Service: gRPC on
`:4317` and HTTP on `:4318`, reachable cluster-wide at
`alloy.observability.svc`. They are **live but unrouted** — they
accept OpenTelemetry data today and drop it, because there is no
trace store yet.

This is deliberate. ADR-0007 defers Tempo and distributed tracing to
**Phase 3**. Standing the endpoint up now means an app instrumented
with the OpenTelemetry SDK can target `alloy.observability.svc:4317`
today and keep that exact endpoint when Tempo lands — Phase 3 is a
Tempo install and a config change, not a re-instrumentation of every
app. The developer-facing endpoint contract is on the
[developer page](/homelab/platform/observability-for-developers/#tracing-otlp-endpoint-phase-3).

## More

The repo-side README at
[`kubernetes/apps/alloy/README.md`](https://github.com/RaptGroup/homelab/blob/main/kubernetes/apps/alloy/README.md)
covers the River pipeline line by line, the per-node discovery field
selector, the OTLP drop-sink and its Phase 3 swap, and the full
smoke-test sequence.
