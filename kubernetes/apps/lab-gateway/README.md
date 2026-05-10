# `kubernetes/apps/lab-gateway/`

The central `lab` Cilium Gateway. One Gateway for the whole cluster;
every web-exposed addon attaches its `HTTPRoute` here via cross-namespace
`parentRefs` instead of bringing its own Gateway.

This addon landed in issue #48 / PR #62 — collapsing N per-addon
Gateways into one removed N LB-pool IPs, N per-host AdGuard rewrites,
and N per-namespace cert ReferenceGrants. AdGuard's seed wildcard
rewrite (`*.lab.jackhall.dev → 192.168.1.201`) is correct by
construction for every addon now, including ones that don't exist yet.

## Shape

```
kubernetes/apps/lab-gateway/
├── application.yaml             # single-source path-only ArgoCD Application
└── manifests/
    ├── namespace.yaml           # gateway-system Namespace
    ├── gateway.yaml             # the `lab` Gateway, listener on *.lab.jackhall.dev:443
    └── reference-grant.yaml     # authorises the cross-namespace cert ref into cert-manager
```

No chart, no values — just the three raw manifests. Lives in
`gateway-system` so it's one logical home for the cluster's north-south
routing primitives, separate from any addon namespace.

## What the Gateway provides

| Knob                                         | Value                                                  |
|----------------------------------------------|--------------------------------------------------------|
| `gatewayClassName`                           | `cilium` (no separate Gateway controller)              |
| LB IP (`lbipam.cilium.io/ips`)               | `192.168.1.201` — pinned, second pool slot after `.200`|
| Listener name                                | `https`                                                |
| Listener hostname                            | `*.lab.jackhall.dev`                                   |
| Listener port / protocol                     | `443` / `HTTPS`                                        |
| TLS mode                                     | `Terminate`                                            |
| TLS cert (`certificateRefs`)                 | `cert-manager/wildcard-lab-jackhall-dev-tls`           |
| `allowedRoutes.namespaces.from`              | `All`                                                  |

The wildcard listener means any `HTTPRoute` whose `hostnames` falls
under `*.lab.jackhall.dev` matches without touching this manifest. New
addons don't edit `gateway.yaml` — they just publish an `HTTPRoute`.

## Cross-namespace attachment without per-route ReferenceGrants

`allowedRoutes.namespaces.from: All` is what makes the central-Gateway
pattern usable. Each addon's `HTTPRoute` lives in the addon's own
namespace and attaches with:

```yaml
parentRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    namespace: gateway-system
    name: lab
    sectionName: https
```

No per-namespace `ReferenceGrant` is required for that attachment —
`from: All` is what authorises it. The Gateway-API spec calls this out
explicitly and it's the only mechanism that scales: one knob on the
Gateway instead of a grant per addon namespace.

The flip side: any cross-namespace **backend** ref (an `HTTPRoute`
whose `backendRefs` points at a Service in another namespace) does
still need a `ReferenceGrant` in the backend's namespace. The only
addon doing this today is `hubble-ui`, whose backend lives in
`kube-system`.

## Wildcard cert ReferenceGrant

The `wildcard-lab-jackhall-dev-tls` Secret is owned by cert-manager and
lives in the `cert-manager` namespace. `reference-grant.yaml` authorises
the `lab` Gateway in `gateway-system` to reference that Secret. This
replaces the per-addon `*-wildcard-cert` grants the per-addon-Gateway
era had to ship — one Gateway, one grant, instead of one per addon
namespace.

The cert itself is a `Certificate` produced by the
`letsencrypt-dns01` `ClusterIssuer` (real LE, DNS-01 against Cloud DNS),
provisioned in `terraform/bootstrap/cert-manager.tf`.

## LB IP allocation in context

| Resource                                | IP               | Source                                |
|-----------------------------------------|------------------|---------------------------------------|
| AdGuard Home DNS                        | `192.168.1.200`  | `kubernetes/apps/adguard-home/`       |
| Central `lab` Gateway                   | `192.168.1.201`  | this addon                            |
| Future `LoadBalancer` Services          | `.202`–`.230`    | first-come from the Cilium pool       |

`.201` is load-bearing for AdGuard's wildcard rewrite — see
[`kubernetes/apps/adguard-home/README.md`](../adguard-home/README.md#lb-ip-allocation)
for the rationale. Pinning the IP via `lbipam.cilium.io/ips` (as opposed
to letting Cilium allocate the next free address) is the difference
between "every addon's hostname resolves" and "AdGuard rewrites point
at a stale IP after a re-allocation."

## Adding a new web-exposed addon

The addon's `kubernetes/apps/<name>/` directory ships:

1. A `Namespace` (or relies on `CreateNamespace=true` in the
   `Application`).
2. An `HTTPRoute` in that namespace with the `parentRefs` block above
   and the addon's `Service` as a `backendRefs` entry. If the backend
   Service lives in a different namespace, also a `ReferenceGrant` in
   the backend's namespace.
3. Optional `gethomepage.dev/*` annotations on the `HTTPRoute` so the
   dashboard auto-discovers the card.

No edits to `lab-gateway/`, no new LB IP, no new AdGuard rewrite.

## Disaster recovery

Stateless. The Application owns the Namespace, the Gateway, and the
cross-namespace ReferenceGrant. Re-syncing this Application is the
entire DR procedure; the wildcard cert and the LB pool are owned by
`terraform/bootstrap/`.
