---
title: lab Gateway
description: The single Cilium Gateway every web-exposed addon attaches to — pinned to 192.168.1.201, terminates the wildcard cert for *.lab.jackhall.dev.
---

The `lab` Gateway is the cluster's one north-south HTTP entry point.
Every web-exposed addon — AdGuard's admin UI, the dashboard, ArgoCD,
Hubble UI, and any future addon — attaches its `HTTPRoute` here via
cross-namespace `parentRefs` instead of bringing its own Gateway. One
LB IP, one Envoy proxy, one wildcard cert, one knob to tune.

This wasn't always the shape: each addon used to bring its own Gateway.
Collapsing them down was issue #48 — see
[ADR-0002 — Cilium as the unified networking layer](https://github.com/RaptGroup/homelab/blob/main/docs/adr/0002-cilium-unified-networking.md)
for the broader "one Cilium for everything" rationale.

## Where it runs

A single `Gateway` resource lives in the `gateway-system` namespace.
There is no chart and no values file —
[`kubernetes/apps/lab-gateway/`](https://github.com/RaptGroup/homelab/tree/main/kubernetes/apps/lab-gateway)
is just three raw manifests: a Namespace, the `Gateway`, and one
`ReferenceGrant`.

| Knob                                  | Value                                             |
|---------------------------------------|---------------------------------------------------|
| `gatewayClassName`                    | `cilium`                                          |
| LB IP (`lbipam.cilium.io/ips`)        | `192.168.1.201` — pinned, second slot in the pool |
| Listener hostname                     | `*.lab.jackhall.dev`                              |
| Listener port / protocol              | `443` / `HTTPS`                                   |
| TLS mode                              | `Terminate`                                       |
| Cert ref                              | `cert-manager/wildcard-lab-jackhall-dev-tls`      |
| `allowedRoutes.namespaces.from`       | `All`                                             |

## Why pin the LB IP

`192.168.1.201` is load-bearing for AdGuard Home's wildcard rewrite:

```
*.lab.jackhall.dev → 192.168.1.201
```

That single rewrite covers every addon's hostname, present and future,
without ever editing the AdGuard UI. If the Gateway's LB IP drifted
(re-allocation after a re-create, or a different pod claiming the
slot), every addon's hostname would resolve to a stale address and the
LAN would silently break. Pinning the IP via `lbipam.cilium.io/ips`
makes the whole pattern correct by construction.

The other pinned IP, `192.168.1.200`, belongs to AdGuard Home's DNS
Service — that's the address LAN devices configure as their resolver.
Together they're the only two IPs in the `.200`–`.230` Cilium LB pool
that have to stay stable; the rest are first-come for any future
`LoadBalancer` Service.

## Cross-namespace `parentRefs`

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
`from: All` authorises it. This is the only Gateway-API mechanism that
scales: one knob on the Gateway instead of N grants in N addon
namespaces.

The flip side: a cross-namespace **backend** ref (an `HTTPRoute`
whose `backendRefs` point at a Service in another namespace) does still
need a `ReferenceGrant` in the backend's namespace. The only addon
doing that today is [Hubble UI](./hubble-ui/), whose backend is owned
by Cilium and lives in `kube-system`.

## Wildcard cert

The Gateway terminates TLS with a real Let's Encrypt cert for
`*.lab.jackhall.dev`. The cert lives in the `cert-manager` namespace as
the Secret `wildcard-lab-jackhall-dev-tls`, produced by the
`letsencrypt-dns01` `ClusterIssuer` (DNS-01 challenge against Cloud
DNS, see
[Split-horizon DNS](/homelab/networking/split-horizon-dns/)).

A single `ReferenceGrant` in `cert-manager` authorises the `lab`
Gateway in `gateway-system` to read that Secret. This replaces the
per-addon `*-wildcard-cert` grants that the per-addon-Gateway era had
to ship — one Gateway, one grant.

cert-manager handles renewal automatically; the renewed Secret
propagates to the Gateway without manual intervention.

## Adding a new web-exposed addon

The addon's `kubernetes/apps/<name>/` directory ships:

1. A `Namespace` (or relies on `CreateNamespace=true` on its
   `Application`).
2. An `HTTPRoute` in that namespace with the `parentRefs` block above
   and the addon's Service in `backendRefs`. If the backend is in a
   different namespace, also a `ReferenceGrant` in the backend's
   namespace.
3. Optional `gethomepage.dev/*` annotations on the `HTTPRoute` so the
   dashboard auto-discovers the card.

That's the entire integration. No edits to `lab-gateway/`, no new LB
IP, no new AdGuard rewrite. The wildcard listener matches every
hostname under `*.lab.jackhall.dev` automatically; the wildcard cert
covers every hostname under it; AdGuard's wildcard rewrite resolves
every hostname under it to `.201`.

## What lives where

Visually:

```
LAN client
   │
   │  DNS query for foo.lab.jackhall.dev
   ▼
192.168.1.200 (AdGuard Home, kubernetes/apps/adguard-home/)
   │
   │  wildcard rewrite → 192.168.1.201
   ▼
192.168.1.201 (the lab Gateway, this addon)
   │
   │  TLS terminate with wildcard cert (cert-manager)
   │  Host: foo.lab.jackhall.dev
   │  → match HTTPRoute parentRef'd here
   ▼
backend Service in foo's namespace
```

Two LB IPs, one cert, one Gateway. Adding addon #9 doesn't change the
left or middle column — it adds one more leaf at the right.

## More

The repo-side README at
[`kubernetes/apps/lab-gateway/README.md`](https://github.com/RaptGroup/homelab/blob/main/kubernetes/apps/lab-gateway/README.md)
spells out the full manifest set, the LB-IP allocation table in
context, and the migration that landed in issue #48.
