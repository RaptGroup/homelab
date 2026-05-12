# terraform/cloudflare

Cloudflare-side resources for the public preview-env path (ADR-0006).
Owns the projects.jackhall.dev zone records (CAA, the wildcard CNAME),
the named Cloudflare Tunnel that fronts the in-cluster `projects` Cilium
Gateway, the tunnel's ingress config, and the GSM version write of the
per-tunnel connector token.

The zone resource itself is **not** TF-owned — Cloudflare's permission
model requires Account:Edit to create new zones, which would widen the
API token beyond the Zone:Edit + Tunnel:Edit + DNS:Edit scope the
operator mints for routine ops. The one-time dashboard step to add the
zone is the only manual piece; everything inside the zone is TF-managed.

State lives in `gs://rockingham-homelab-tfstate/terraform/cloudflare/` —
same bucket as `terraform/gcp/` (and `terraform/bootstrap/`), different
prefix.

## Prerequisites

This root depends on `terraform/gcp/` having applied at least once, so:

- The GSM containers `cloudflare-api-token` and `cloudflare-tunnel-token`
  exist and the API token value has been uploaded.
- The `terraform/gcp` remote state holds the project ID and the two GSM
  secret IDs as outputs.

## Bootstrap (one-time)

1. **Create a Cloudflare account** if you don't have one, and add the
   `projects.jackhall.dev` zone in the CF dashboard (Websites → Add a
   site). Cloudflare will assign two nameservers — note them; the
   delegation at the apex is added in `terraform/gcp/` after this root
   applies.

2. **Mint a scoped API token** at https://dash.cloudflare.com/profile/api-tokens:

   - Permissions:
     - `Zone:Zone:Edit` (read+edit the zone itself)
     - `Zone:DNS:Edit` (CAA, CNAME)
     - `Account:Cloudflare Tunnel:Edit` (the tunnel, its config, the token)
   - Zone resources: include → specific zone → `projects.jackhall.dev`
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
   `cloudflare_zones` in any zone's overview pane) and put it in
   `terraform.tfvars`:

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

## Finish the apex delegation

After the first successful apply here, copy the assigned nameservers
into the apex zone:

```sh
tofu output -raw projects_zone_nameservers_json
# e.g. ["amir.ns.cloudflare.com","celeste.ns.cloudflare.com"]
```

Paste that array into `terraform/gcp/terraform.tfvars`:

```hcl
projects_zone_nameservers = ["amir.ns.cloudflare.com", "celeste.ns.cloudflare.com"]
```

Then re-apply `terraform/gcp/`. The apex zone publishes the NS records
delegating `projects.jackhall.dev` to Cloudflare; public resolvers see
it within minutes. Verify with:

```sh
dig +short NS projects.jackhall.dev @8.8.8.8
dig +short CAA projects.jackhall.dev @8.8.8.8
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
Adding `cloudflare` to that list is a follow-up; for the tracer-bullet
PR it's operator-applied so the bootstrap order (gcp → cloudflare →
gcp re-apply) stays a manual ceremony rather than a CI dance.

The CI path will need:

- An additional CI service account (or the apply SA's roles widened)
  with `roles/secretmanager.secretAccessor` on the API token and
  `roles/secretmanager.secretVersionAdder` on the tunnel token —
  the GSM access pattern is asymmetric for this root.
- A `terraform-apply-cloudflare.yml` workflow paired with a
  `cloudflare` GitHub deployment environment, mirroring the gcp
  shape from ADR-0004.

## Teardown

`tofu destroy` here removes:

- All DNS records (CAA, wildcard CNAME).
- The tunnel itself (active connectors will disconnect; cloudflared
  pods will log auth errors until uninstalled).
- The latest GSM secret version of the tunnel token (the container
  itself is owned by `terraform/gcp/`).

The zone resource in the Cloudflare dashboard is **not** destroyed —
it was created out of band and is also not TF-managed here. To remove
it fully, do the dashboard step in reverse (Cloudflare → site →
Configuration → Delete site) after `tofu destroy` lands.
