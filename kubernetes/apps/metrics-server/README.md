# `kubernetes/apps/metrics-server/`

[metrics-server](https://github.com/kubernetes-sigs/metrics-server) —
the Kubernetes Metrics API extension server. Backs `kubectl top
nodes` / `kubectl top pods` and the Homepage cluster widget's CPU/RAM
bars. Scrapes kubelet's `/metrics/resource` endpoint and exposes the
result as `metrics.k8s.io/v1beta1`.

## Why this is separate from kube-prometheus-stack

PRD #4 explicitly defers `kube-prometheus-stack` to a future
learning-deep-dive pass — but the two solve different problems and
`metrics-server` is the strictly smaller one:

|                       | metrics-server                                     | kube-prometheus-stack                                                     |
|-----------------------|----------------------------------------------------|---------------------------------------------------------------------------|
| Purpose               | Resource metrics for HPA / `kubectl top` / widgets | Full TSDB + scrape config + alerting + Grafana                            |
| API                   | `metrics.k8s.io/v1beta1` extension API             | Prometheus HTTP API + custom CRDs                                         |
| Storage               | In-memory ring buffer (~1m of data)                | PVC-backed Prometheus TSDB                                                |
| Footprint             | One Deployment, 100m / 200Mi                       | Prometheus, Alertmanager, node-exporter, kube-state-metrics, Grafana, etc |
| Maintenance           | None — no dashboards, no rules                     | Dashboards, rules, recording, retention                                   |

Shipping `metrics-server` does not commit us to `kube-prometheus-stack`
and doesn't shortcut the deep-dive pass. The PRD's silence on it was
an oversight (see issue #50).

## Shape

```
kubernetes/apps/metrics-server/
├── application.yaml     # multi-source ArgoCD Application
└── helm-values.yaml     # metrics-server chart values, tuned for Talos
```

No `manifests/` — metrics-server has no UI, no LAN exposure, and no
secrets to sync. Talos-specific args (`--kubelet-insecure-tls`,
`--kubelet-preferred-address-types=InternalIP,Hostname`) are documented
in `helm-values.yaml`.

## Verifying after first sync

```sh
# Extension APIService registered and reachable.
kubectl get apiservice v1beta1.metrics.k8s.io
# → NAME                     SERVICE                          AVAILABLE   AGE
# → v1beta1.metrics.k8s.io   metrics-server/metrics-server    True        …

# Node-level metrics flowing.
kubectl top nodes
# → six rows, non-zero CPU/RAM

# Pod-level metrics flowing.
kubectl top pods -A | head

# Homepage cluster widget recovers.
curl -fsS https://dashboard.lab.jackhall.dev/api/widgets/kubernetes | jq .
# → HTTP 200, no "ensure you have metrics-server installed" string
kubectl -n homepage logs deploy/homepage | grep -i metrics-server
# → no matches
```

`kubectl top` on a freshly-synced metrics-server can take up to a full
scrape interval (15s, per `--metric-resolution`) before it returns a
non-empty row — first call sometimes responds with "metrics not yet
available." Retry once.

## Disaster recovery

Stateless. Re-syncing the Application is the entire DR procedure; the
metrics buffer rebuilds within one scrape interval.
