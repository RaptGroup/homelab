# `kubernetes/apps/homepage/`

Cluster dashboard at `dashboard.lab.jackhall.dev`
([gethomepage.dev](https://gethomepage.dev/)). Auto-discovers other
addons via `gethomepage.dev/*` annotations on their `HTTPRoute`s
(PRD #4 / issue #14).

## Shape

```
kubernetes/apps/homepage/
├── application.yaml            # multi-source ArgoCD Application
├── helm-values.yaml            # jameswynn/homepage values
└── manifests/
    ├── external-secret.yaml    # widget credentials synced from GSM
    ├── gateway.yaml            # per-addon Cilium Gateway (wildcard cert)
    ├── httproute.yaml          # dashboard.lab.jackhall.dev → homepage Service
    └── reference-grant.yaml    # cross-namespace grant for the wildcard cert
```

## Widget credentials

Live-status widgets (currently AdGuard Home and ArgoCD) need credentials
to call each addon's API. Per the homelab convention, those credentials
live in GSM and are synced into a K8s Secret by ESO; nothing sensitive
lives in Git or in helm-values.

The three GSM containers are TF-managed in `terraform/gcp/main.tf`
(mirroring `talos-cluster-secrets`, `argocd-repo-ssh-key`, and
`adguard-home-admin`); only the *values* are uploaded out of band.

| GSM secret ID                | Purpose                                                     |
|------------------------------|-------------------------------------------------------------|
| `homepage-adguard-username`  | Plaintext AdGuard admin username                            |
| `homepage-adguard-password`  | Plaintext AdGuard admin password                            |
| `homepage-argocd-token`      | ArgoCD readonly account API token                           |

The `homepage-widget-credentials` `ExternalSecret` reads these and
projects them as `HOMEPAGE_VAR_ADGUARD_USERNAME`,
`HOMEPAGE_VAR_ADGUARD_PASSWORD`, and `HOMEPAGE_VAR_ARGOCD_TOKEN` env
vars on the Homepage Deployment, which the addon `HTTPRoute`
annotations reference as `{{HOMEPAGE_VAR_…}}` substitutions.

> **Plaintext vs. bcrypt — why two AdGuard secrets exist.**
> `adguard-home-admin` (consumed by `kubernetes/apps/adguard-home/`)
> stores `{username, password_hash}` where `password_hash` is the
> *bcrypt* of the admin password — that is what AdGuard's
> `AdGuardHome.yaml` requires. Homepage's AdGuard widget, however,
> authenticates against the live admin API and therefore needs the
> *plaintext* password. So `homepage-adguard-username` /
> `homepage-adguard-password` and the bcrypt half of
> `adguard-home-admin` must point at the **same actual credential** —
> if you rotate the AdGuard admin password, update both places or the
> dashboard widget will start returning auth errors.

## First-install flow

1. **Decide the AdGuard credential first.** `kubernetes/apps/adguard-home/`
   establishes the AdGuard admin user; the same plaintext password feeds
   step 3 below. See that addon's README for the bcrypt step.

2. **Mint the ArgoCD readonly-account token.** The `homepage` local
   account and its `role:readonly` RBAC binding are declared in
   `kubernetes/bootstrap/argocd/values.yaml` (`configs.cm.accounts.homepage`
   + `configs.rbac.policy.csv`), so the chart provisions both on every
   reconcile. The token itself is *not* in Git — it's minted out-of-band
   against the live cluster, since ArgoCD only stores the account
   declaration, not its credentials:

   ```sh
   argocd login argocd.lab.jackhall.dev
   argocd account generate-token --account homepage
   ```

   Sanity check first if the account doesn't appear in the UI's User
   Info page (e.g. right after a fresh bootstrap, before Argo has
   reconciled the chart):

   ```sh
   kubectl -n argocd get cm argocd-cm -o yaml | grep accounts.homepage
   # → accounts.homepage: apiKey
   # → accounts.homepage.enabled: "true"
   kubectl -n argocd get cm argocd-rbac-cm -o yaml | grep -A1 policy.csv
   # → policy.csv: |
   # →   g, homepage, role:readonly
   ```

   The `apiKey` capability (vs. `login`) is deliberate: the account can
   mint API tokens but cannot log in to the UI, bounding a leaked token
   to API reads only.

3. **Upload the three values to GSM.** The containers are pre-provisioned
   by `terraform/gcp/`:

   ```sh
   echo -n '<adguard-admin-username>' | gcloud secrets versions add \
     homepage-adguard-username \
     --project rockingham-homelab --data-file=-

   echo -n '<adguard-admin-password>' | gcloud secrets versions add \
     homepage-adguard-password \
     --project rockingham-homelab --data-file=-

   echo -n '<argocd-readonly-api-token>' | gcloud secrets versions add \
     homepage-argocd-token \
     --project rockingham-homelab --data-file=-
   ```

   `echo -n` matters — a trailing newline becomes part of the secret
   value and breaks API auth.

   ESO's `ClusterSecretStore gsm` syncs the values into the
   `homepage-widget-credentials` K8s Secret in the `homepage` namespace
   within `refreshInterval` (1h).

4. **Sync the Application.** ArgoCD picks `homepage` up from the root
   app-of-apps automatically. First sync brings up:

   - the `homepage` Deployment (envFrom mounts
     `homepage-widget-credentials` as `HOMEPAGE_VAR_*`),
   - the `homepage` Service on port 3000,
   - the per-namespace Gateway pinned to `192.168.1.203` (waits for the
     wildcard cert to be `Ready` in `cert-manager`),
   - the `HTTPRoute` for `dashboard.lab.jackhall.dev`.

5. **Add the per-host AdGuard rewrite.** AdGuard's seed wildcard
   (`*.lab.jackhall.dev → 192.168.1.201`) sends every unrouted lab
   hostname to the AdGuard admin-UI Gateway, which only knows the SNI
   `adguard.lab.jackhall.dev` and resets unrecognised handshakes. The
   per-addon convention (per `kubernetes/apps/adguard-home/manifests/gateway.yaml`)
   is to add an explicit per-host rewrite via the AdGuard UI as each
   addon comes online:

   - `https://adguard.lab.jackhall.dev` → **Filters → DNS rewrites → Add**
   - Domain: `dashboard.lab.jackhall.dev`
   - Answer: `192.168.1.203`

   These per-host rewrites are not in Git — they live in the
   `adguard-home-config` PVC. A cold restart of AdGuard re-seeds only
   the wildcard, so any per-host rewrites need to be re-added (DR-only
   concern; see the AdGuard README's disaster-recovery section).

6. **Verify.** Once the device is using AdGuard Home for resolution
   (per `kubernetes/apps/adguard-home/README.md`):

   ```sh
   curl -I https://dashboard.lab.jackhall.dev   # → HTTP/2 200, valid LE cert
   ```

   The dashboard should render with cards for itself, AdGuard, ArgoCD,
   and Hubble UI auto-discovered from their `HTTPRoute` annotations.

## Rotating credentials

To rotate the ArgoCD token: mint a new one against the live cluster,
then push it to GSM:

```sh
argocd login argocd.lab.jackhall.dev
argocd account generate-token --account homepage | tr -d '\n' | \
  gcloud secrets versions add homepage-argocd-token \
    --project rockingham-homelab --data-file=-
```

ESO picks up the new value on the next refresh and the Homepage pod's
env vars update on the next pod restart (chart `restartPods` helper or a
manual rollout). Old tokens stay valid until explicitly revoked via
`argocd account delete-token --account homepage <id>`.

To rotate the AdGuard password: rotate the plaintext password in
AdGuard's admin UI, recompute the bcrypt hash, then update **both**
GSM secrets in lockstep — `adguard-home-admin` (the JSON object with
the new bcrypt hash) and `homepage-adguard-password` (the new
plaintext). See `kubernetes/apps/adguard-home/README.md` for the
bcrypt recipe.

## Disaster recovery

Homepage is stateless — its config is rendered from `helm-values.yaml`
on every pod start and the dashboard's data comes from live cluster
queries plus the widget API calls. Re-running the first-install flow
(steps 2–6 above) is the entire DR procedure; the only state worth
keeping is the GSM credentials, which are already off-machine.
