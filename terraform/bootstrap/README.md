# terraform/bootstrap

Brings the Talos cluster from "kubeconfig works, nothing installed" to
"ArgoCD reconciles `kubernetes/apps/`" in a single `tofu apply`.

After this root has been applied successfully:

- Adding a new addon = drop a `kubernetes/apps/<name>/` directory and push.
  Terraform is not touched.
- Bumping ArgoCD itself = edit `kubernetes/bootstrap/argocd/values.yaml`
  or the chart version in `kubernetes/bootstrap/argocd/application.yaml.tftpl`
  and push. Argo upgrades itself.
- Bumping bootstrap-managed addons (Cilium, cert-manager, ESO,
  local-path-provisioner) = bump the corresponding `*_chart_version`
  variable in this root and re-apply.

## Bootstrap order

Components are installed in this exact order, enforced via `depends_on`
between resources. Re-running on a fresh cluster cannot apply pieces in
the wrong order.

1. **Gateway API CRDs** — `standard-install.yaml` from
   `kubernetes-sigs/gateway-api`. Applied first so Cilium's operator
   finds the CRDs at startup and registers its `GatewayClass`.
2. **Cilium** — Helm chart with the Talos values pinned in `cilium.tf`,
   plus a `CiliumLoadBalancerIPPool` covering `192.168.1.200`–`230` and
   a `CiliumL2AnnouncementPolicy` that excludes control-plane nodes.
3. **cert-manager** — Helm chart. The `ClusterIssuer` and wildcard
   `Certificate` are created later (after step 4) so the DNS-01 SA key
   can be sourced through ESO instead of written by Terraform.
4. **External Secrets Operator** — Helm chart and a `ClusterSecretStore`
   named `gsm`. The store authenticates to GCP via cluster→GCP
   Workload Identity Federation (the same pool #139 created for the
   AR-pull path; see [ADR-0007](../../docs/adr/0007-eso-bootstrap-auth-via-cluster-wif.md)) —
   Terraform creates no `Secret` directly. Once ESO is up, the
   cert-manager `ExternalSecret` syncs the DNS-01 key, then the
   `ClusterIssuer` and wildcard `Certificate` come up.
5. **local-path-provisioner** — applied from the upstream
   `deploy/local-path-storage.yaml`, then annotated as the cluster's
   default `StorageClass`.
6. **ArgoCD** — Helm chart, plus a self-managed `Application` and the
   root app-of-apps `Application` watching `kubernetes/apps/`.

## Prerequisites

- **Talos cluster reachable.** The kubeconfig under
  `talos/_out/kubeconfig` (default for `var.kubeconfig_path`) talks to
  the control-plane VIP. `kubectl get nodes` should list every node
  `Ready` (Cilium will mark them `Ready` after install if the kubelet
  was waiting on a CNI).
- **`terraform/gcp/` already applied.** This root reads its outputs
  (`project_id`, `lab_zone_name`, `cert_manager_sa_email`, `eso_sa_email`)
  out of the GCS-backed remote state.
- **NS records delegated.** The four nameservers from
  `tofu output -json lab_zone_name_servers` must be live at the
  registrar for `lab.jackhall.dev`. Without delegation, ACME DNS-01
  challenges fail because public resolvers can't reach the Cloud DNS
  zone.
- **Application-default credentials.** `gcloud auth
  application-default login` so the `google` provider can read project
  state and so the GCS backend can read TF state.
- **OIDC discovery document and JWKS published.** ESO authenticates to
  GCP via Workload Identity Federation against the cluster's own OIDC
  issuer (see [ADR-0007](../../docs/adr/0007-eso-bootstrap-auth-via-cluster-wif.md)).
  Before `tofu apply` in this root, the cluster's
  `/.well-known/openid-configuration` and `/openid/v1/jwks` must be
  reachable at the public issuer URL (Cloud DNS → GCS bucket; see #139
  for the recipe). On a brand-new cluster the order is
  `terraform/talos/` → JWKS upload → `terraform/gcp/` → this root.
  Skip this step and ESO's `ClusterSecretStore gsm` reports
  `Ready=False` with a token-exchange error after apply.

## Inputs

Every variable has a default — `tofu apply` runs with no `terraform.tfvars`
at all if you accept the homelab defaults. Override in a (gitignored)
`terraform.tfvars` only when one of the assumed values is wrong for your
environment:

