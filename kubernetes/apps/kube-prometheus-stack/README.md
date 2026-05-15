# `kubernetes/apps/kube-prometheus-stack/`

First slice of the ADR-0007 self-hosted observability stack. Ships
Prometheus, Grafana, Alertmanager, node-exporter, kube-state-metrics,
and the chart-bundled dashboard library as a single Argo Application
under a shared `observability` namespace. Loki and Alloy land as
sibling Applications in later slices (#176, tracer-bullet #4 and #5).

## Shape

```
kubernetes/apps/kube-prometheus-stack/
├── application.yaml       # multi-source ArgoCD Application (default wave)
├── helm-values.yaml       # prometheus-community/kube-prometheus-stack values
└── manifests/
    ├── namespace.yaml                          # observability Namespace (PSA: restricted)
    ├── grafana-httproute.yaml                  # grafana.lab.jackhall.dev → Grafana Service
    └── external-secret-grafana-admin.yaml      # GSM → K8s Secret with admin user/pass
```

## What this slice delivers

- A single Argo Application syncing to `Healthy` (Prometheus,
  Alertmanager, Grafana, node-exporter on every node, kube-state-metrics,
  and the Prometheus Operator running the stack).
- Grafana reachable at `https://grafana.lab.jackhall.dev` on the LAN
  (via AdGuard's `*.lab.jackhall.dev → 192.168.1.201` wildcard rewrite,
  ADR-0003) with the existing wildcard cert.
- Anonymous LAN visitors land on the Grafana login page as Viewer and
  can browse the chart-bundled dashboard library; editing is gated
  behind the admin login.
- Wide-open `ServiceMonitor` / `PodMonitor` / `PrometheusRule` / `Probe`
  discovery across every namespace — the ADR-0007 developer contract.

## What this slice does NOT deliver

- **Loki + the Loki datasource.** Provisioned in the Loki slice
  (#176, tracer-bullet #4). The Prometheus datasource is provisioned
  here; Loki is intentionally deferred.
- **Pod log auto-collection.** Alloy slice (#176, tracer-bullet #5).
- **Cilium + Hubble metric scraping.** Cilium values bump
  (#176, tracer-bullet #3) is a `terraform/bootstrap/` change, not an
  Argo change.
- **Alertmanager Discord receiver + Watchdog → healthchecks.io.**
  Alerting slice (#176, tracer-bullet #6). This slice keeps
  Alertmanager up but routes nothing externally.
- **Repo-owned dashboard JSON files.** Dashboards-as-code slice
  (#176, tracer-bullet #7). The sidecar is wired (label
  `grafana_dashboard`), so dashboards land as ConfigMaps in a later
  slice without revisiting this one.
- **`prometheus.lab.jackhall.dev` or `alertmanager.lab.jackhall.dev`
  HTTPRoutes.** Per ADR-0007 (Q15), Grafana is the only externally-routed
  surface. The raw Prometheus and Alertmanager UIs are reachable by
  `kubectl port-forward` when needed.

## The nil-uses-helm-values trap

The Prometheus Operator's default is "if `serviceMonitorSelector` is
nil, scope to the chart's release labels." A user writing
`serviceMonitorSelector: {}` to mean "select everything" instead gets
"scope to release labels only", because the chart's
`serviceMonitorSelectorNilUsesHelmValues: true` rewrites an empty
selector to a chart-scoped one at template time. This is the
"only-chart-labelled-ServiceMonitors-are-discovered" footgun.

The fix is two-part and **both halves must stay set on every chart
bump**:

1. `serviceMonitorSelectorNilUsesHelmValues: false` (same for
   `podMonitor`, `rule`, `probe`).
2. Each of the four `*Selector` keys explicitly set to `{}`.

The two `*NamespaceSelector` keys (`serviceMonitorNamespaceSelector`,
`podMonitorNamespaceSelector`) also set to `{}` so the operator scans
every namespace. `helm-values.yaml` carries a top-of-file comment
naming the trap so a future chart-version bump can't silently regress
it. The ADR-0007 developer contract ("drop a `ServiceMonitor` next to
your Service, no namespace labelling, it just works") fails if any of
these six knobs reverts.

## Stateful PVCs

All three PVCs in this slice ride on `storageClassName: longhorn` —
ADR-0005's heuristic for singleton, valuable, must-survive-node-drain
storage applies cleanly to each:

| Component     | Size  | StorageClass | Why Longhorn                                                |
|---------------|-------|--------------|-------------------------------------------------------------|
| Prometheus    | 100 GB| `longhorn`   | 30-day TSDB; losing it on a worker reboot is the failure ADR-0005 prevents |
| Alertmanager  | 10 GB | `longhorn`   | Notification dedup + silences state, small but valuable     |
| Grafana SQLite| 10 GB | `longhorn`   | Operator drafts + Scratch-folder dashboards; cheap insurance |

PVC sizing comes from ADR-0007's retention windows (30 days metrics).
Resize path is the standard Longhorn `kubectl patch pvc … storage:
…Gi` flow — the chart issues fresh PVCs at the size in
`helm-values.yaml`, so a permanent bump means editing this slice and
letting Longhorn's volume expansion do the runtime growth.

## Grafana admin credential

The chart's `grafana.admin.existingSecret: grafana-admin` points at
the K8s Secret in this namespace. ESO syncs that Secret from the
`grafana-admin-password` GSM container declared in `terraform/gcp/`:

```
GSM `grafana-admin-password` (JSON {admin-user, admin-password})
   │
   ▼   ExternalSecret in this namespace (manifests/external-secret-grafana-admin.yaml)
K8s Secret `observability/grafana-admin`
   keys: admin-user, admin-password
   │
   ▼   grafana.admin.{userKey,passwordKey} in helm-values.yaml
Grafana env / pod boot
```

The plaintext password is uploaded by the operator after a
`tofu apply` of `terraform/gcp/` — same pattern as `adguard-home-admin`
and friends, so the plaintext never enters Terraform state or Git:

```
echo -n '{"admin-user":"admin","admin-password":"<password>"}' \
  | gcloud secrets versions add grafana-admin-password \
      --project rockingham-homelab --data-file=-
```

Until that upload happens, the ESO `grafana-admin` ExternalSecret
reports `SecretSyncedError` and the Grafana pod fails to find the
credential — Argo will report the app as `Degraded` rather than
silently masking the missing secret.

Rotation: re-upload a new version with the same command; ESO's next
refresh (1h) propagates it. Grafana picks the new credential up on
its next pod restart — kick with `kubectl -n observability rollout
restart deploy kube-prometheus-stack-grafana` to apply immediately.

## Smoke test

The acceptance criterion for this slice is "anyone on the LAN can hit
`https://grafana.lab.jackhall.dev`, land on the Grafana login page as
an anonymous viewer, browse the chart-bundled dashboards, and sign in
as admin to edit." The procedure:

1. **DNS resolves on LAN.** From a LAN device pointing manual DNS at
   AdGuard, `dig grafana.lab.jackhall.dev` returns `192.168.1.201`
   (the LB-pinned lab Gateway VIP via the
   `*.lab.jackhall.dev → 192.168.1.201` wildcard rewrite, ADR-0003).
2. **TLS works.** `curl -v https://grafana.lab.jackhall.dev/login`
   completes a handshake with the LE wildcard cert
   (`wildcard-lab-jackhall-dev-tls`), no `-k` needed.
3. **Anonymous view.** Open the URL in a browser without logging in;
   the Grafana home dashboard renders. Navigate to *Dashboards →
   Browse* and confirm the chart-bundled dashboards (Cluster overview,
   Node Exporter / Nodes, Pods, etc.) are visible and populated.
4. **Anonymous editing blocked.** Attempt *New dashboard*; Grafana
   redirects to the login page. (Anonymous role is `Viewer`.)
5. **Admin login.** After the operator has uploaded the credential to
   the `grafana-admin-password` GSM container and ESO has synced it,
   sign in with the admin user/password; the *New dashboard* button
   becomes available.
6. **Prometheus and Alertmanager health.** Both are ClusterIP-only;
   verify with port-forward:
   ```
   kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
   curl -sf http://localhost:9090/-/healthy   # 200 OK
   kubectl -n observability port-forward svc/kube-prometheus-stack-alertmanager 9093:9093 &
   curl -sf http://localhost:9093/-/healthy   # 200 OK
   ```
7. **Wide-open ServiceMonitor discovery.** Confirm Prometheus is
   scraping at least one `ServiceMonitor` outside the `observability`
   namespace — the chart bundles a `kube-prometheus-stack-operator`
   ServiceMonitor in `observability`; the developer-contract check is
   that adding a `ServiceMonitor` to, say, `default` lands in the
   Prometheus targets page without restart or relabel:
   ```
   kubectl apply -f - <<'EOF'
   apiVersion: monitoring.coreos.com/v1
   kind: ServiceMonitor
   metadata: {name: smoke-svc, namespace: default}
   spec:
     selector: {matchLabels: {nonexistent: "true"}}
     endpoints: [{port: http}]
   EOF
   ```
   In the Prometheus UI's *Status → Service Discovery* view,
   `default/smoke-svc` should appear (zero targets — that's expected,
   the selector matches nothing — and a non-empty
   "discovered targets" entry confirms cross-namespace scanning).
   `kubectl delete servicemonitor smoke-svc -n default` to clean up.
8. **PVCs bound.** All three on `longhorn`:
   ```
   kubectl -n observability get pvc
   # prometheus-…             Bound   …   100Gi   longhorn
   # alertmanager-…           Bound   …    10Gi   longhorn
   # storage-kube-prometheus-stack-grafana-0   Bound   …    10Gi   longhorn
   ```

If any step fails, `kubectl -n observability get pods` + the
`kube-prometheus-stack-operator` pod's logs are the first places to
look; admission-webhook drift on HTTPRoute or ExternalSecret defaults
is the second (the values here spell every API-server default out;
the lint script catches the LB-pin variant, not these).

## What's NOT here

- **The full ADR-0007 stack.** Loki, Alloy, the Cilium values bump,
  the Discord + healthchecks.io receivers, repo-owned dashboards, and
  the developer-facing onboarding doc all ship as their own slices —
  see the issue list under #176.
- **Custom dashboards.** The sidecar is wired (label
  `grafana_dashboard`, search namespace `ALL`); dashboards land in
  `kubernetes/apps/kube-prometheus-stack/dashboards/` as
  ConfigMap-wrapped JSON in a later slice without touching this one.
