# terraform/cloudflare

Cloudflare-side records for the homelab's two public surfaces (ADR-0003
+ ADR-0006, both amended 2026-05-12 and ADR-0006 amended again
2026-05-13). Owns the contents of the CF-managed apex `jackhall.dev`
zone:

- Apex CAA pinning issuance to Let's Encrypt (mirror of the pre-move
  Cloud DNS CAA — load-bearing for `*.lab.jackhall.dev` cert renewals).
- NS delegation records at `lab.jackhall.dev` pointing at the four
  `ns-cloud-d*.googledomains.com.` Cloud DNS nameservers. Keeps the
  `lab.jackhall.dev` zone exactly where it was.
- CAA exception at `projects.jackhall.dev` allowing pki.goog +
  letsencrypt.org — gates the ACM-issued wildcard below to Google
  Trust Services for `projects.*` while leaving the apex
  `letsencrypt.org` pin intact for `*.lab.jackhall.dev`.
- ACM-issued advanced certificate pack covering
  `projects.jackhall.dev` + `*.projects.jackhall.dev` (Google CA, TXT
  validation, 90-day validity, CF-auto-renewed). Universal SSL on the
  Free plan can't serve two-label hostnames, so the preview surface
  needs an explicitly-listed multi-SAN cert. See ADR-0006's
  2026-05-13 amendment.
- Named cloudflared tunnel + its ingress config + the wildcard CNAME
  for the public preview surface.
- GSM version write of the per-tunnel connector token for the
  in-cluster `cloudflared` addon to sync.

The apex zone itself is **not** TF-owned — Cloudflare's permission
model requires Account:Edit to create new zones, which would widen the
API token beyond the Zone-scoped + Account-Tunnel-Edit shape we mint.
The one-time dashboard step to add the zone is the only manual piece;
everything inside the zone is TF-managed.

State lives in `gs://rockingham-homelab-tfstate/terraform/cloudflare/` —
same bucket as `terraform/gcp/` and `terraform/bootstrap/`, different
prefix.

## Why the apex, not a subzone

ADR-0006 originally framed `projects.jackhall.dev` as a separate
CF-managed subdomain zone NS-delegated from the Cloud DNS apex.
Implementing that revealed that CF's subdomain-zone path on every plan
requires the parent zone to be on CF authoritative DNS too. The only
path that keeps the apex elsewhere is CF Business plan ($200/mo, via
Partial CNAME Setup) — which inverts the cost-for-parity math that
chose CF Tunnel over a GCP-native bastion in the first place.

So the apex moves to CF; `lab.jackhall.dev` stays on Cloud DNS via an
NS delegation from the CF apex. See ADR-0003's 2026-05-12 amendment
for the full reasoning.

## Prerequisites

This root depends on `terraform/gcp/` having applied at least once, so:

- The GSM containers `cloudflare-api-token` and `cloudflare-tunnel-token`
  exist (value of `cloudflare-api-token` uploaded out of band, see below).
- The `terraform/gcp` remote state holds `project_id`, `apex_dns_name`,
  `lab_zone_name_servers`, and the two GSM secret IDs as outputs.

## Bootstrap (one-time)

1. **Create a Cloudflare account** if you don't have one, and add the
   **apex `jackhall.dev`** in the CF dashboard (Add → Connect a
   domain). When prompted for "How should DNS records be imported?"
   either choice is fine — this root publishes the records that
   matter regardless. Cloudflare will assign two nameservers; note
   them but you don't need to act on them yet (the registrar flip
   happens after this root applies, not before).

2. **Mint a scoped API token** at https://dash.cloudflare.com/profile/api-tokens:

   - Permissions:
     - `Zone:Zone:Edit` (read+edit zone metadata)
     - `Zone:DNS:Edit` (CAA, NS, CNAME)
     - `Zone:SSL and Certificates:Edit` (the ACM advanced cert pack)
     - `Account:Cloudflare Tunnel:Edit` (the tunnel, its config, the token)
   - Zone resources: include → specific zone → `jackhall.dev`
   - Account resources: include → the account that owns the zone

   The Tunnel permission is account-scoped because tunnels are
   account-level objects in CF's data model; the rest are zone-scoped.
   `SSL and Certificates` was added in ADR-0006's 2026-05-13 amendment;
   widen an existing token in-place rather than minting a new one, so
   the GSM-stored value doesn't have to rotate.

3. **Upload the token to GSM:**

   ```sh
   echo -n '<cf-api-token>' \
     | gcloud secrets versions add cloudflare-api-token \
         --project rockingham-homelab --data-file=-
   ```