```hcl
# letsencrypt_email = "you@example.com"   # default is the operator mailbox
# kubeconfig_path   = "../../talos/_out/kubeconfig"
# lab_dns_name      = "lab.jackhall.dev"
# lb_pool_start     = "192.168.1.200"
# lb_pool_end       = "192.168.1.230"
```

For first-run smoke testing, point at the Let's Encrypt staging
directory to avoid burning your weekly issuance budget on a misconfig:

```hcl
letsencrypt_server = "https://acme-staging-v02.api.letsencrypt.org/directory"
```

Switch back to the production directory (the variable's default) once
the staging cert issues clean.

## Run

```sh
cd terraform/bootstrap
tofu init        # pulls providers, configures the GCS backend
tofu plan
tofu apply
```

A second `tofu plan` immediately after a successful apply must show
`No changes`. If it doesn't, that's a bug — open an issue.

After apply, run `just smoke` from the repo root to sanity-check the
cluster — `cilium connectivity test` plus a Ready=True assertion on the
wildcard `Certificate`, the LE `ClusterIssuer`, and the `gsm`
`ClusterSecretStore`. See the repo-root [`README.md`](../../README.md)
for prerequisites.

## Idempotency

Re-running `tofu apply` on an already-bootstrapped cluster is a no-op.
The `kubectl_manifest` resources use server-side apply with
`force_conflicts = true`, which converges with whatever ArgoCD has done
to the same objects. The `kubernetes_annotations` resource on the
`local-path` `StorageClass` uses `force = true` for the same reason.

## Recovery from a partial apply

Terraform's Helm provider rolls a single Helm release back on failure
(`atomic = true`) but cannot unwind earlier successful releases. The
recovery shape depends on which step failed.

**Gateway API CRDs (step 1).** Re-run. The CRDs are server-side-applied
and re-applying is idempotent.

**Cilium (step 2).** Inspect the helm release: `helm -n kube-system
status cilium`. If pods are crashlooping on a Talos values mismatch,
fix the values, run `tofu apply`. If the release got stuck and `atomic`
left it pending, `helm -n kube-system uninstall cilium` and re-apply.
The LB pool and L2 policy do not need to be cleaned up — they're
re-applied each run.

**cert-manager (step 3).** Same shape as Cilium. The wildcard
`Certificate` is the slow part — DNS-01 takes ~2 minutes to propagate.
If the `Certificate` shows `Ready=False` after apply, check
`kubectl -n cert-manager describe certificate wildcard-lab-jackhall-dev`
and `kubectl -n cert-manager describe clusterissuer letsencrypt-dns01`.
The most common cause is NS delegation not yet propagated.

**External Secrets Operator (step 4).** If ESO comes up but the
`ClusterSecretStore gsm` shows `Ready=False`, the most common causes
are: the OIDC discovery document or JWKS isn't reachable at the
public issuer URL (re-run the upload from #139's recipe; the issuer
URL is `tofu -chdir=../gcp output -raw cluster_oidc_issuer`, verify
with `curl "$(tofu -chdir=../gcp output -raw cluster_oidc_issuer)/.well-known/openid-configuration"`
and `…/openid/v1/jwks`); the WIF binding on `external-secrets@…`
doesn't trust the `system:serviceaccount:external-secrets:external-secrets-gsm`
principal (check `terraform/gcp/` plan for `eso_wif_user`); or the GCP
SA lacks `roles/secretmanager.secretAccessor` (verify in
`terraform/gcp/`). `kubectl -n external-secrets describe
clustersecretstore gsm` surfaces the underlying GCP STS error verbatim
in the `Status.Conditions[Ready].Message` field. See
[ADR-0007](../../docs/adr/0007-eso-bootstrap-auth-via-cluster-wif.md)
for the auth shape.

**local-path-provisioner (step 5).** Inspect:
`kubectl -n local-path-storage get pods`. If the upstream YAML moved,
bump `var.local_path_version`.

**ArgoCD (step 6).** If the Helm release succeeded but the
`Application` resources didn't apply, re-run. They're
server-side-applied and idempotent.

## Outputs

| Output                       | Used by                                                      |
|------------------------------|--------------------------------------------------------------|
| `wildcard_cert_secret`       | Gateway/HTTPRoute manifests in `kubernetes/apps/<name>/`     |
| `argocd_namespace`           | Operator port-forwarding the UI on first login              |
| `argocd_initial_admin_secret`| Operator reading the initial admin password                 |
| `default_storage_class`      | Sanity check / addon PVC defaults                           |
| `lb_pool_range`              | Operator sanity check against the LAN range                 |
