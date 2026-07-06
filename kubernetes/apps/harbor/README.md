# `kubernetes/apps/harbor/`

Self-hosted Harbor registry for the homelab — the LAN-only home for OCI
images and Helm charts the homelab builds and wants to keep on its own
infrastructure. Ships as a single Argo Application under the `harbor`
namespace; reached at `https://harbor.lab.jackhall.dev` on the LAN via
the central `lab` Cilium Gateway (same shape as
`grafana.lab.jackhall.dev`). See #221.

## Harbor vs. Artifact Registry

Two registry surfaces in the homelab, on purpose:

| Surface                                           | Audience | Reach                        | Push path                                  | Purpose                                                                  |
|---------------------------------------------------|----------|------------------------------|--------------------------------------------|--------------------------------------------------------------------------|
| Harbor (`harbor.lab.jackhall.dev`)                 | Operator | LAN-only via `lab` Gateway   | `docker login` + `docker push` from LAN   | Self-hosted home for artifacts the homelab builds and keeps on its infra |
| Artifact Registry `projects` repo (ADR-0006, #139) | Public   | `projects.jackhall.dev` via Cloudflare Tunnel | Keyless WIF push from ARC workflows (`tf-ci-arc-push`) | Public preview-environment images |

Harbor is distinct from the AR `projects` repo on every axis that
matters: audience (operator vs reviewers), reach (LAN vs public), push
path (manual `docker login` vs keyless WIF), and purpose (durable
self-hosted vs ephemeral preview). The two never share an image or a
credential. See ADR-0006 and CONTEXT.md → `projects` for the AR side.

## Shape

```
kubernetes/apps/harbor/
├── application.yaml                              # multi-source ArgoCD Application (default wave)
├── helm-values.yaml                              # harbor chart values
└── manifests/
    ├── namespace.yaml                             # harbor Namespace (no PSA opt-out — chart runs non-root)
    ├── harbor-httproute.yaml                      # harbor.lab.jackhall.dev → Harbor front-door Service
    └── external-secret-harbor-admin.yaml          # GSM → K8s Secret with HARBOR_ADMIN_PASSWORD
```

## What this app delivers

- A single Argo Application syncing to `Healthy` — Harbor core,
  registry, jobservice, portal, nginx, PostgreSQL, Redis, and Trivy.
- The Harbor portal reachable at `https://harbor.lab.jackhall.dev` on
  the LAN (via AdGuard's `*.lab.jackhall.dev → 192.168.1.201` wildcard
  rewrite, ADR-0003) with the existing LE wildcard cert.
- `admin` login at the portal, password sourced from the
  `harbor-admin-password` GSM container via ESO (same credential
  pipeline as Grafana's admin password).
- An OCI registry push/pull surface for the homelab's own images:
  `docker login harbor.lab.jackhall.dev` from any LAN device.
- OCI-hosted Helm chart hosting via Harbor's OCI registry support:
  `helm push oci://harbor.lab.jackhall.dev/<project>/charts`. The
  deprecated chartmuseum is **not** enabled.

## What this app does NOT deliver

- **Public reachability.** Harbor is LAN-only — no Cloudflare Tunnel,
  no `projects` Gateway attachment. The AR `projects` repo remains the
  public/preview push path (ADR-0006). Public Harbor reachability is
  explicitly out of scope for #221.
- **Registry replication / caching proxy of upstream registries.** Not
  the initial rationale; can be added later via Harbor's replication
  feature.
- **Trivy gating deploys or Argo syncs.** Trivy runs and surfaces scan
  results in the portal; it is not wired into CI or Argo.
- **OIDC/SSO.** Admin password only initially. SSO is deferred per the
  ADR-0007 observability stack's "3+ editors" trigger — this registry
  has one operator for now.
- **A new LB-pool address.** Harbor's front-door Service is `ClusterIP`;
  the `HTTPRoute` rides the existing `.201` lab Gateway. No
  `lbipam.cilium.io/ips` pin and no LB-pool address consumed.

## Resource cost

Heavier than a typical addon: Harbor bundles PostgreSQL, Redis, Trivy,
and nginx alongside core/registry/jobservice/portal. At default
settings this is roughly nine pods plus one PostgreSQL StatefulSet. If
the cluster is tight, disabling Trivy (`trivy.enabled: false` in
`helm-values.yaml`) sheds the Trivy pod and its PVC without losing the
registry / chart-hosting core value.

## Stateful PVCs

All five PVCs ride on `storageClassName: longhorn` — ADR-0005's
heuristic for singleton, valuable, must-survive-node-drain storage
applies to each (registry blobs, the Harbor database's image-metadata
tables, Trivy's vulnerability DB, Redis's session cache, jobservice's
job logs):

| Component              | Size  | StorageClass | Why Longhorn                                                            |
|------------------------|-------|--------------|-------------------------------------------------------------------------|
| Registry (image blobs) | 50 Gi | `longhorn`   | The whole point — losing built images on a worker reboot is the failure ADR-0005 prevents |
| Harbor database        | 5 Gi  | `longhorn`   | Image-metadata tables, project config, user accounts                    |
| Redis                  | 5 Gi  | `longhorn`   | Session store + job queue; small but singleton                          |
| Trivy                  | 5 Gi  | `longhorn`   | Vulnerability DB; refetched on restart if lost, but slow — worth pinning |
| Jobservice (job logs)  | 5 Gi  | `longhorn`   | Per-job execution logs; rotated but valuable                            |

Registry 50 Gi is the homelab-built image set with room to grow; the
others are 5 Gi each, comfortably above the chart defaults. Resize path
is the standard Longhorn `kubectl patch pvc … storage: …Gi` flow — the
chart issues fresh PVCs at the sizes in `helm-values.yaml`, so a
permanent bump means editing this file and letting Longhorn's volume
expansion do the runtime growth.

## Admin credential

The chart's `existingSecretAdminPassword` points at the `harbor-admin-password`
K8s Secret in this namespace; the chart's `existingSecretAdminPasswordKey`
(`HARBOR_ADMIN_PASSWORD`, the chart default) is the key it mounts as the
admin password env var on the core and exporter Deployments. ESO syncs
that Secret from the `harbor-admin-password` GSM container declared in
`terraform/gcp/`:

```
GSM `harbor-admin-password` (plaintext string)
   │
   ▼   ExternalSecret in this namespace (manifests/external-secret-harbor-admin.yaml)
K8s Secret `harbor/harbor-admin-password`
   key: HARBOR_ADMIN_PASSWORD
   │
   ▼   existingSecretAdminPassword / existingSecretAdminPasswordKey in helm-values.yaml
Harbor core pod env
```

The plaintext password is uploaded by the operator after a
`tofu apply` of `terraform/gcp/` — same pattern as
`grafana-admin-password` and friends, so the plaintext never enters
Terraform state or Git:

```
echo -n '<harbor-admin-password>' \
  | gcloud secrets versions add harbor-admin-password \
      --project rockingham-homelab --data-file=-
```

Until that upload happens, the ESO `harbor-admin-password` ExternalSecret
reports `SecretSyncedError` and the Harbor core pod fails to find the
credential — Argo will report the app as `Degraded` rather than
silently masking the missing secret. Same fail-loud shape as the
Grafana admin credential.

Rotation: re-upload a new version with the same command; ESO's next
refresh (1h) propagates it. Harbor picks the new credential up on
its next core pod restart — kick with
`kubectl -n harbor rollout restart deploy harbor-core` to apply
immediately.

## Smoke test

The acceptance criteria from #221 are: any LAN device with manual DNS
at AdGuard can log in and push/pull images and Helm charts. The
procedure:

1. **DNS resolves on LAN.** From a LAN device pointing manual DNS at
   AdGuard, `dig harbor.lab.jackhall.dev` returns `192.168.1.201`
   (the lab Gateway VIP via the
   `*.lab.jackhall.dev → 192.168.1.201` wildcard rewrite, ADR-0003).
2. **TLS works.** `curl -v https://harbor.lab.jackhall.dev`
   completes a handshake with the LE wildcard cert
   (`wildcard-lab-jackhall-dev-tls`), no `-k` needed.
3. **Admin login.** After the operator has uploaded the credential to
   the `harbor-admin-password` GSM container and ESO has synced it,
   open the URL in a browser; sign in with username `admin` and the
   uploaded password. The admin console shows the configured projects.
4. **PVCs bound.** All five on `longhorn` at the documented sizes:
   ```
   kubectl -n harbor get pvc
   # harbor-jobservice       Bound   …    5Gi    longhorn
   # harbor-registry         Bound   …   50Gi    longhorn
   # database-data-harbor-…  Bound   …    5Gi    longhorn   (StatefulSet volumeClaimTemplate)
   # data-harbor-redis-0     Bound   …    5Gi    longhorn   (StatefulSet volumeClaimTemplate)
   # data-harbor-trivy-0     Bound   …    5Gi    longhorn   (StatefulSet volumeClaimTemplate)
   ```
5. **Docker push/pull.** From a LAN device with Docker installed:
   ```
   docker login harbor.lab.jackhall.dev -u admin -p '<uploaded-password>'
   docker pull alpine:3.20
   docker tag alpine:3.20 harbor.lab.jackhall.dev/library/alpine:3.20
   docker push harbor.lab.jackhall.dev/library/alpine:3.20
   docker rmi harbor.lab.jackhall.dev/library/alpine:3.20 alpine:3.20
   docker pull harbor.lab.jackhall.dev/library/alpine:3.20
   ```
   (`library` is the default public project Harbor ships with; create
   a private one in the portal UI if a private push test is wanted.)
6. **Helm chart hosting.** From a LAN device with Helm 3.8+ (OCI
   support GA):
   ```
   echo '<harbor-admin-password>' \
     | helm registry login harbor.lab.jackhall.dev -u admin --password-stdin
   # Build a trivial chart and push it to a project, e.g. `library`:
   helm create smoke
   helm package smoke --version 0.1.0
   helm push smoke-0.1.0.tgz oci://harbor.lab.jackhall.dev/library/charts
   helm pull oci://harbor.lab.jackhall.dev/library/charts/smoke --version 0.1.0
   ```
   The chart appears in the portal under the matching project.

If any step fails, `kubectl -n harbor get pods` and the
`harbor-core` pod's logs are the first places to look; admission-webhook
drift on HTTPRoute or ExternalSecret defaults is the second (the values
here spell every API-server default out; the lint script catches the
LB-pin variant, not these).

## Out-of-band operator steps

These run once, after a `tofu apply` of `terraform/gcp/` has created
the `harbor-admin-password` GSM container. None of them touch Git or
Terraform state:

1. **Harbor admin password.** Pick a password; upload it:
   ```
   echo -n '<harbor-admin-password>' \
     | gcloud secrets versions add harbor-admin-password \
         --project rockingham-homelab --data-file=-
   ```
2. Within one ESO refresh interval (1h — force it sooner with
   `kubectl -n harbor annotate externalsecret harbor-admin-password force-sync=$(date +%s) --overwrite`)
   the K8s Secret appears and the Harbor core pod schedules. Login at
   `https://harbor.lab.jackhall.dev` with username `admin` and the
   password you uploaded.

## What's NOT here

- **Migrating ArgoCD's chart sources to Harbor.** The app-of-apps
  still pulls upstream chart repos; self-hosting the homelab's charts
  there is a future move once Harbor is proven.
- **Registry replication / caching proxy of upstream registries.**
  Not the initial rationale; can be added later via Harbor's
  replication feature.
- **Trivy scan results gating deploys or Argo syncs.** Trivy runs but
  is not wired into CI/Argo; scan results show in the portal only.
- **OIDC/SSO for Harbor.** Admin password only initially; defer SSO
  per the ADR-0007 observability stack's "3+ editors" trigger.
- **A new LB-pool address.** Harbor rides the existing lab Gateway at
  `.201`; no LB-pool address consumed.