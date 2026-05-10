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
    ├── gateway.yaml            # per-addon Cilium Gateway pinned to 192.168.1.201
    ├── httproute.yaml          # adguard.lab.jackhall.dev → admin Service
    └── reference-grant.yaml    # cross-namespace grant for the wildcard cert in cert-manager
```

The DNS Service is the public face on the LAN (`192.168.1.200`); the
admin UI is reached at `https://adguard.lab.jackhall.dev` once the
operator's device is using AdGuard Home itself for resolution.

## LB IP allocation

| Resource                                | IP               |
|-----------------------------------------|------------------|
| AdGuard Home DNS                        | `192.168.1.200`  |
| AdGuard Home admin-UI Gateway           | `192.168.1.201`  |

Both come out of the `.200`–`.230` Cilium pool from
`terraform/bootstrap`. The Gateway pin matters because AdGuard's seed
wildcard rewrite `*.lab.jackhall.dev → 192.168.1.201` needs a stable
target; without the pin, Cilium would hand out a different IP on
restart and the rewrite would point at nothing.

Following the convention `kubernetes/apps/hubble-ui/` established,
each addon brings its own per-namespace Gateway (`from: Same`) rather
than attaching to a shared one. Other addons therefore land on
different pool IPs and need a per-host rewrite added in the AdGuard
UI (`adguard.lab.jackhall.dev` → AdGuard admin → DNS settings →
DNS rewrites).

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
   - the Gateway on `.201` (waits for the wildcard cert to be `Ready`
     in `cert-manager`),
   - the `HTTPRoute` for `adguard.lab.jackhall.dev`.

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
- Wildcard rewrite `*.lab.jackhall.dev → 192.168.1.201`
- Default AdGuard DNS filter blocklist
- DHCP server explicitly disabled (out-of-scope per PRD #4)

Manual via the UI (not in Git):

- Per-host rewrites beyond the wildcard
- Additional blocklists / allowlists
- Client-specific filtering rules
- Schedule / safe-search / parental controls

If you need to re-seed (corrupt config, fresh PVC), delete the
`adguard-home-config` PVC and let Argo recreate the Deployment.

## Disaster recovery

Re-run the first-install flow above; the only state worth keeping is
the GSM credential (already off-machine) and any per-host rewrites the
operator added through the UI. The query log and stats live on the
`adguard-home-work` PVC and are accepted-loss in Phase 1 storage.
