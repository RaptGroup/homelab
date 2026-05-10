---
title: AdGuard Home
description: The LAN DNS resolver and ad-blocker that fronts *.lab.jackhall.dev for every device pointed at it.
---

[AdGuard Home](https://adguard.com/en/adguard-home/overview.html) is
the lab's LAN-side DNS resolver and ad-blocker. It is also the
in-cluster half of the [split-horizon DNS](/homelab/networking/split-horizon-dns/)
setup: every internal hostname under `*.lab.jackhall.dev` is resolved
here, never by the public Cloud DNS zone.

## Where it runs

A single Deployment in the `adguard-home` namespace, fronted by two
Services:

- **DNS** — a Cilium `LoadBalancer` Service pinned to `192.168.1.200`,
  the first address in the `.200`–`.230` LB pool. This is what LAN
  devices point at as their DNS server.
- **Admin UI** — reached at
  [`https://adguard.lab.jackhall.dev`](https://adguard.lab.jackhall.dev/)
  via an `HTTPRoute` attached to the central `lab` Gateway. The UI
  itself is only reachable once the device asking is already using
  AdGuard Home for resolution (otherwise the hostname doesn't resolve).

Source lives at
[`kubernetes/apps/adguard-home/`](https://github.com/jvcorredor/homelab/tree/main/kubernetes/apps/adguard-home).

## Role in split-horizon DNS

The lab issues a real Let's Encrypt wildcard cert for
`*.lab.jackhall.dev` via DNS-01 against Google Cloud DNS, but **no**
internal hostnames live in that public zone. Cloud DNS holds only the
ACME challenge records. Everything else — `dashboard.lab.jackhall.dev`,
`hubble.lab.jackhall.dev`, `adguard.lab.jackhall.dev`, and every future
addon — resolves through AdGuard Home.

Two pieces make that work:

1. **A single wildcard rewrite** in AdGuard:
   `*.lab.jackhall.dev → 192.168.1.201`. That target is the central
   `lab` Gateway's LB IP. Every web-exposed addon's hostname resolves
   to the same address; the Gateway routes by `Host:` header to the
   right backend.
2. **A pinned LB IP** for AdGuard's own DNS Service (`192.168.1.200`),
   so the address a device points at as its DNS server doesn't drift
   across reschedules.

New web-exposed addons don't need a new AdGuard rewrite — the wildcard
already covers them. They only need an `HTTPRoute` attaching to the
`lab` Gateway.

For the architecture rationale (why split-horizon at all, and why
AdGuard Home runs in-cluster), see
[Split-horizon DNS](/homelab/networking/split-horizon-dns/) and
[ADR-0003](https://github.com/jvcorredor/homelab/blob/main/docs/adr/0003-public-domain-dns-tls-split-horizon.md).

## Accessing the UI

You can only reach the admin UI from a device already using AdGuard
Home for DNS — the hostname is served by AdGuard itself.

1. Point the device at `192.168.1.200` as its DNS server. The per-OS
   recipes are on the
   [Split-horizon DNS](/homelab/networking/split-horizon-dns/#per-os-manual-dns-recipes)
   page.
2. Verify resolution:

   ```sh
   dig +short adguard.lab.jackhall.dev    # → 192.168.1.201
   ```

3. Open [`https://adguard.lab.jackhall.dev`](https://adguard.lab.jackhall.dev/).
   The browser should show a valid Let's Encrypt cert. Log in with the
   admin credentials provisioned at install time (these aren't checked
   into the repo or this site — they're stored in the operator's
   password manager).

If `dig` returns nothing, the device is still using its old DNS server;
re-check the manual DNS config.

## Source-IP caveat

The DNS Service uses `externalTrafficPolicy: Cluster`, so AdGuard sees
the source IP of the cluster node that forwarded the query, not the
actual LAN client. That means anything in the UI keyed off client IP —
"Top clients", per-client rules, per-client query log — can't tell LAN
devices apart by IP alone. Use AdGuard's **ClientIDs** (DoH/DoT
suffixes or a PTR record) when per-client behavior matters. The
underlying reason ETP=Cluster is the right choice for an L2-announced
LB Service is in
[`kubernetes/apps/adguard-home/README.md`](https://github.com/jvcorredor/homelab/blob/main/kubernetes/apps/adguard-home/README.md#source-ip-and-per-client-features).

## More

The repo-side README at
[`kubernetes/apps/adguard-home/README.md`](https://github.com/jvcorredor/homelab/blob/main/kubernetes/apps/adguard-home/README.md)
covers operator-only material: the first-install flow (bcrypt hash →
GSM → ESO sync), what the seed config writes vs. what the UI owns,
and the disaster-recovery procedure.
