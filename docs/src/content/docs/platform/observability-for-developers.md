---
title: Observability for developers
description: How to make your app observable on the rockingham cluster — metrics, logs, alerts, traces, and dashboards, with copy-paste YAML.
---

You are landing an app in a `lab.*` namespace on `rockingham`. This
page is the one-page contract for making it observable: how to get
metrics, logs, alerts, traces, and dashboards, with no cluster-side
configuration and no ticket to the operator.

The stack behind this — Prometheus, Loki, Grafana, Alloy — is
described on the [Observability stack](/homelab/applications/observability/)
page and decided in
[ADR-0007](https://github.com/RaptGroup/homelab/blob/main/docs/adr/0007-observability-as-self-hosted-stack.md).
You do not need to read either to use what is below.

Everything here assumes **mutual trust**: every Grafana user sees
every namespace's metrics and logs. There is no per-tenant isolation
— the operator and every developer on this cluster are investigating
its health together.

## Metrics: the ServiceMonitor contract

Expose your metrics in Prometheus format and Prometheus will discover
them. Two steps:

1. **Expose `/metrics`** on a port of your `Service`, in Prometheus
   exposition format. Most frameworks have a one-line library for
   this.
2. **Drop a `ServiceMonitor`** next to your `Service`, in *your* own
   namespace. That is it — no namespace label, no scrape-config edit,
   no operator involvement.

Prometheus runs **wide-open discovery**: it scrapes any
`ServiceMonitor` in any namespace. A concrete example for an app
whose `Service` carries `app.kubernetes.io/name: my-app` and exposes
a port named `metrics`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: my-app
  namespace: my-app
  labels:
    app.kubernetes.io/name: my-app
spec:
  # Selects the Service(s) to scrape — must match your Service's labels.
  selector:
    matchLabels:
      app.kubernetes.io/name: my-app
  # Each entry is a port on the selected Service to scrape.
  endpoints:
    - port: metrics      # the *name* of the Service port, not the number
      path: /metrics
      interval: 30s
```

`kubectl apply -f` it. Within a scrape interval the target shows up in
Prometheus's *Status → Target health* page, and the series are
queryable in Grafana. If the target never appears, the usual cause is
the `selector` not matching your `Service`'s labels, or `port` naming
a port the `Service` does not actually declare.

Use a `PodMonitor` instead if you are scraping pods directly with no
`Service` in front — same shape, `spec.selector` matches pod labels.

## Logs: zero action

Your pod's stdout and stderr are collected automatically. There is
**nothing to configure** — no sidecar, no annotation, no opt-in.

The [Alloy](/homelab/applications/alloy/) DaemonSet tails every pod's
log files on every node and ships them to Loki, labelled by
`namespace`, `pod`, and `container`. Write structured logs to stdout
and query them in Grafana's **Explore** view with
[LogQL](https://grafana.com/docs/loki/latest/query/):

```logql
{namespace="my-app"}                       # everything from your namespace
{namespace="my-app", container="server"}   # one container
{namespace="my-app"} |= "error"            # lines containing "error"
{namespace="my-app"} | json | level="warn" # parse JSON, filter on a field
```

Logs are retained for **14 days**. The one thing worth doing on your
side: log as **JSON** to stdout, so `| json` in LogQL gives you
queryable fields instead of substring matching.

## Alerting: PrometheusRule in your namespace

Express your SLOs as code, alongside your app. A `PrometheusRule` in
*your* namespace is evaluated by Prometheus automatically — the same
wide-open discovery that picks up `ServiceMonitor`s picks up rules.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: my-app-slo
  namespace: my-app
  labels:
    app.kubernetes.io/name: my-app
spec:
  groups:
    - name: my-app.rules
      rules:
        - alert: MyAppHighErrorRate
          # 5xx rate over total request rate, above 5% for 10 minutes.
          expr: |
            sum(rate(http_requests_total{namespace="my-app",code=~"5.."}[5m]))
              /
            sum(rate(http_requests_total{namespace="my-app"}[5m]))
              > 0.05
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "my-app 5xx error rate above 5% for 10m"
            description: "Error ratio is {{ $value | humanizePercentage }}."
```

`kubectl apply -f` it; the rule appears in Prometheus's *Alerts*
page. A firing alert is delivered to Alertmanager. **How** Alertmanager
forwards it from there — to a Discord channel, a heartbeat check, or
nowhere — is operator-managed cluster config, not something you set
in your namespace. Set the `severity` label (`warning` / `critical`)
so the operator's routing can act on it.

## Tracing: OTLP endpoint (Phase 3)

Distributed tracing is **Phase 3** — there is no trace store on the
cluster yet. But the ingest endpoint is already live, so you can
instrument now and not change anything later.

[Alloy](/homelab/applications/alloy/) exposes an **OTLP receiver**,
reachable cluster-wide:

| Protocol | Endpoint |
|---|---|
| OTLP/gRPC | `alloy.observability.svc:4317` |
| OTLP/HTTP | `alloy.observability.svc:4318` |

Point your OpenTelemetry SDK exporter at one of these. **Be aware:
spans sent today are accepted and dropped** — there is no consumer
until Phase 3 lands [Tempo](https://grafana.com/oss/tempo/) as the
trace backend. The value of using the endpoint now is that it does
not move: when Tempo arrives, your traces start being stored without
a single change to your app's exporter config.

Do not deploy your own collector for traces — this endpoint is the
cluster's shared one.

## Dashboards: Scratch → code

Grafana shows two folders you can use:

- **Scratch** — writable. Throw together a dashboard for an
  investigation here. It is **ephemeral and not in Git** — treat
  anything left in Scratch as disposable.
- **Homelab** — repo-owned, **read-only** in the UI. Dashboards here
  come from `kubernetes/apps/kube-prometheus-stack/dashboards/` and
  the JSON in Git is the source of truth.

When a Scratch dashboard is worth keeping, **promote it to code**:

1. In Grafana, open the dashboard → *Settings → JSON Model*; copy the
   JSON.
2. Save it as
   `kubernetes/apps/kube-prometheus-stack/dashboards/<name>.json`. Set
   `"id": null` and give it a unique `"uid"` (e.g. `homelab-<name>`).
3. Add a `configMapGenerator` entry for it in that directory's
   `kustomization.yaml`.
4. Open a PR. On merge, Argo provisions it into the read-only
   **Homelab** folder — then delete the Scratch copy.

A dashboard only becomes durable by landing in `dashboards/` via PR.

## Where to look

One Grafana — `https://grafana.lab.jackhall.dev` — is the front door
for everything above:

- **Dashboards** — your `ServiceMonitor` metrics, plus the bundled
  node and cluster-health boards.
- **Explore → Prometheus** — ad-hoc PromQL against your metrics.
- **Explore → Loki** — LogQL against your logs.
- **Alerts** — the state of your `PrometheusRule`s.

You reach it on the LAN once your device uses AdGuard Home for DNS
([Split-horizon DNS](/homelab/networking/split-horizon-dns/)).
Anonymous access is read-only Viewer — enough to browse dashboards
and run Explore queries; editing needs the admin login.
