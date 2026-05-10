# terraform/gcp

Provisions the GCP-side foundation for the Rockingham Homelab in a single
dedicated project (`rockingham-homelab` by default):

- The GCP project itself, with `deletion_policy = "DELETE"` so the whole
  footprint can be torn down as one unit.
- Cloud DNS managed zone for `lab.jackhall.dev`.
- Service account for cert-manager's DNS-01 solver (`roles/dns.admin`
  scoped to the zone, not the project).
- Service account for External Secrets Operator
  (`roles/secretmanager.secretAccessor` at the project level).
- GCS bucket `rockingham-homelab-tfstate` holding Terraform state for
  this and any future homelab roots.

State lives in `gs://rockingham-homelab-tfstate/terraform/gcp/` so local
and CI applies share the same state. The bucket is created by this same
root, so the very first apply on a fresh GCP account is local-state; see
"Bootstrap from scratch" below.

## Prerequisites

1. Authenticated `gcloud` ADC for Terraform to use:

   ```sh
   gcloud auth application-default login
   ```

2. A billing account ID — the project is created here but must be linked
   to billing or the Cloud DNS / Secret Manager APIs won't function. List
   your accounts:

   ```sh
   gcloud billing accounts list
   ```

3. The principal running `tofu apply` needs, at minimum:
   - `roles/resourcemanager.projectCreator` on the parent (org/folder) or
     no parent for personal accounts.
   - `roles/billing.user` on the billing account being linked.

## Inputs

Set these via a `terraform.tfvars` file (gitignored) or `-var` flags.
`terraform.tfvars` example:

```hcl
billing_account = "0X0X0X-0X0X0X-0X0X0X"
# org_id    = "123456789012"   # only if you have an org
# folder_id = "123456789012"   # mutually exclusive with org_id
```

`project_id` defaults to `rockingham-homelab`. Override only if that ID
is taken globally.

## APIs

`tofu apply` enables these on the new project:

- `cloudresourcemanager.googleapis.com`
- `iam.googleapis.com`
- `dns.googleapis.com`
- `secretmanager.googleapis.com`
- `storage.googleapis.com`

`disable_on_destroy = false` so a partial destroy doesn't disable APIs
that other tooling (gcloud, the console) might still need before the
project itself goes away.

## Run

```sh
cd terraform/gcp
tofu init       # configures the GCS backend
tofu plan
tofu apply
```

A second `tofu plan` immediately after a successful apply must show
`No changes`. If it doesn't, that's a bug — open an issue.

## Bootstrap from scratch

If the GCS state bucket doesn't yet exist (true on a clean GCP account,
or after `tofu destroy`), the first `tofu init` against the GCS backend
fails — there's nothing to read. Two-phase recipe:

1. Comment out the `backend "gcs"` block in `versions.tf`.
2. `tofu init && tofu apply` — uses local state, creates the project,
   APIs, DNS zone, SAs, and the state bucket itself.
3. Uncomment the backend block.
4. `tofu init -migrate-state` — copies the local state into the bucket.
5. Delete the local `terraform.tfstate*` files (gitignored anyway).

After that, every machine and CI runner that authenticates to GCP
shares the same state.

## Registrar handoff

After the first apply, grab the four NS records and paste them into the
registrar managing `jackhall.dev` as an `NS` record set for the `lab`
subdomain:

```sh
tofu output -json lab_zone_name_servers
```

Until those NS records propagate, ACME DNS-01 challenges will fail
because public resolvers can't reach the Cloud DNS zone.

## Teardown

`tofu destroy` won't work end-to-end while state lives in the bucket
that's about to be destroyed. The recipe is the bootstrap-from-scratch
flow in reverse:

1. `tofu init -migrate-state` after switching the backend back to local
   (or `tofu state pull > terraform.tfstate` then comment out the
   backend block).
2. `tofu destroy`.

Because the project is owned by Terraform with `deletion_policy = DELETE`,
this removes the project itself — taking the DNS zone, state bucket,
service accounts, and any GSM secrets created later with it. There is a
30-day soft-delete window during which `gcloud projects undelete
<project_id>` can recover it.

## Outputs

| Output                   | Used by                                                          |
|--------------------------|------------------------------------------------------------------|
| `lab_zone_name_servers`  | Operator → registrar (manual)                                    |
| `lab_zone_name`          | `terraform/bootstrap/` cert-manager `ClusterIssuer` config       |
| `cert_manager_sa_email`  | `terraform/bootstrap/` (creates the SA key K8s Secret)           |
| `eso_sa_email`           | `terraform/bootstrap/` (creates the SA key K8s Secret)           |
| `project_id`             | Anything that needs to qualify GSM secret refs                   |
| `project_number`         | Some GCP APIs / IAM bindings require the numeric form            |
| `tfstate_bucket`         | Other TF roots' backend blocks (hardcoded; this is just a sanity output) |
