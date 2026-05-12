# `kubernetes/apps/cloudflared/`

The outbound Cloudflare Tunnel connector for the public preview-env
path (ADR-0006). One Deployment of the upstream `cloudflare/cloudflared`
container that dials Cloudflare's edge from inside the cluster and
forwards inbound `*.projects.jackhall.dev` traffic to the `projects`
Cilium Gateway. No inbound ports on the Optimum gateway; the tunnel
dials outbound on UDP/7844.

Paired with `terraform/cloudflare/` (the CF-side zone records, tunnel
resource, and ingress config) and [`kubernetes/apps/projects-gateway/`](../projects-gateway/)
(the in-cluster Gateway this Deployment forwards to).

## Shape

```
kubernetes/apps/cloudflared/
├── application.yaml                  # single-source path-only ArgoCD Application
└── manifests/
    ├── namespace.yaml                # cloudflared Namespace
    ├── external-secret.yaml          # ESO sync of the per-tunnel connector token from GSM
    └── deployment.yaml               # the cloudflared Deployment, single replica
```

No Helm chart. The upstream `cloudflare-tunnel-remote` chart bakes the
connector token into Helm values, with no "use an existing Secret" knob —
that would put a long-lived credential in git or in an ArgoCD Helm
parameter override, both of which we explicitly avoid (every other
secret in this repo flows through ESO from GSM). Raw manifests give
the same shape with the secret path intact.

## Why this addon is here

cloudflared exists because the cluster has **no inbound ports on the
LAN edge.** The Optimum gateway has no port-forward into the cluster,
and ADR-0006 deliberately keeps it that way for the preview-env
surface. cloudflared establishes an outbound QUIC connection to
Cloudflare's edge; CF terminates TLS from the reviewer's browser at
the edge and forwards the request body down the established
connection. The cluster never accepts a TCP connect from the public
internet.

## Token path

```
terraform/cloudflare/                    # creates the named tunnel,
   reads cloudflare_zero_trust_tunnel_cloudflared_token,
   writes the value as a new google_secret_manager_secret_version
        │
        ▼
GSM secret `cloudflare-tunnel-token`     # container TF-managed in terraform/gcp/
        │  ESO ClusterSecretStore `gsm` (refresh 1h)
        ▼
K8s Secret `cloudflared-tunnel-token`    # in the cloudflared namespace, key: token
        │  secretKeyRef
        ▼
$TUNNEL_TOKEN env var on cloudflared pod
```

cloudflared's `run` subcommand reads `$TUNNEL_TOKEN`, decodes it, and
uses the embedded tunnel UUID + secret to authenticate the connection.
The token is **per-tunnel**; rotating it (a `terraform taint
cloudflare_zero_trust_tunnel_cloudflared.projects` followed by
`tofu apply` in `terraform/cloudflare/`) lands a new GSM version and
the pod picks it up at the next ESO refresh — sooner with a forced
sync:

```sh
kubectl -n cloudflared annotate externalsecret cloudflared-tunnel-token \
  force-sync=$(date +%s) --overwrite
kubectl -n cloudflared rollout restart deployment cloudflared
```

## Ingress rules are at Cloudflare

cloudflared's `config_src` for this tunnel is `cloudflare` (set in
`terraform/cloudflare/main.tf`), so the ingress rules — "forward
`*.projects.jackhall.dev` to `http://cilium-gateway-projects.gateway-system.svc.cluster.local:80`,
fallback to 404" — live at the Cloudflare side, not in a config file
mounted into this pod. That's why this Deployment is so minimal: just
the container, the token, and metrics.

Changing the in-cluster forward target (e.g. a Gateway rename, a
namespace move) is a `terraform apply` in `terraform/cloudflare/`,
not a redeploy here.

## Why single replica

Cloudflare Tunnel supports running multiple cloudflared connectors
against the same tunnel ID; CF multiplexes the connections across edge
POPs for HA and rolling-restart safety. We default to **one replica**
because:

- The preview-env surface is non-critical and short-lived by
  construction (ADR-0006).
- The rolling-update strategy here keeps `maxUnavailable: 0` and
  `maxSurge: 1`, so even a single-replica rollout briefly has two
  pods, both connected — no tunnel-disconnect blip during image bumps.
- A genuine outage of the single cloudflared pod is a few-second
  reconnect, well within the SLO for "demo URLs."

Bumping to 2+ replicas is a one-line `replicas:` change in
`deployment.yaml` whenever the surface starts hosting anything that
warrants it.

## Verifying after first sync

```sh
# 1. ESO has populated the K8s Secret.
kubectl -n cloudflared get secret cloudflared-tunnel-token \
  -o jsonpath='{.data.token}' | base64 -d | head -c 16
# Expect: 16 chars of an opaque token (it's a JWT-ish blob, not
# human-readable). Empty means ESO hasn't synced yet; check
# `kubectl -n cloudflared describe externalsecret cloudflared-tunnel-token`.

# 2. The Deployment is Ready.
kubectl -n cloudflared get deploy cloudflared
# Expect: READY 1/1.

# 3. The connector reports a healthy tunnel.
kubectl -n cloudflared logs deploy/cloudflared --tail=50 \
  | grep -E 'Connection .* registered|Registered tunnel connection'
# Expect: at least one line per CF data center connection (typically 2-4).

# 4. The CF dashboard mirror.
# Zero Trust → Networks → Tunnels → `rockingham-projects` should show
# status: HEALTHY with one or more active connectors.
```

## Disaster recovery

Stateless. The token is in GSM (off-machine, off-cluster). Re-syncing
this Application from scratch (ExternalSecret pulls the latest GSM
version, Deployment rolls in, connector re-registers) is the entire
DR procedure. No node-local state, no PVC, no DaemonSet — a clean
restart from any state.

If the tunnel itself is destroyed (a `tofu destroy` in
`terraform/cloudflare/`), the connector will log auth errors until a
new tunnel is created and its token uploaded to GSM. The container is
intentionally unaware of "which tunnel" — it follows the GSM-synced
token wherever it points.
