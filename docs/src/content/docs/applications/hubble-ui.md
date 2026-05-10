---
title: Hubble UI
description: Cilium's network-flow visualizer at hubble.lab.jackhall.dev — the entire Tier 1 observability story for the lab.
---

[Hubble UI](https://docs.cilium.io/en/stable/observability/hubble/) is
Cilium's flow-log frontend: a live service map plus an L4/L7 flow log
that surfaces what's actually talking to what inside the cluster. It is
the entire Tier 1 observability story for the Rockingham Homelab —
there is no Prometheus, no Grafana, no Alertmanager. The deeper
observability stack is a deliberately deferred Phase-2 deep-dive.

## Where it runs

The Hubble UI Deployment, Service, and ConfigMap are installed by the
**Cilium Helm release**, not by an ArgoCD addon. `hubble.relay.enabled`
and `hubble.ui.enabled` are flipped on in `terraform/bootstrap/cilium.tf`,
so the workload itself lives in `kube-system` alongside Cilium.

A separate ArgoCD addon
([`kubernetes/apps/hubble-ui/`](https://github.com/jvcorredor/homelab/tree/main/kubernetes/apps/hubble-ui))
owns only the routing layer that exposes the existing Service:

- A `hubble-ui` namespace (which doesn't host the workload — it hosts
  the routing primitives).
- An `HTTPRoute` for `hubble.lab.jackhall.dev` attached cross-namespace
  to the central [`lab` Gateway](./lab-gateway/) in `gateway-system`.
- A `ReferenceGrant` in `kube-system` authorising the cross-namespace
  backend reference to the `hubble-ui` Service that Cilium installed
  there.

This is the only addon in the cluster with a cross-namespace **backend**
ref — every other addon's `HTTPRoute` targets a Service in its own
namespace.

## Tier 1 observability

The Cilium agent already sees every packet on the cluster's data plane
(it is the data plane), so flow visibility is free in the sense that no
extra scrape pipeline, no extra TSDB, and no extra dashboards have to
be maintained. Hubble UI surfaces three things:

1. **Service map** — auto-built graph of which Services and external
   endpoints are talking to which.
2. **Flow log** — live tail of L3/L4 flows with verdicts (forwarded /
   dropped) and policy attribution.
3. **Namespace filter** — pick a namespace, see only the flows
   originating or terminating there.

For the lab's current scale (≤8 addons, ≤6 nodes) this is more than
enough to answer "is X reaching Y" and "did the new NetworkPolicy break
something." When workload metrics or alerting become load-bearing, the
plan is to bring up `kube-prometheus-stack` as a separate Phase-2 pass —
`metrics-server` covers the narrower `kubectl top` / HPA case in the
meantime ([metrics-server](./metrics-server/)).

## Accessing the UI

Once the device is using AdGuard Home for resolution
([Split-horizon DNS](/homelab/networking/split-horizon-dns/)):

```sh
dig +short hubble.lab.jackhall.dev    # → 192.168.1.201 (the lab Gateway)
```

Open [`https://hubble.lab.jackhall.dev`](https://hubble.lab.jackhall.dev/).
The browser should show a valid Let's Encrypt cert (the cluster
wildcard for `*.lab.jackhall.dev`, terminated at the central Gateway).
The UI exposes a namespace dropdown — pick `kube-system` to see Cilium
itself, or any addon namespace to scope the view.

There is no auth on the UI today. The hostname is only resolvable from
the LAN side of the split-horizon setup, which is the cluster's
implicit trust boundary; the UI is read-only and surfaces only metadata
(source/dest, verdict, port) rather than packet payloads. That trade-off
is acceptable for Tier 1; Tier 2 observability would re-evaluate.

## Homepage card and the `kube-system` override

The dashboard auto-discovers the Hubble card from
`gethomepage.dev/*` annotations on the `HTTPRoute`. Because the backing
Deployment is in `kube-system` (where Cilium installed it), not in the
`hubble-ui` namespace where the routing layer lives, the route also
carries Homepage's status-discovery override:

```yaml
gethomepage.dev/app: hubble-ui
gethomepage.dev/namespace: kube-system
```

The convention is documented in
[`kubernetes/apps/homepage/README.md`](https://github.com/jvcorredor/homelab/blob/main/kubernetes/apps/homepage/README.md#status-discovery-overrides);
without these annotations the card renders **NOT FOUND**.

## More

The repo-side README at
[`kubernetes/apps/hubble-ui/README.md`](https://github.com/jvcorredor/homelab/blob/main/kubernetes/apps/hubble-ui/README.md)
covers the cross-namespace routing topology in more detail and explains
why the workload lives in `kube-system` while the routing layer is a
separate addon directory.
