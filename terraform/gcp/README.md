# terraform/gcp

Provisions the GCP-side foundation for the Rockingham Homelab in a single
dedicated project (`rockingham-homelab` by default):

- Cloud DNS managed zone for `lab.jackhall.dev`.
- Service account for cert-manager's DNS-01 solver (`roles/dns.admin`
  scoped to the zone, not the project).
- Service account for External Secrets Operator
  (`roles/secretmanager.secretAccessor` at the project level).

State is local. There is no GCS backend yet — the bucket would itself be
created here and the chicken-and-egg isn't worth solving for a single-
operator homelab.

## Prerequisites

1. A GCP project named `rockingham-homelab` (or whatever you set
   `project_id` to). This root does **not** create the project; create it
   manually first so this layer doesn't take responsibility for billing
   association or project deletion:

   ```sh
   gcloud projects create rockingham-homelab \
     --name="Rockingham Homelab"
   gcloud beta billing projects link rockingham-homelab \
     --billing-account=<YOUR_BILLING_ACCOUNT_ID>
   ```

2. Authenticated `gcloud` ADC for Terraform to use:

   ```sh
   gcloud auth application-default login
   gcloud config set project rockingham-homelab
   ```

## APIs

`terraform apply` enables these on the target project:

- `cloudresourcemanager.googleapis.com`
- `iam.googleapis.com`
- `dns.googleapis.com`
- `secretmanager.googleapis.com`

`disable_on_destroy = false` so a `terraform destroy` doesn't disable
APIs that other tooling (gcloud, the console) might still need.

## Run

```sh
cd terraform/gcp
tofu init
tofu plan
tofu apply
```

A second `tofu plan` immediately after a successful apply must show
`No changes`. If it doesn't, that's a bug — open an issue.

## Registrar handoff

After the first apply, grab the four NS records and paste them into the
registrar managing `jackhall.dev` as an `NS` record set for the `lab`
subdomain:

```sh
tofu output -json lab_zone_name_servers
```

Until those NS records propagate, ACME DNS-01 challenges will fail
because public resolvers can't reach the Cloud DNS zone.

## Outputs

| Output                   | Used by                                                          |
|--------------------------|------------------------------------------------------------------|
| `lab_zone_name_servers`  | Operator → registrar (manual)                                    |
| `lab_zone_name`          | `terraform/bootstrap/` cert-manager `ClusterIssuer` config       |
| `cert_manager_sa_email`  | `terraform/bootstrap/` (creates the SA key K8s Secret)           |
| `eso_sa_email`           | `terraform/bootstrap/` (creates the SA key K8s Secret)           |
| `project_id`             | Anything that needs to qualify GSM secret refs                   |
