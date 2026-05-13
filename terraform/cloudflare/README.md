# terraform/cloudflare

Cloudflare-side records for the homelab's two public surfaces (ADR-0003
amendment + ADR-0006 amendment, both 2026-05-12). Owns the contents of
the CF-managed apex `jackhall.dev` zone:

- Apex CAA pinning issuance to Let's Encrypt (mirror of the pre-move
  Cloud DNS CAA — load-bearing for `*.lab.jackhall.dev` cert renewals).
- NS delegation records at `lab.jackhall.dev` pointing at the four
  `ns-cloud-d*.googledomains.com.` Cloud DNS nameservers. Keeps the
  `lab.jackhall.dev` zone exactly where it was.
- CAA exception at `projects.jackhall.dev` allowing pki.goog +
  letsencrypt.org (CF's contracted CAs for Universal SSL).
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
     - `Account:Cloudflare Tunnel:Edit` (the tunnel, its config, the token)
   - Zone resources: include → specific zone → `jackhall.dev`
   - Account resources: include → the account that owns the zone

   The Tunnel permission is account-scoped because tunnels are
   account-level objects in CF's data model; the rest are zone-scoped.

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

This root is **not** wired into the `terraform-plan.yml` /
`terraform-apply.yml` workflows yet — those only run for `gcp` and
`bootstrap` (see `terraform-plan.yml` → `candidates=(gcp bootstrap)`).
Adding `cloudflare` to that list is the work tracked in
[#131](https://github.com/RaptGroup/homelab/issues/131); for the
tracer-bullet PR it's operator-applied so the bootstrap order
(gcp → cloudflare → Squarespace flip) stays a manual ceremony rather
than a CI dance.

The CI path will need:

- An additional CI service account (or the apply SA's roles widened)
  with `roles/secretmanager.secretAccessor` on `cloudflare-api-token`
  and `roles/secretmanager.secretVersionAdder` on
  `cloudflare-tunnel-token` — the GSM access pattern is asymmetric
  for this root.
- A `terraform-apply-cloudflare.yml` workflow paired with a
  `cloudflare` GitHub deployment environment, mirroring the gcp
  shape from ADR-0004.

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
