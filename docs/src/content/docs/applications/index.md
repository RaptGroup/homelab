---
title: Applications
description: ArgoCD-managed addons running in the Rockingham cluster, one directory per addon under kubernetes/apps/.
---

Everything past bootstrap is reconciled by ArgoCD from
[`kubernetes/apps/`](https://github.com/jvcorredor/homelab/tree/main/kubernetes/apps).
One directory per addon; dropping a new directory there is how a new
addon gets into the cluster. Each entry below links to its source and,
where applicable, the LAN endpoint it serves.

## Addons

| Addon | What it does | Access | Source |
|---|---|---|---|
| [AdGuard Home](./adguard-home/) | LAN DNS resolver and ad-blocker; fronts `*.lab.jackhall.dev` for any device pointed at it. | DNS `192.168.1.200`<br/>UI `https://adguard.lab.jackhall.dev` | [`adguard-home/`](https://github.com/jvcorredor/homelab/tree/main/kubernetes/apps/adguard-home) |
| [ARC controller](./arc/) | Actions Runner Controller — manages the GitHub Actions runner scale sets. | None (operator) | [`arc-controller/`](https://github.com/jvcorredor/homelab/tree/main/kubernetes/apps/arc-controller) |
| [ARC runners — brazostech](./arc/) | GitHub Actions runner scale set for the `brazostech` GitHub App installation. | None (ephemeral pods) | [`arc-runners-brazostech/`](https://github.com/jvcorredor/homelab/tree/main/kubernetes/apps/arc-runners-brazostech) |
| [ARC runners — raptgroup](./arc/) | GitHub Actions runner scale set for the operator's `raptgroup` GitHub App installation. | None (ephemeral pods) | [`arc-runners-raptgroup/`](https://github.com/jvcorredor/homelab/tree/main/kubernetes/apps/arc-runners-raptgroup) |
| Homepage | Cluster dashboard; auto-discovers other addons via `gethomepage.dev/*` annotations on their `HTTPRoute`s. | `https://dashboard.lab.jackhall.dev` | [`homepage/`](https://github.com/jvcorredor/homelab/tree/main/kubernetes/apps/homepage) |
| [Hubble UI](./hubble-ui/) | Cilium's network-flow observability UI — live service map and L4/L7 flow log. | `https://hubble.lab.jackhall.dev` | [`hubble-ui/`](https://github.com/jvcorredor/homelab/tree/main/kubernetes/apps/hubble-ui) |
| [`lab` Gateway](./lab-gateway/) | The single Gateway API `Gateway` every web-exposed addon attaches to; terminates TLS for `*.lab.jackhall.dev`. | LB `192.168.1.201` | [`lab-gateway/`](https://github.com/jvcorredor/homelab/tree/main/kubernetes/apps/lab-gateway) |
| metrics-server | Kubernetes Metrics API extension; backs `kubectl top` and Homepage's cluster CPU/RAM widget. | None (`metrics.k8s.io` API) | [`metrics-server/`](https://github.com/jvcorredor/homelab/tree/main/kubernetes/apps/metrics-server) |

## How the LAN endpoints fit together

Two LB IPs out of the Cilium `.200`–`.230` pool carry every addon's
traffic:

- `192.168.1.200` — **AdGuard Home DNS.** First hop for any device
  configured to use it. Resolves `*.lab.jackhall.dev` to `.201` via a
  wildcard rewrite.
- `192.168.1.201` — **The `lab` Gateway.** Terminates TLS with the
  Let's Encrypt wildcard cert and routes by `Host:` header to the
  addon behind each hostname (`dashboard`, `adguard`, `hubble`, …)
  via `HTTPRoute`s in the addons' own namespaces.

See [Split-horizon DNS](/homelab/networking/split-horizon-dns/) for
why DNS resolves the way it does, and the per-addon page (where one
exists) for what each addon actually does.
