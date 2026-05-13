# `kubernetes/apps/adguard-home/`

LAN DNS resolver and ad-blocker, fronting `*.lab.jackhall.dev` for any
device on the LAN with `192.168.1.200` set as its DNS server. First
ArgoCD-managed addon (PRD #4 / issue #13).

## Shape

```
kubernetes/apps/adguard-home/
├── application.yaml            # multi-source ArgoCD Application
├── helm-values.yaml            # bjw-s/app-template values (Deployment + admin Service + PVCs)
└── manifests/
    ├── namespace.yaml          # adguard-home Namespace (explicit, matches hubble-ui)
    ├── dns-service.yaml        # LoadBalancer Service pinned to 192.168.1.200 (UDP/TCP 53)
    ├── external-secret.yaml    # admin user/bcrypt-hash synced from GSM
    ├── seed-configmap.yaml     # AdGuardHome.yaml template rendered by the init container
    └── httproute.yaml          # adguard.lab.jackhall.dev → admin Service (attaches to the central `lab` Gateway)
```

The DNS Service is the public face on the LAN (`192.168.1.200`); the
admin UI is reached at `https://adguard.lab.jackhall.dev` once the
operator's device is using AdGuard Home itself for resolution.
TLS termination + routing happens at the central `lab` Gateway
defined in `kubernetes/apps/lab-gateway/`; AdGuard's HTTPRoute
attaches cross-namespace via `parentRefs.namespace: gateway-system`
(issue #48).

## LB IP allocation

| Resource                                | IP               |
|-----------------------------------------|------------------|
| AdGuard Home DNS                        | `192.168.1.200`  |
| Central `lab` Gateway                   | `192.168.1.201`  |

Both come out of the `.200`–`.230` Cilium pool from
`terraform/bootstrap`. The Gateway pin matters because AdGuard's seed
wildcard rewrite `*.lab.jackhall.dev → 192.168.1.201` needs a stable
target; with the central Gateway claiming `.201`, every addon's
hostname resolves through that single entry without per-host
rewrites in the AdGuard UI.

## Source IP and per-client features

The DNS Service uses `externalTrafficPolicy: Cluster` (default), not
`Local`. ETP=Local broke LAN reachability because Cilium's L2 leader
election picked announcer nodes that didn't host the AdGuard pod, so
packets to `192.168.1.200` were dropped (see issue #41 for the full
diagnosis).

The trade-off: AdGuard Home sees the source IP of whichever worker
node forwarded the query via eBPF NAT, not the actual LAN client.
Anything in the AdGuard UI that keys off client IP — Top clients,
per-client filtering rules, per-client query log, custom blocklists
scoped to a device — therefore can't distinguish LAN devices.

Use **ClientIDs** instead when per-client behavior matters: configure
the device to query AdGuard over DoH (`https://192.168.1.200/dns-query/<client-id>`),
DoT (`<client-id>.dns.lab.jackhall.dev`), or by setting a PTR record
the device's IP resolves to. ClientIDs identify clients regardless
of source IP. Aggregate stats (total queries, blocked counts, top
domains) are unaffected.

## First-install flow

1. **Generate the admin bcrypt hash.** AdGuard Home stores the password
   as bcrypt in `AdGuardHome.yaml`. Hash a chosen password locally:

   ```sh
   htpasswd -nbB admin '<password>' | cut -d: -f2
   ```

   Save the plaintext password in a password manager — neither this
   repo nor GSM holds it.

2. **Upload the JSON credential to GSM.** The container is
   pre-provisioned by `terraform/gcp/`:

   ```sh
   echo '{"username":"admin","password_hash":"<hash-from-step-1>"}' \
     | gcloud secrets versions add adguard-home-admin \
         --project rockingham-homelab --data-file=-
   ```

   ESO's `ClusterSecretStore gsm` syncs the value into the
   `adguard-home-admin` K8s Secret in this namespace within
   `refreshInterval` (1h).

3. **Sync the Application.** ArgoCD picks `adguard-home` up from the
   root app-of-apps automatically. First sync brings up:

   - the `adguard-home` Deployment (init container seeds
     `AdGuardHome.yaml` from `seed-configmap.yaml` plus the synced
     credential),
   - the admin UI Service,
   - the DNS LB Service on `.200`,
   - the `HTTPRoute` for `adguard.lab.jackhall.dev`, attaching to the
     central `lab` Gateway in `gateway-system` (the Gateway itself is
     deployed by `kubernetes/apps/lab-gateway/`).

4. **Point a device at `192.168.1.200`.** macOS / iOS / Windows / Linux
   all expose a manual DNS field; consult per-OS recipes (TBD: PRD US
   29).

5. **Verify resolution + admin UI.** From the configured device:

   ```sh
   dig +short adguard.lab.jackhall.dev    # → 192.168.1.201
   curl -I https://adguard.lab.jackhall.dev   # → HTTP/2 200, valid LE cert
   ```

   Log in to the UI with the credentials uploaded in step 2.

## What the seed config sets, what the operator owns

The init container only writes `AdGuardHome.yaml` if the file is
missing on the config PVC. After that, AdGuard Home owns the file —
every UI save rewrites it in place. The seed therefore only matters on
a fresh PVC (first install or disaster recovery).

Seeded:

- Admin user with the bcrypt hash from GSM
- Admin UI on `0.0.0.0:80`, DNS on `0.0.0.0:53`
- DoH upstreams (Cloudflare + Google) with plaintext bootstrap
- Wildcard rewrite `*.lab.jackhall.dev → 192.168.1.201` (the central
  `lab` Gateway). `lab.jackhall.dev` is LAN-only — one entry covers
  every addon fronted by the central `lab` Gateway, no per-host
  rewrites needed as new gateway-fronted addons come online.
- Per-node A records for the Talos control-plane (`cp-0{1,2,3}`),
  workers (`worker-0{1,2,3}`), and the control-plane VIP
  (`rockingham`) under `lab.jackhall.dev`. Specific names beat the
  wildcard, so `talosctl --nodes <hostname>` / `ssh` / `ping` work by
  hostname (issue #135).
- Default AdGuard DNS filter blocklist
- DHCP server explicitly disabled (out-of-scope per PRD #4)

Manual via the UI (not in Git):

- Additional blocklists / allowlists
- Client-specific filtering rules
- Schedule / safe-search / parental controls

If you need to re-seed (corrupt config, fresh PVC), delete the
`adguard-home-config` PVC and let Argo recreate the Deployment.

## Disaster recovery

Re-run the first-install flow above; the only state worth keeping is
the GSM credential (already off-machine). The query log and stats
live on the `adguard-home-work` PVC and are accepted-loss in Phase 1
storage. The seed wildcard rewrite covers every addon, so there are
no per-host rewrite entries to restore.
