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

## LAN unreachability — labelled L2-announce opt-out

ADR-0006 calls for the `projects` Gateway to be **unreachable from the
LAN by construction** — the only ingress path is `cloudflared` →
Gateway, and a misbehaving LAN client cannot reach a preview by any
means.

The mechanism: the Gateway carries
`spec.infrastructure.labels.homelab.jackhall.dev/l2-announce: "false"`.
Gateway API v1 propagates infrastructure labels onto the auto-generated
Service (`cilium-gateway-projects` in `gateway-system`). The
`lab-l2-workers` `CiliumL2AnnouncementPolicy` in
[`terraform/bootstrap/cilium.tf`](../../../terraform/bootstrap/cilium.tf)
carries a matching `serviceSelector` that excludes services with that
label, so **no worker ARP-announces the Gateway's LB IP**. The IP
exists in Cilium's lbipam bookkeeping (Cilium 1.16's Gateway controller
still generates `type: LoadBalancer` unconditionally, and Cilium 1.18+'s
`CiliumGatewayClassConfig` only supports `LoadBalancer`/`NodePort` —
not `ClusterIP`), but it is invisible to L2 and therefore undeliverable
from any LAN device:

- LAN-side ARP-Who-Has for the Gateway's IP gets no reply → no MAC →
  no Ethernet frame can be built → the packet never leaves the
  client's NIC. There is no "knows the IP and crafts a Host header"
  bypass.
- `cloudflared` reaches the Gateway by Service DNS
  (`cilium-gateway-projects.gateway-system.svc.cluster.local`) over
  ClusterIP routing inside the cluster — that path does not depend on
  L2 announcement.
- Public-DNS resolution of `*.projects.jackhall.dev` goes via
  Cloudflare regardless; there is no AdGuard rewrite for the projects
  subzone.

This realises ADR-0006's "LAN-unreachable by construction" property
without a Cilium upgrade. See #142 for the decision record (Path B —
labelled opt-out — chosen over Path A — Cilium 1.18+ upgrade — because
Cilium 1.18 still cannot scope the generated Service to ClusterIP, so
the upgrade would not by itself deliver the property and would carry
significantly more blast radius).

The manifest still omits `lbipam.cilium.io/ips`: there is no benefit to
pinning the IP for a Service no node announces, and the lint guard
([`scripts/lint-apps.sh`](../../../scripts/lint-apps.sh)) recognises
`allowedRoutes.namespaces.from: Selector` as the structural marker for
"this Gateway isn't on the LB pool by design."

**Cosmetic gap.** Cilium's lbipam still allocates one address from
`lab-pool` (currently `.202`, since AdGuard and `lab` consume
`.200`/`.201`) for the unreachable Service. The address is consumed in
bookkeeping but unreachable on the wire. With 30 addresses in
`lab-pool.start..end` and one preview-env Gateway, this is acceptable.

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
