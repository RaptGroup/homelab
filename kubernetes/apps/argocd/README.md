# `kubernetes/apps/argocd/`

Routing layer for the self-managed ArgoCD install. Exposes argocd-server
at `https://argocd.lab.jackhall.dev` so the documented `argocd login`
workflow works without `kubectl port-forward` (issue #49).

ArgoCD itself is owned by the bootstrap-time
[`kubernetes/bootstrap/argocd/`](../../bootstrap/argocd/) Application —
chart values, RBAC, accounts, server flags all live there. This addon
only ships the HTTPRoute that attaches argocd-server to the central
`lab` Gateway. Same shape as `kubernetes/apps/hubble-ui/`.

## Shape

```
kubernetes/apps/argocd/
├── application.yaml           # path-only ArgoCD Application
└── manifests/
    └── httproute.yaml         # argocd.lab.jackhall.dev → argocd-server (attaches to the central `lab` Gateway)
```

TLS termination + wildcard-cert handling happens at the central `lab`
Gateway in `gateway-system` (owned by `kubernetes/apps/lab-gateway/`).
The HTTPRoute attaches cross-namespace via `parentRefs.namespace:
gateway-system`. `argocd-server` runs with `server.insecure: true`
(`kubernetes/bootstrap/argocd/values.yaml`), so the in-cluster hop is
plaintext on port 80 — same model as adguard-home.

AdGuard Home's seed wildcard rewrite (`*.lab.jackhall.dev → 192.168.1.201`)
resolves `argocd.lab.jackhall.dev` to the central Gateway by
construction. No per-host AdGuard rewrite is needed (post-#48).

## First-install flow

1. **Sync the Application.** ArgoCD picks `argocd-routing` up from the
   root app-of-apps automatically. First sync brings up:

   - the `argocd-server` HTTPRoute for `argocd.lab.jackhall.dev`,
     attaching to the central `lab` Gateway in `gateway-system`.

2. **Verify.** Once the device is using AdGuard Home for resolution
   (per `kubernetes/apps/adguard-home/README.md`):

   ```sh
   dig +short argocd.lab.jackhall.dev    # → 192.168.1.201
   curl -I https://argocd.lab.jackhall.dev   # → HTTP/2 200, valid LE cert
   argocd login argocd.lab.jackhall.dev --grpc-web
   ```

   `--grpc-web` stays required because argocd-server runs with
   `server.insecure: true` — the CLI can't negotiate plain gRPC over
   HTTP/2 the way it does against a TLS-terminating server.

## Homepage widget

The HTTPRoute carries the `gethomepage.dev/widget.*` annotations for
the Homepage ArgoCD widget. Credentials are supplied by
`kubernetes/apps/homepage/` — its ExternalSecret syncs
`homepage-argocd-token` from GSM into `HOMEPAGE_VAR_ARGOCD_TOKEN`,
which the `widget.key` annotation references via
`{{HOMEPAGE_VAR_ARGOCD_TOKEN}}`. See
[`kubernetes/apps/homepage/README.md`](../homepage/README.md) for the
token-minting recipe.

The widget calls argocd-server in-cluster (`http://argocd-server.argocd:80`)
rather than going through the Gateway, avoiding a needless TLS hop and
sidestepping the `--grpc-web` story for an internal API call.
