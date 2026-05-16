# `kubernetes/apps/alloy/`

Grafana Alloy slice of the ADR-0007 self-hosted observability stack
(#176, tracer-bullet #5). Ships `grafana/alloy` as a DaemonSet — its
own Argo Application in the shared `observability` namespace — that
tails every pod's logs on every node and writes them to Loki.

This slice is what makes the Loki slice (#176, tracer-bullet #4)
useful: before Alloy, a LogQL query in Grafana returned zero rows
because nothing shipped logs. After Alloy syncs, `{namespace="argocd"}`
returns recent lines labelled by `namespace`, `pod`, and `container`.

The OTLP receivers (gRPC 4317, HTTP 4318) also come up here. They are
**unrouted today** — they accept OpenTelemetry data and drop it. They
exist so a workload can be pointed at `alloy.observability.svc:4317`
now and keep that endpoint when ADR-0007 Phase 3 wires Tempo in.

## Shape

```
kubernetes/apps/alloy/
├── application.yaml   # multi-source ArgoCD Application (default wave)
└── helm-values.yaml   # grafana/alloy values — DaemonSet + River config
```

No `manifests/` directory: the `observability` Namespace is owned by
the `kube-prometheus-stack` Application, and Alloy is ClusterIP-only
(Grafana is the stack's only externally routed surface), so there is
no Namespace manifest and no HTTPRoute.

## What this slice delivers

- An `alloy` Argo Application syncing to `Healthy`: a DaemonSet with
  one Ready pod on every node — six on `rockingham`.
- Pod-log auto-discovery for **every namespace** with zero per-app
  action. Logs land in Loki labelled `namespace`, `pod`, `container`,
  and `job` (`namespace/container`).
- A `ServiceMonitor` so Alloy's own metrics flow back to Prometheus —
  picked up by the wide-open ServiceMonitor discovery the
  `kube-prometheus-stack` slice configured.
- OTLP receivers on the `alloy` Service: gRPC `:4317`, HTTP `:4318`,
  reachable cluster-wide at `alloy.observability.svc`. They accept
  OTLP and drop it — a Phase 3 hook, not a live pipeline.

## What this slice does NOT deliver

- **Trace ingest.** The OTLP receivers have no downstream consumer —
  the receiver's `output` lists are empty by design. ADR-0007 defers
  Tempo and the full trace pipeline to Phase 3; that slice wires
  Tempo into the existing `otelcol.receiver.otlp` block, so today's
  endpoint addresses do not change.
- **Log dashboards or alerting.** Dashboards-as-code is #176
  tracer-bullet #7; Alertmanager wiring is #6.
- **Application metrics scraping.** That is the `ServiceMonitor`
  developer contract from the `kube-prometheus-stack` slice — Alloy
  ships logs, not app metrics.

## How log collection works

Alloy runs as a **DaemonSet** (`controller.type: daemonset`) — one
pod per node. The River program in `helm-values.yaml`
(`alloy.configMap.content`) runs this pipeline on each pod:

1. `discovery.kubernetes` watches the Kubernetes API for Pods,
   **field-selected to this node** (`spec.nodeName`). Without that
   pin all six DaemonSet pods would discover all six nodes' Pods and
   ship every log line six times. The node name reaches the pod as
   the `NODE_NAME` env var, injected from `spec.nodeName` via the
   downward API.
2. `discovery.relabel` turns Kubernetes metadata into Loki labels
   (`namespace`, `pod`, `container`, `job`) and builds `__path__` —
   the on-disk glob for each container's CRI log files.
3. `local.file_match` + `loki.source.file` tail those files off the
   node's `/var/log` (bind-mounted read-only via `mounts.varlog`).
   File-based tailing tracks read positions on disk, so an Alloy
   restart resumes instead of re-shipping; it also keeps log tailing
   off the kube-apiserver.
4. `loki.process` runs `stage.cri` to unwrap the containerd CRI log
   envelope — `rockingham` is Talos, which runs containerd — so Loki
   stores the bare message and the real log timestamp.
5. `loki.write` ships to the single-binary Loki at
   `http://loki.observability.svc:3100/loki/api/v1/push`. Loki runs
   `auth_enabled: false`, so no tenant header or credentials.

## OTLP receivers (Phase 3 hook)

`otelcol.receiver.otlp` listens on gRPC `0.0.0.0:4317` and HTTP
`0.0.0.0:4318`. Those ports are published on the `alloy` Service via
`alloy.extraPorts`, so anything in the cluster can reach
`alloy.observability.svc:4317` / `:4318`.

The receiver's `output` lists (`metrics`, `logs`, `traces`) are
**empty**. OTLP sent today is accepted at the wire and dropped — there
is no consumer. This is deliberate: ADR-0007 Phase 3 adds Tempo and
wires it into the `traces` output of this same receiver. Standing the
endpoint up now means an app instrumented with the OpenTelemetry SDK
can target `alloy.observability.svc:4317` today and not change its
endpoint when tracing actually lands.

## Smoke test

Alloy is healthy and logs are queryable from Grafana.

1. **Argo sync.** `kubectl -n argocd get app alloy` reports `Synced` /
   `Healthy`.
2. **One Ready pod per node.**
   ```
   kubectl -n observability get ds alloy
   # DESIRED  CURRENT  READY  ...  6  6  6
   kubectl -n observability get pods -l app.kubernetes.io/name=alloy -o wide
   # one pod per node, all Running
   ```
3. **ServiceMonitor scraped.** In the Prometheus UI (*Status →
   Targets*, reach it with
   `kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090`),
   the `observability/alloy` target shows `up == 1`.
4. **Logs in Loki.** At `https://grafana.lab.jackhall.dev`, open
   *Explore*, pick the Loki datasource, and run `{namespace="argocd"}`.
   Recent log lines return, each labelled `namespace`, `pod`, and
   `container`. (Compare against the Loki slice's smoke test, where
   the same query returned **zero rows** — that zero-row state is what
   this slice fixes.)
5. **OTLP ports reachable.** The receivers accept and drop OTLP — a
   successful connection that ingests nothing is the expected result.
   ```
   kubectl -n observability run otlp-probe --rm -it --restart=Never \
     --image=fullstorydev/grpcurl -- \
     -plaintext alloy.observability.svc:4317 list
   # gRPC responds (reflection may be disabled — a TCP/gRPC-level
   # response, not connection-refused, is the pass signal)
   ```
   HTTP `:4318` answers likewise — `curl -s -o /dev/null -w '%{http_code}'
   http://alloy.observability.svc:4318/v1/traces` from an in-cluster
   pod returns an HTTP status (not a connection error). Data is
   dropped — no downstream consumer until Phase 3.
6. **Lint.** `scripts/lint-apps.sh kubernetes/apps/alloy` passes — the
   app is a plain chart Application with no `Gateway` or
   `LoadBalancer` Service, so the LB-pin guard does not apply.

If a node's Alloy pod is Running but its logs never reach Loki,
`kubectl -n observability logs ds/alloy` is the first place to look —
a `/var/log/pods` permission or path mismatch surfaces there, as does
a `loki.write` connection failure.

## What's NOT here

- **Tempo + the full trace pipeline** — ADR-0007 Phase 3.
- **Alertmanager Discord + Watchdog wiring** — #176, tracer-bullet #6.
- **Repo-owned dashboards** — #176, tracer-bullet #7.
- **The developer-facing observability onboarding doc** — #176,
  tracer-bullet #8.
