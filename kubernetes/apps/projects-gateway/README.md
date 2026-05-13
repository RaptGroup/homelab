# `kubernetes/apps/projects-gateway/`

The `projects` Cilium Gateway — the second cluster Gateway, alongside
`lab`, for public preview environments. Receives cleartext HTTP from
the in-cluster `cloudflared` Deployment, which has already terminated
TLS at Cloudflare's edge using an ACM-issued advanced wildcard for
`*.projects.jackhall.dev` (see ADR-0006's 2026-05-13 amendment for
why Universal SSL is insufficient). Routes by hostname to HTTPRoutes
in preview namespaces.

See [ADR-0006](../../../docs/adr/0006-public-preview-environments-via-cloudflare-tunnel.md)
for the full design; this addon is the cluster-side surface, paired
with `terraform/cloudflare/` (zone records + tunnel) and
[`kubernetes/apps/cloudflared/`](../cloudflared/) (the connector).

## Shape

```
kubernetes/apps/projects-gateway/
├── application.yaml            # single-source path-only ArgoCD Application
└── manifests/
    └── gateway.yaml            # the `projects` Gateway, HTTP listener on *.projects.jackhall.dev:80
```

No chart, no values, no Namespace, no ReferenceGrant — just the one
Gateway manifest. `gateway-system` is owned by `lab-gateway`'s
Application; the two Applications share the namespace but don't share
the Namespace resource ownership.

## What the Gateway provides

| Knob                                            | Value                                                     |
|-------------------------------------------------|-----------------------------------------------------------|
| `gatewayClassName`                              | `cilium`                                                  |
| Listener name                                   | `http`                                                    |
| Listener hostname                               | `*.projects.jackhall.dev`                                 |
| Listener port / protocol                        | `80` / `HTTP`                                             |
| TLS                                             | None at this Gateway — terminated at CF using ACM wildcard |
| `allowedRoutes.namespaces.from`                 | `Selector`                                                |
| namespaceSelector                               | `projects.jackhall.dev/enabled=true`                      |

The HTTP-only listener is deliberate. The reviewer's browser talks TLS
to Cloudflare's edge over the public internet; cloudflared dials
outbound from inside the cluster, multiplexes that connection over a
QUIC tunnel back to CF's edge, and demuxes incoming requests as plain
HTTP into this Gateway. Adding a TLS listener here would re-terminate
inside the cluster for no benefit — the cert chain is owned by CF, the
in-cluster hop is over a network the operator owns end-to-end.

## Namespace gating

`allowedRoutes.namespaces.from: Selector` is the structural gate
between "the preview-env path exists" and "every namespace in the
cluster can publish a preview." Only namespaces labelled
`projects.jackhall.dev/enabled=true` can attach an HTTPRoute to this
Gateway. The preview-env wrapper (the local `just` recipe and the
PR-driven GitHub Actions workflow — both pending on follow-up issues)
applies the label at namespace creation time; nothing else should.

