---
title: External Secrets Operator
description: Syncs Google Secret Manager values into Kubernetes Secrets via the cluster-wide ClusterSecretStore named gsm.
---

[External Secrets Operator](https://external-secrets.io/) (ESO) is the
bridge between Google Secret Manager and the cluster's Kubernetes
`Secret`s. Every credential the lab needs at runtime — the cert-manager
DNS-01 service-account key, the ArgoCD repo SSH deploy key, the AdGuard
admin bcrypt hash, the GitHub App private keys for the
[ARC runners](/homelab/applications/arc/) — lives in GSM and is
materialised into a `Secret` by ESO on demand.

## Why Terraform installs it

ESO needs credentials to *talk to* GSM, but storing those credentials in
GSM is the chicken-and-egg this whole layer exists to solve. The fix is
a single bootstrap: Terraform mints a service-account key for the ESO
SA, writes it to one Kubernetes `Secret` (the `gcp-sm-credentials`
Secret in the `external-secrets` namespace), and stops there.
**Every other credential in the cluster flows through ESO from GSM** —
this is the only Kubernetes `Secret` Terraform creates directly, and
the rule is load-bearing for the
[ADR-0001](https://github.com/RaptGroup/homelab/blob/main/docs/adr/0001-iac-strategy.md)
boundary between Terraform and ArgoCD.

ESO also has to be up before cert-manager's `ClusterIssuer`, because
the DNS-01 SA key is itself sourced from GSM. That ordering is enforced
by `depends_on` in `terraform/bootstrap/`. See
[Platform / Bootstrap order](/homelab/platform/#bootstrap-order).

## Where the config lives

Everything lives in
[`terraform/bootstrap/external-secrets.tf`](https://github.com/RaptGroup/homelab/blob/main/terraform/bootstrap/external-secrets.tf):

- The `external-secrets` namespace and Helm release (chart version
  `0.10.7`, CRDs enabled).
- The bootstrap SA key — `google_service_account_key.eso` minted by
  Terraform, written into `Secret/gcp-sm-credentials` in the
  `external-secrets` namespace.
- The `ClusterSecretStore/gsm` that every `ExternalSecret` in the
  cluster references by name.

The GSM-side resources (the `eso-sm-reader` service account, the GSM
secrets themselves, the IAM bindings that let the SA read them) live in
`terraform/gcp/` and are exposed to `terraform/bootstrap/` via the
`eso_sa_email` remote-state output.

## Operational entry points

| Resource | Purpose |
|---|---|
| `ClusterSecretStore/gsm` | The single store every `ExternalSecret` references. Backed by GCP Secret Manager in the `rockingham-homelab` project, authenticated via the bootstrap SA key. |
| `Secret/gcp-sm-credentials` (in `external-secrets`) | The bootstrap SA key. The only K8s `Secret` Terraform writes directly. |
| `kubectl get clustersecretstore gsm` | Should report `STATUS=Valid`. `Invalid` is the smoke-test signal that the SA key is malformed or missing the `roles/secretmanager.secretAccessor` binding. |

The smoke test in `just smoke` asserts `Ready=True` on this
`ClusterSecretStore` precisely because every other addon's runtime
credentials transit through it; if `gsm` is unhealthy, the rest of the
cluster degrades quietly.

## How addons consume secrets

Every addon that needs a credential ships its own `ExternalSecret`
manifest under `kubernetes/apps/<name>/`. The shape:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: <descriptive>
  namespace: <addon-namespace>
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: gsm
  target:
    name: <k8s-secret-name>
    creationPolicy: Owner
  data:
    - secretKey: <key-in-target-secret>
      remoteRef:
        key: <gsm-secret-id>
```

ESO polls GSM every `refreshInterval` and writes/updates the target
`Secret`. Rotating a credential is a one-step GSM update — the next
sync materialises the new value, and the consuming addon picks it up
on its next pod restart (or sooner, if the addon watches the `Secret`).

Current consumers in the lab:

- **cert-manager** — `ExternalSecret/cert-manager-dns01-key` →
  `Secret/cert-manager-dns01-key` (the DNS-01 SA JSON, read by the
  `letsencrypt-dns01` `ClusterIssuer`).
- **ArgoCD** — `ExternalSecret/argocd-repo-homelab` →
  `Secret/argocd-repo-homelab` labelled
  `argocd.argoproj.io/secret-type: repository`. ArgoCD matches
  Applications to credentials by repo URL automatically; this is how
  the root app-of-apps clones the homelab repo over SSH.
- **AdGuard Home, ARC runners, …** — under
  [`kubernetes/apps/`](https://github.com/RaptGroup/homelab/tree/main/kubernetes/apps).

## Why ESO over `Secret`s in git

A few alternatives were considered and rejected:

- **Plain `Secret`s in git, base64-encoded.** Storing credentials in
  the repo defeats the point of having a secret manager and rules out
  making any of the docs site or repo public.
- **Sealed Secrets / SOPS.** Keeps the data in git, encrypted, but
  rotation still means a PR per credential and decryption keys still
  have to live somewhere. ESO + GSM puts that somewhere in a
  purpose-built service the operator already runs for the GCP side.
- **HashiCorp Vault.** Strictly more capable, strictly more operational
  cost. The lab has no auditing, leasing, or dynamic-credential
  requirements that justify it.

## More

[`terraform/bootstrap/external-secrets.tf`](https://github.com/RaptGroup/homelab/blob/main/terraform/bootstrap/external-secrets.tf)
holds the full Helm release and `ClusterSecretStore` spec. The
operator-facing recovery procedure for a malformed SA key is in
[`terraform/bootstrap/README.md`](https://github.com/RaptGroup/homelab/blob/main/terraform/bootstrap/README.md#recovery-from-a-partial-apply).
