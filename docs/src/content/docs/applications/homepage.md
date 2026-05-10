---
title: Homepage
description: Cluster dashboard at dashboard.lab.jackhall.dev — auto-discovers other addons via gethomepage.dev/* annotations on their HTTPRoutes.
---

[Homepage](https://gethomepage.dev/) is the lab's single-page
dashboard, served at
[`https://dashboard.lab.jackhall.dev`](https://dashboard.lab.jackhall.dev/).
It surfaces a card per addon — name, link, icon, and (where the addon
has a widget) live status pulled from the addon's own API. The
defining design choice: cards aren't hand-listed in the dashboard's
own config. Each addon advertises itself via
`gethomepage.dev/*` annotations on its `HTTPRoute`, and Homepage
discovers them by watching the cluster's Gateway-API objects.

## Where it runs

A single Deployment in the `homepage` namespace, fronted by an
`HTTPRoute` for `dashboard.lab.jackhall.dev` attached cross-namespace
to the central [`lab` Gateway](./lab-gateway/) in `gateway-system`.
TLS termination and the wildcard cert are the Gateway's job, not
this addon's.

Source lives at
[`kubernetes/apps/homepage/`](https://github.com/jvcorredor/homelab/tree/main/kubernetes/apps/homepage):
the upstream `jameswynn/homepage` chart, a `helm-values.yaml` next to
the `Application`, and a `manifests/` directory with the `HTTPRoute`
and an `ExternalSecret` for the widget credentials.

## Auto-discovery via HTTPRoute annotations

The dashboard's `helm-values.yaml` carries no per-addon list:

```yaml
config:
  services: []
```

Cards instead come from `gethomepage.dev/*` annotations on each
addon's `HTTPRoute`. Homepage runs with
`config.kubernetes.gateway: true`, scans the Gateway-API objects in
the cluster, and renders one card per annotated route. The minimum
annotation set on a route looks like:

```yaml
metadata:
  annotations:
    gethomepage.dev/enabled: "true"
    gethomepage.dev/name: <display name>
    gethomepage.dev/description: <one-line>
    gethomepage.dev/group: <Cluster | Networking | Platform>
    gethomepage.dev/icon: <icon name>
    gethomepage.dev/href: https://<addon>.lab.jackhall.dev
```

Maintaining a parallel list in `helm-values.yaml` would defeat the
convention — the dashboard would have to be edited for every addon
change, on top of the addon's own routing. Co-locating the card
definition with the route the card links to is the whole point.

The dashboard layout (column counts per group) is the only piece
that does live in `helm-values.yaml`, since it's a property of the
dashboard itself rather than of any one addon.

## Status discovery and the override annotations

Each card can also surface a small live-status badge — typically the
addon's pod readiness — pulled from Homepage's own K8s API watch.
The default lookup assumes a pod with
`app.kubernetes.io/name=<HTTPRoute name>` in the HTTPRoute's
namespace. When that doesn't match — different name, different
namespace, or both — the card renders **NOT FOUND** unless the
HTTPRoute spells out an override:

| Annotation                  | Overrides                                        |
|-----------------------------|--------------------------------------------------|
| `gethomepage.dev/app`       | The `app.kubernetes.io/name` label selector      |
| `gethomepage.dev/namespace` | The namespace Homepage searches for the pod      |

Two live examples in the lab:

- **AdGuard Home** ships its `HTTPRoute` as `adguard-home-ui` but the
  bjw-s app-template renders the Deployment as `adguard-home`. Route
  sets `gethomepage.dev/app: adguard-home`.
- **Hubble UI** is installed by the Cilium Helm chart into
  `kube-system`, while its `HTTPRoute` lives in the `hubble-ui`
  namespace where the routing layer is owned. Route sets both
  `gethomepage.dev/app: hubble-ui` and
  `gethomepage.dev/namespace: kube-system`.

When adding a new addon: if the route name matches the Deployment's
`app.kubernetes.io/name` label and both live in the same namespace,
no override is needed.

## Widget credentials

A few addons (today: AdGuard Home, ArgoCD) ship a richer "widget"
that calls the addon's API for live data. Those calls need
credentials — and per the lab's secrets convention, credentials never
land in Git. Three values are stored in Google Secret Manager and
synced into a K8s Secret by ESO:

| GSM secret ID                | What it is                                |
|------------------------------|-------------------------------------------|
| `homepage-adguard-username`  | AdGuard admin username (plaintext)        |
| `homepage-adguard-password`  | AdGuard admin password (plaintext)        |
| `homepage-argocd-token`      | ArgoCD `homepage` readonly account token  |

The `homepage-widget-credentials` `ExternalSecret` projects each
value as `HOMEPAGE_VAR_*` env vars on the Deployment, and the addon
`HTTPRoute` annotations reference them via `{{HOMEPAGE_VAR_…}}`
substitutions in the widget block.

Two snags worth surfacing — the operator-side README at
[`kubernetes/apps/homepage/README.md`](https://github.com/jvcorredor/homelab/blob/main/kubernetes/apps/homepage/README.md)
covers the rotation procedures in full:

- The AdGuard widget needs the **plaintext** password; AdGuard
  itself stores a **bcrypt** hash. Two GSM containers therefore hold
  the same secret in two shapes — rotate them together or the widget
  starts failing auth while the addon still works.
- The ArgoCD `homepage` account is declared in
  `kubernetes/bootstrap/argocd/values.yaml` with `apiKey` capability
  only (no UI login). The token itself is minted out-of-band against
  the live cluster and uploaded to GSM — Argo doesn't store account
  credentials.

## Accessing the dashboard

Once the device is using AdGuard Home for resolution
([Split-horizon DNS](/homelab/networking/split-horizon-dns/)):

```sh
dig +short dashboard.lab.jackhall.dev    # → 192.168.1.201 (the lab Gateway)
curl -I https://dashboard.lab.jackhall.dev
# → HTTP/2 200, valid Let's Encrypt cert
```

Open [`https://dashboard.lab.jackhall.dev`](https://dashboard.lab.jackhall.dev/).
The dashboard loads with a card per addon, grouped by the
`gethomepage.dev/group` value on each route. There is no auth — the
hostname is only resolvable on the LAN side of the split-horizon
setup, which is the cluster's implicit trust boundary.

## More

The repo-side README at
[`kubernetes/apps/homepage/README.md`](https://github.com/jvcorredor/homelab/blob/main/kubernetes/apps/homepage/README.md)
covers the first-install flow (decide AdGuard creds → mint ArgoCD
token → upload to GSM → sync), the credential rotation procedures,
and the disaster-recovery story (Homepage is stateless; the only
state worth keeping is the GSM credentials).
