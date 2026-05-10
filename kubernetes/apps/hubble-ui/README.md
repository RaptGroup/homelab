# `kubernetes/apps/hubble-ui/`

[Hubble UI](https://docs.cilium.io/en/stable/observability/hubble/) — the
service-map and live flow-log frontend that ships with Cilium. Backs the
Tier 1 observability story (`docs/adr/` + observability memory): no
Prometheus, no Grafana, just whatever Cilium gives us out of the box.

The UI itself isn't installed by this addon. The Cilium Helm release in
`terraform/bootstrap/cilium.tf` enables `hubble.{relay,ui}.enabled=true`,
which puts the `hubble-ui` Deployment, Service, and ConfigMap into
`kube-system`. This addon owns only the routing layer that exposes the
existing Service at `hubble.lab.jackhall.dev`.

## Shape

```
kubernetes/apps/hubble-ui/
├── application.yaml                # single-source path-only ArgoCD Application
└── manifests/
    ├── namespace.yaml              # hubble-ui Namespace (routing layer only)
    ├── httproute.yaml              # hubble.lab.jackhall.dev → hubble-ui Service in kube-system
    └── referencegrant-service.yaml # authorises the cross-namespace backend ref
```

No `helm-values.yaml`, no chart source — Cilium's chart already shipped
the workload. The Application is a single path source pointing at
`manifests/`.

## Cross-namespace routing

Two cross-namespace edges make this work:

1. **HTTPRoute → Gateway.** The route lives in `hubble-ui` and attaches
   to the central `lab` Gateway in `gateway-system` via
   `parentRefs.namespace: gateway-system / name: lab`. Cross-namespace
   attachment is open-by-default at the Gateway side (`allowedRoutes.
   namespaces.from: All` on the listener, defined in
   `kubernetes/apps/lab-gateway/`), so no per-route ReferenceGrant is
   needed for the Gateway side.
2. **HTTPRoute → backend Service.** The backend is the `hubble-ui`
   Service in `kube-system`, which is owned by Cilium. A
   `ReferenceGrant` in `kube-system` (`referencegrant-service.yaml`)
   authorises HTTPRoutes from the `hubble-ui` namespace to target that
   Service. This is the only cross-namespace backend ref in the cluster
   today; everything else points at a Service in its own namespace.

TLS termination happens at the central Gateway with the wildcard cert,
not here.

## Homepage card and the `kube-system` override

The HTTPRoute carries `gethomepage.dev/*` annotations so the dashboard
auto-discovers the card, but Hubble UI needs the
**status-discovery override** documented in
`kubernetes/apps/homepage/README.md`:

```yaml
gethomepage.dev/app: hubble-ui          # selects app.kubernetes.io/name=hubble-ui
gethomepage.dev/namespace: kube-system  # in kube-system, not hubble-ui
```

Without these the card renders **NOT FOUND** because Homepage's default
search is `name=<HTTPRoute name>` in the HTTPRoute's namespace, and the
backing Deployment is in `kube-system` (where Cilium installed it), not
`hubble-ui` (where this repo owns the routing layer).

## Why a separate addon at all

The Cilium chart could in principle install a Gateway and HTTPRoute too,
but the routing layer needs to attach to the central `lab` Gateway
(issue #48) and reference the cluster wildcard cert — both ArgoCD-managed
state outside the Cilium chart. Owning the routing layer here keeps the
Cilium values file focused on data-plane config and lets the Hubble UI
exposure follow the same shape as every other web-exposed addon.

## Disaster recovery

Stateless. The Application owns only the Namespace, the HTTPRoute, and
the cross-namespace ReferenceGrant; the workload itself is reconciled
from the Cilium chart in `terraform/bootstrap/`. Re-syncing this
Application is the entire DR procedure.
