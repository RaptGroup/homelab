# `kubernetes/apps/loki/`

Loki slice of the ADR-0007 self-hosted observability stack (#176,
tracer-bullet #4). Ships `grafana/loki` in single-binary mode as its
own Argo Application in the shared `observability` namespace, and adds
Loki to Grafana as a queryable datasource.

This slice is verifiable on its own: Loki syncs Healthy, its `/ready`
endpoint returns 200, and Grafana's Explore view lists Loki and
accepts a LogQL query. **Queries return zero rows** — nothing ships
logs to Loki until the Alloy slice (#176, tracer-bullet #5) lands.
That zero-row state is the expected steady state for this slice, not
a fault.

## Shape

```
kubernetes/apps/loki/
├── application.yaml   # multi-source ArgoCD Application (default wave)
└── helm-values.yaml   # grafana/loki values — single-binary mode
```

No `manifests/` directory: the `observability` Namespace is owned by
the `kube-prometheus-stack` Application, and Loki is ClusterIP-only
(Grafana is the stack's only externally routed surface), so there is
no Namespace manifest and no HTTPRoute.

## What this slice delivers

- A `loki` Argo Application syncing to `Healthy`: one single-binary
  StatefulSet pod running every Loki module, backed by one Longhorn
  PVC.
- A 100 GB PVC on `storageClassName: longhorn` holding chunks and the
  tsdb index.
- 14-day log retention (ADR-0007), enforced by the compactor.
- A `ServiceMonitor` so Loki's own metrics flow back to Prometheus —
  picked up by the wide-open ServiceMonitor discovery the
  `kube-prometheus-stack` slice configured.
- Loki provisioned as a Grafana datasource at
  `http://loki.observability.svc:3100` (wired from
  `kubernetes/apps/kube-prometheus-stack/helm-values.yaml` via
  `grafana.additionalDataSources`, since Grafana lives in that chart).

## What this slice does NOT deliver

- **Log shipping.** No logs reach Loki until Grafana Alloy ships as
  its own Application (#176, tracer-bullet #5). LogQL queries return
  zero rows until then.
- **Remote-write of chunks to GCS.** ADR-0007's "Out of Scope" — Loki
  keeps chunks and index on the local filesystem (one Longhorn PVC).
  Moving chunks to GCS via the tsdb shipper is a future change to
  `loki.storage` in `helm-values.yaml`, not a re-architecture.
- **Loki recording rules / bundled dashboards.** `monitoring.rules`
  and `monitoring.dashboards` are off; alerting is #176 tracer-bullet
  #6 and dashboards-as-code is #7.

## Deployment shape

Single-binary mode (`deploymentMode: SingleBinary`): one Loki process
running `targetModule: all`, the chart-recommended shape for installs
under ~1 TB/day. The chart default is `SimpleScalable` (separate
read/write/backend tiers); `helm-values.yaml` zeroes those tiers to
nil replicas so the chart does not stand up three empty Deployments
alongside the single binary.

`auth_enabled` is set to `false` — single-tenant homelab, no
`X-Scope-OrgID` tenancy. Left at the chart default (`true`), every
read and write would need a tenant header and Grafana's Explore
queries would fail with "no org id".

The nginx `gateway`, the memcached `chunksCache`/`resultsCache`, the
`lokiCanary`, and the helm-`test` pod are all disabled — they exist
to serve multi-tier Loki and are dead weight for a single binary.

## Stateful PVC

| Component | Size  | StorageClass | Why Longhorn                                              |
|-----------|-------|--------------|-----------------------------------------------------------|
| Loki      | 100 GB| `longhorn`   | 14-day chunk + index store; losing it on a worker reboot is exactly the failure ADR-0005 prevents |

`singleBinary.persistence.enableStatefulSetAutoDeletePVC` is forced
to `false`: an Argo prune of the StatefulSet must not take 14 days of
logs with it. The PVC outlives the workload and is reclaimed by hand.

Resize path is the standard Longhorn flow — edit `size:` under
`singleBinary.persistence` in `helm-values.yaml`, let Argo apply, and
Longhorn's volume expansion grows the disk at runtime.

## Retention

ADR-0007 sets log retention to 14 days. Three knobs in
`helm-values.yaml` enforce it together:

- `loki.limits_config.retention_period: 336h` — the 14-day horizon.
- `loki.compactor.retention_enabled: true` — the compactor is what
  actually deletes; without this the horizon is advisory only.
- `loki.compactor.retention_delete_delay: 2h` — grace window before a
  chunk past the horizon is physically removed.
- `loki.compactor.delete_request_store: filesystem` — where the
  compactor tracks deletion requests (same PVC as the chunks).

## Smoke test

Loki is healthy and queryable from Grafana. Queries return zero rows —
expected until Alloy ships.

1. **Argo sync.** `kubectl -n argocd get app loki` reports `Synced` /
   `Healthy`.
2. **PVC bound at 100 GB on longhorn.**
   ```
   kubectl -n observability get pvc -l app.kubernetes.io/name=loki
   # storage-loki-0   Bound   …   100Gi   longhorn
   ```
3. **`/ready` returns 200.** Loki is ClusterIP-only; port-forward:
   ```
   kubectl -n observability port-forward svc/loki 3100:3100 &
   curl -sf http://localhost:3100/ready   # "ready\n", HTTP 200
   ```
   (Immediately after a pod start `/ready` 503s for ~15s while the
   ingester warms up — re-check.)
4. **ServiceMonitor scraped.** In the Prometheus UI (*Status →
   Targets*, reach it with
   `kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090`),
   the `observability/loki` target shows `up == 1`.
5. **Grafana lists Loki.** At `https://grafana.lab.jackhall.dev`,
   *Connections → Data sources* shows **Loki** alongside Prometheus.
6. **LogQL accepted.** In *Explore*, pick the Loki datasource and run
   `{namespace="argocd"}`. The query is accepted and returns **zero
   rows** — correct, since no Alloy slice is shipping logs yet. A
   query error (not an empty result) is the failure signal here.

If Loki will not become Healthy, `kubectl -n observability logs
sts/loki` is the first place to look — a schema or storage
misconfiguration surfaces there at boot.

## What's NOT here

- **Alloy + log auto-collection** — #176, tracer-bullet #5.
- **Alertmanager Discord + Watchdog wiring** — #176, tracer-bullet #6.
- **Repo-owned dashboards** — #176, tracer-bullet #7.
- **The developer-facing observability onboarding doc** — #176,
  tracer-bullet #8.