A namespace created out of band (a stray `kubectl create namespace`,
a chart that doesn't know about preview-env conventions) cannot
publish to `*.projects.jackhall.dev` by accident — the API itself
rejects the HTTPRoute's parentRef. There's no controller to bypass,
no convention to forget; the gate is in the Gateway spec.

## How cloudflared reaches this Gateway

`cloudflared` forwards `*.projects.jackhall.dev` to:

```
http://cilium-gateway-projects.gateway-system.svc.cluster.local:80
```

`cilium-gateway-<gateway-name>` is the naming convention Cilium uses
for the Service it generates per Gateway. The forward target is
configured at the Cloudflare side (via
`terraform/cloudflare/main.tf` → `cloudflare_zero_trust_tunnel_cloudflared_config`),
not in a local cloudflared config file — the tunnel is remote-managed.

## LAN reachability and the Cilium 1.16 constraint

ADR-0006 calls for the `projects` Gateway to be **unreachable from the
LAN by construction** — a ClusterIP-only Service with no LB-pool
address, so the Cilium LB pool stays a LAN-only surface.

In Cilium 1.16 (this cluster's current version), that property is not
fully realisable. The Gateway controller always generates a Service of
`type: LoadBalancer` for a Gateway resource; the parametrized
`CiliumGatewayClassConfig` CRD that would let us scope the generated
Service to ClusterIP ships in **Cilium 1.18+**, and even then only
supports `LoadBalancer` and `NodePort` as Service types per the
upstream docs as of writing.

What this means in practice for the tracer-bullet PR:

- This manifest **omits** `lbipam.cilium.io/ips` per the issue's "no
  LB pool IP annotation" requirement. The lint guard
  ([`scripts/lint-apps.sh`](../../../scripts/lint-apps.sh)) is
  updated to skip the pin check for Gateways carrying the
  `homelab.jackhall.dev/lan-routable: "false"` annotation — that
  annotation is the explicit operator-facing marker.

  Wait — the manifest as committed does **not** carry that annotation
  either, because the lint update in this PR widens the skip to
  Gateways whose namespaceSelector gate (`from: Selector`) marks them
  as preview-env-only. See the script comment for the rationale; the
  annotation form remains the escape hatch if a future
  preview-shaped Gateway wants a different gate.

- Cilium's lbipam will allocate the first free address from `lab-pool`
  (currently `.202` since AdGuard and `lab` consume `.200` / `.201`),
  and the existing L2-announcement policy on workers will ARP-announce
  it. A LAN client that knows the IP and crafts a Host header request
  (`curl -H "Host: foo.projects.jackhall.dev" http://192.168.1.202`)
  can technically reach a preview workload. Public-DNS resolution of
  `*.projects.jackhall.dev` goes via Cloudflare regardless — there is
  no AdGuard rewrite for the projects subzone.

- Realising ADR-0006's structural-impossibility property is a
  follow-up. Two paths:
  1. Cilium 1.18+ upgrade + a parametrized GatewayClass scoping the
     `projects` Gateway's generated Service to a non-LoadBalancer
     shape (NodePort + iptables-block, or — if upstream lands ClusterIP
     support — ClusterIP).
  2. A separate `CiliumL2AnnouncementPolicy` whose `serviceSelector`
     opts services *out* by label, with this Gateway's Service
     carrying the opt-out label. The IP is still allocated from the
     pool, but no ARP frames advertise it — LAN clients can't reach
     it without a static route.

  Both are out of scope for the tracer-bullet PR; tracked as a
  follow-up issue.

## End-to-end verification

After the full path is wired (terraform/cloudflare/ applied, GSM
token populated, cloudflared addon synced, NS delegation published
at the apex), verify with a single canary:

```sh
# 1. Hand-create a labeled namespace.
kubectl create namespace canary-test
kubectl label namespace canary-test projects.jackhall.dev/enabled=true

# 2. Apply a Pod + Service + HTTPRoute. nginx public image so the
#    AR pull path isn't on the critical path for this slice.
kubectl -n canary-test apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: canary
  labels: { app: canary }
spec:
  containers:
    - name: nginx
      image: nginx:1.27
      ports: [{ containerPort: 80 }]
---
apiVersion: v1
kind: Service
metadata:
  name: canary
spec:
  selector: { app: canary }
  ports: [{ port: 80, targetPort: 80 }]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: canary
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      namespace: gateway-system
      name: projects
      sectionName: http
  hostnames:
    - canary-test.projects.jackhall.dev
  rules:
    - backendRefs:
        - name: canary
          port: 80
EOF

# 3. From a network OUTSIDE the LAN (cellular, a VPS, etc.):
curl -sS https://canary-test.projects.jackhall.dev
# Expect: nginx welcome HTML, status 200, CF-served cert.

# 4. Tear down.
kubectl delete namespace canary-test
```

The canary namespace is intentionally **not** committed to the repo.
Once verified, it's deleted — the next preview comes through the
wrapper, not by hand.

## Disaster recovery

Stateless. The Application owns the single Gateway manifest; re-syncing
this Application is the entire DR procedure on the cluster side. The
Cloudflare-side state (zone records, tunnel) is in
`terraform/cloudflare/` state in GCS.