4. **Get the Cloudflare account ID** (top-right of the dashboard, or
   any zone's Overview pane → "Account ID" in the right sidebar) and
   put it in `terraform.tfvars`:

   ```hcl
   cloudflare_account_id = "0123456789abcdef0123456789abcdef"
   ```

   The account ID is not sensitive — it's a public identifier in API
   responses — but it's not in the repo because every CF account is
   different.

## Run

```sh
cd terraform/cloudflare
tofu init
tofu plan
tofu apply
```

A second `tofu plan` immediately after a successful apply must show
`No changes`.

## Pre-flip verification (DO NOT skip)

Before pointing Squarespace at the CF nameservers, query the CF zone
**directly** to confirm every expected record is present. This is the
load-bearing safety check — if CF activates the zone with missing
records, the lab path can break mid-renewal.

```sh
# Grab one of the CF nameservers.
CF_NS=$(tofu output -json apex_zone_nameservers | jq -r '.[0]')

# 1. Apex CAA mirrors Cloud DNS verbatim. Must include both issue and
#    issuewild for letsencrypt.org. Empty here = cert renewal will fail
#    post-flip.
dig +short CAA jackhall.dev @"$CF_NS"
# Expect:
#   0 issue "letsencrypt.org"
#   0 issuewild "letsencrypt.org"

# 2. Lab subzone NS delegation. Must list all four ns-cloud-d* values.
#    Missing here = LE validator can't reach _acme-challenge TXT records.
dig +short NS lab.jackhall.dev @"$CF_NS"
# Expect:
#   ns-cloud-d1.googledomains.com.
#   ns-cloud-d2.googledomains.com.
#   ns-cloud-d3.googledomains.com.
#   ns-cloud-d4.googledomains.com.

# 3. Projects CAA exception.
dig +short CAA projects.jackhall.dev @"$CF_NS"
# Expect:
#   0 issue "letsencrypt.org"
#   0 issue "pki.goog"
#   0 issuewild "letsencrypt.org"
#   0 issuewild "pki.goog"

# 4. Wildcard CNAME for the tunnel.
dig +short CNAME canary.projects.jackhall.dev @"$CF_NS"
# Expect:
#   <some-uuid>.cfargotunnel.com.

# 5. Apex SOA from CF.
dig +short SOA jackhall.dev @"$CF_NS"
# Expect:
#   <ns>.cloudflare.com. dns.cloudflare.com. ...

# 6. ACM cert pack issued and serving from CF's edge for a two-label
#    name under projects.*. CF won't terminate TLS without this; before
#    issuance completes you'll see `alert handshake failure` here.
echo | openssl s_client -connect canary.projects.jackhall.dev:443 \
  -servername canary.projects.jackhall.dev 2>/dev/null \
  | openssl x509 -noout -subject -issuer
# Expect:
#   subject=CN = *.projects.jackhall.dev      (or DNS SAN list including it)
#   issuer=C = US, O = Google Trust Services, CN = WE1 (or similar GTS leaf)
```

If any of these are empty or unexpected, **do not flip Squarespace**.
Re-apply this root, recheck, or open an issue.

## Flip Squarespace

Once the pre-flip checks pass:

1. Sign in to Squarespace's domain management.
2. Find the nameserver / DNS settings for `jackhall.dev`.
3. Replace the current nameservers (`ns-cloud-a{1,2,3,4}.googledomains.com.`)
   with the two CF values:

   ```sh
   tofu output -json apex_zone_nameservers
   # e.g. ["amir.ns.cloudflare.com","celeste.ns.cloudflare.com"]
   ```

4. Save. Squarespace's UI may warn about a 24-48 hour propagation window —
   typical TTL on registrar NS records.
5. Watch the CF dashboard's "Pending Nameserver Update" status flip to
   "Active" — usually minutes, can be hours.

## Post-flip verification

```sh
# 1. Public resolvers see CF NS for the apex.
dig +short NS jackhall.dev @8.8.8.8
# Expect: the two CF nameservers (matching apex_zone_nameservers output).

# 2. Lab path still works end-to-end (this is the regression check).
dig +short NS lab.jackhall.dev @8.8.8.8
# Expect: ns-cloud-d* (delegation chain working through CF apex).

# 3. From a LAN device with AdGuard DNS:
curl -I https://dashboard.lab.jackhall.dev
# Expect: 200 OK with valid LE cert, just like before the flip.

# 4. cert-manager wildcard cert renewable. Force a renewal cycle and
#    watch for failure. The next natural renewal will exercise this
#    automatically, but proactively confirming closes the loop.
kubectl -n cert-manager annotate certificate wildcard-lab-jackhall-dev \
  cert-manager.io/force-renew="$(date +%s)" --overwrite
kubectl -n cert-manager get certificate wildcard-lab-jackhall-dev \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
# Expect: True within ~2 minutes.
```

## What the cloudflared addon needs

The cluster-side `kubernetes/apps/cloudflared/` Application uses the
GSM `cloudflare-tunnel-token` secret container that this root writes
versions to. The ExternalSecret there refreshes from GSM hourly — a
`terraform taint cloudflare_zero_trust_tunnel_cloudflared.projects`
followed by `tofu apply` rotates the token; the cloudflared pod picks
it up within an hour, or sooner with a forced refresh
(`kubectl -n cloudflared annotate externalsecret cloudflared-tunnel-token
force-sync=$(date +%s) --overwrite`).

## CI

This root is wired into CI per [#131](https://github.com/RaptGroup/homelab/issues/131)
and the ADR-0004 amendment (2026-05-13). Two workflow paths:

- **Plan on PR.** `.github/workflows/terraform-plan.yml` is matrix-
  based across all three roots; a PR that touches
  `terraform/cloudflare/**` produces a sticky PR comment with the
  CF-root plan output, alongside any gcp/bootstrap plans for the
  same PR. Plan runs as `tf-ci-plan`, widened with a per-secret
  `roles/secretmanager.secretAccessor` on `cloudflare-api-token`
  so the Cloudflare provider can be instantiated at plan time.
- **Apply on merge to main.** `.github/workflows/terraform-apply-cloudflare.yml`
  fires on `push: main` with path filter on
  `terraform/cloudflare/**`. The `apply` job declares
  `environment: cloudflare` and runs as `tf-ci-apply-cloudflare` —
  a dedicated SA with narrow secret-scoped + bucket-scoped GCP
  permissions (no `roles/owner`). GitHub holds the job in
  `Waiting` until the repo owner approves the deployment in the
  UI. Same `apply tfplan` artifact handoff as gcp's apply
  workflow, so the bytes applied are the bytes reviewed.

The bootstrap order is unchanged from the tracer-bullet shape:
operator runs `tofu apply` locally once to land the CF apex zone
records, then flips Squarespace's nameservers. Subsequent applies
go through CI.

### CI repository configuration

Beyond the gcp-root variables and secret (see `terraform/gcp/README.md`),
the cloudflare CI path needs:

| Setting                       | Type     | Value                                                                       |
|-------------------------------|----------|-----------------------------------------------------------------------------|
| `GCP_APPLY_SA_CLOUDFLARE`     | Variable | `tofu -chdir=terraform/gcp output -raw ci_apply_cloudflare_service_account_email` |
| `CLOUDFLARE_ACCOUNT_ID`       | Variable | Same value as `terraform.tfvars` here (not sensitive — public ID)           |

And the **`cloudflare` deployment environment** in the GitHub UI
(Settings → Environments → New environment, name `cloudflare`):

- Deployment branch restriction: `Selected branches and tags` → add `main`.
- Required reviewer: repo owner.

Without the environment, the apply job queues indefinitely. Without
the deployment-branch rule, a workflow run on a feature branch
could attempt to opt into the environment.

### Bootstrap: enabling CI apply on a fresh project

`tf-ci-apply-cloudflare` is provisioned by `terraform/gcp/`, so the
first CI-ready apply requires those bindings to be live first:

1. Operator runs `tofu apply` against `terraform/gcp/` (locally or
   via the gcp apply workflow) — this creates the
   `tf-ci-apply-cloudflare` SA, its three IAM bindings, and the
   env-scoped WIF binding keyed on `attribute.environment/cloudflare`.
2. Operator copies the new output value into the GitHub repo
   variable: `GCP_APPLY_SA_CLOUDFLARE = $(tofu -chdir=terraform/gcp output -raw ci_apply_cloudflare_service_account_email)`.
3. Operator sets the `CLOUDFLARE_ACCOUNT_ID` repo variable to the
   same value as `terraform.tfvars` here.
4. Operator creates the `cloudflare` GitHub deployment environment
   in the UI with the protection rules above.
5. From this point on, merging a PR that touches
   `terraform/cloudflare/**` triggers
   `terraform-apply-cloudflare.yml`: it re-plans against current
   state, surfaces the diff in the job log, pauses for environment
   approval if there is a diff, and applies the approved plan.

## Teardown

`tofu destroy` here removes:

- All DNS records this root manages inside the CF apex zone (apex
  CAA, lab NS delegation, projects CAA, wildcard CNAME).
- The tunnel itself (active connectors will disconnect; cloudflared
  pods will log auth errors until uninstalled).
- The latest GSM secret version of the tunnel token (the container
  itself is owned by `terraform/gcp/`).

The apex zone resource in the Cloudflare dashboard is **not**
destroyed — it was created out of band and is also not TF-managed
here. To fully remove, do the dashboard step in reverse (CF →
zone → Configuration → Delete zone) after `tofu destroy` lands, and
flip Squarespace back to Cloud DNS NS (`ns-cloud-a*`) before deleting
the zone or the lab path goes dark.
