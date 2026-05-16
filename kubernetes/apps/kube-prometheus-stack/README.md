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
├── manifests/
│   ├── namespace.yaml                          # observability Namespace (PSA: restricted)
│   ├── grafana-httproute.yaml                  # grafana.lab.jackhall.dev → Grafana Service
│   └── external-secret-grafana-admin.yaml      # GSM → K8s Secret with admin user/pass
└── dashboards/
    ├── kustomization.yaml                      # configMapGenerator → grafana_dashboard ConfigMaps
    ├── cilium.json                             # Cilium/Hubble dashboard (vendored)
    ├── nodes.json                              # 6-node CPU/mem/disk/network overview
    └── addon-health.json                       # cluster + addon health at a glance
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
- **Alertmanager Discord receiver + Watchdog → healthchecks.io.**
  Alerting slice (#176, tracer-bullet #6). This slice keeps
  Alertmanager up but routes nothing externally.
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

## Dashboards-as-code

`dashboards/` holds repo-owned Grafana dashboard JSON. Its
`kustomization.yaml` runs a `configMapGenerator` that wraps every
`*.json` file into one ConfigMap labelled `grafana_dashboard: "1"` —
the label the Grafana sidecar (`grafana.sidecar.dashboards` in
`helm-values.yaml`) selects on to provision dashboards on boot. The
directory is wired as a fourth ArgoCD source on `application.yaml`.
`disableNameSuffixHash: true` keeps each ConfigMap's name stable, so
editing a dashboard's JSON updates the existing ConfigMap in place and
the sidecar reloads it — no orphaned hash-suffixed copy.

Three dashboards ship today:

| File                | Source                 | Notes                                                            |
|---------------------|------------------------|------------------------------------------------------------------|
| `cilium.json`       | Vendored (#179)        | "Hubble Metrics and Monitoring" — needs the #179 Hubble scrape    |
| `nodes.json`        | Repo-authored (#182)   | CPU/mem/disk/network across all 6 nodes; story 2                  |
| `addon-health.json` | Repo-authored (#182)   | Cluster + addon health at a glance; story 1                       |

`nodes.json` and `addon-health.json` are hand-authored against the
metrics kube-prometheus-stack ships out of the box (node-exporter,
kube-state-metrics) and have data from first sync. `addon-health.json`
also carries an "Addon exporters" row (ArgoCD, cert-manager, ESO,
Longhorn) that reads "No data" until each addon ships its own
`ServiceMonitor` — wide-open discovery scrapes it the moment it does.

`cilium.json` is vendored: copied from the `cilium/cilium` **v1.16.5**
tag (`install/kubernetes/cilium/files/hubble/dashboards/hubble-dashboard.json`)
so it matches the deployed Cilium chart (`var.cilium_chart_version`)
rather than the stale grafana.com publication (ID `16613`). Two edits
adapt a vendored dashboard for sidecar (file-based) provisioning: the
`__inputs` import-wizard block is removed so its `${DS_PROMETHEUS}`
datasource resolves against the provisioned Prometheus datasource, and
the top-level `id` is nulled so Grafana assigns one. **It needs Hubble
metrics scraping to populate** — its `hubble_*` / `cilium_*` panels
read "No data" until the `terraform/bootstrap/cilium.tf` scrape values
(#179, ADR-0002/0007) are applied. Each dashboard's provenance is
recorded as an annotation (`homelab.jackhall.dev/dashboard-source`) on
its generated ConfigMap, set per-entry in `dashboards/kustomization.yaml`.

### Folder convention: "Homelab" vs "Scratch"

Grafana shows two folders for this stack's non-bundled dashboards:

- **Homelab** — repo-owned, the dashboards under `dashboards/`. The
  provisioning provider runs with `allowUiUpdates: false`, so these are
  **read-only in the UI**: the JSON in Git is the source of truth.
- **Scratch** — operator-created in the Grafana UI, **writable**, and
  intentionally **not in Git**. It is where in-flight investigations
  live before they are promoted to code or abandoned.

The folder split is driven by the sidecar's `folderAnnotation`
mechanism, not by dashboard `tags`. `helm-values.yaml` sets
`sidecar.dashboards.folderAnnotation: grafana_folder` and
`provider.foldersFromFilesStructure: true`; `dashboards/kustomization.yaml`
stamps every generated ConfigMap with `grafana_folder: Homelab`. The
sidecar files those dashboards into a `Homelab/` subdirectory and
Grafana turns the subdirectory into a real folder. `tags` was the
alternative — it was rejected because tags label a dashboard but do
not place it in a folder, so they cannot give Scratch its own
read/write boundary. Chart-bundled dashboards carry no `grafana_folder`
annotation and stay in Grafana's "General" folder.

The "Scratch" folder is not provisioned — the dashboard sidecar
provisions dashboards, not empty folders. Create it once, by hand:
*Dashboards → New → New folder → name it `Scratch`*. Anyone with an
editor/admin login can then save throwaway dashboards into it.

### Promoting a Scratch dashboard to code

When a Scratch dashboard is worth keeping:

1. In Grafana, open it → *Dashboard settings → JSON Model*; copy the JSON.
2. Save it as `dashboards/<name>.json`; set `"id": null` and a unique
   `"uid"` (e.g. `homelab-<name>`) so Grafana does not collide it.
3. Add a `configMapGenerator` entry in `dashboards/kustomization.yaml`
   with a `homelab.jackhall.dev/dashboard-source` provenance annotation.
4. Open a PR. On merge Argo provisions it into the read-only **Homelab**
   folder — delete the Scratch copy.

Scratch is ephemeral — treat anything left there as disposable. A
dashboard only becomes durable by landing in `dashboards/` via PR.

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
9. **Repo-owned dashboards provisioned into the Homelab folder.** The
   sidecar wraps each `dashboards/*.json` into a `grafana-dashboard-*`
   ConfigMap; Grafana's *Dashboards* list shows a **Homelab** folder
   holding "Rockingham Nodes", "Addon Health Overview", and "Hubble
   Metrics and Monitoring". `nodes.json` and `addon-health.json` (its
   "Cluster & workload health" row) render populated panels on first
   sync. The Cilium dashboard's `hubble_*` / `cilium_*` panels stay
   "No data" until the `terraform/bootstrap/cilium.tf` Hubble-scrape
   values (#179) are applied; the `addon-health.json` "Addon exporters"
   row likewise fills in per addon as ServiceMonitors land.
10. **Edit-and-resync updates the dashboard.** Change a panel title in
   `dashboards/nodes.json`, commit, and let Argo sync; the
   `grafana-dashboard-nodes` ConfigMap updates in place (stable name,
   no hash suffix) and the sidecar reloads the dashboard within
   `updateIntervalSeconds` — verifying the ConfigMap → sidecar reload
   path.
11. **Scratch folder is writable.** Create a `Scratch` folder in the
   Grafana UI; signed in as admin, save a throwaway dashboard into it.
   It is editable (unlike the read-only Homelab folder) and is not
   tracked in Git — see "Folder convention" above.

If any step fails, `kubectl -n observability get pods` + the
`kube-prometheus-stack-operator` pod's logs are the first places to
look; admission-webhook drift on HTTPRoute or ExternalSecret defaults
is the second (the values here spell every API-server default out;
the lint script catches the LB-pin variant, not these).

## What's NOT here

- **The rest of the ADR-0007 stack.** The Alertmanager Discord +
  healthchecks.io receivers and the developer-facing onboarding doc
  ship as their own slices — see the issue list under #176. The Cilium
  values bump that feeds the Cilium dashboard shipped in #179
  (`terraform/bootstrap/cilium.tf`).
- **A full per-addon dashboard library.** `dashboards/` ships the
  node-level and addon-health overviews plus the vendored Cilium
  dashboard; bespoke per-addon dashboards (ArgoCD, cert-manager, ESO,
  Longhorn) ship incrementally with the addons that need them, not in
  this slice. The `configMapGenerator` mechanism and the
  Homelab/Scratch folder convention above are what they build on.
