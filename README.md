# Rockingham Homelab

Configuration for the Rockingham Homelab: a 6-node bare-metal Kubernetes
cluster (`rockingham`) running Talos Linux.

The cluster is bootstrapped by two Terraform roots and then reconciled by
ArgoCD. Phase 1 addons are running today.

- [`terraform/gcp/`](./terraform/gcp) — the GCP-side foundation: project,
  Cloud DNS zone for `lab.jackhall.dev`, service accounts for cert-manager
  and ESO, GSM secret containers, GCS state bucket, and the Workload
  Identity Federation pool used by CI.
- [`terraform/bootstrap/`](./terraform/bootstrap) — cluster bootstrap, in
  order: Gateway API CRDs → Cilium (CNI + kube-proxy replacement + LB IPAM
  + Gateway API) → cert-manager → External Secrets Operator →
  local-path-provisioner → ArgoCD plus the root app-of-apps `Application`.
- [`kubernetes/bootstrap/`](./kubernetes/bootstrap) — the root and
  self-managed ArgoCD `Application` templates Terraform applies.
- [`kubernetes/apps/`](./kubernetes/apps) — ArgoCD-managed addons, one
  directory per addon (`adguard-home`, `arc-controller`,
  `arc-runners-raptgroup`, `arc-runners-brazostech`, `homepage`,
  `hubble-ui`). Adding an addon is a new directory here; Terraform is not
  touched.
- [`talos/`](./talos) — per-node Talos machine-config patches and the
  bring-up runbook for the cluster.
- [`scripts/lint-apps.sh`](./scripts/lint-apps.sh) — `helm template` +
  `kubeconform` per addon, also wired into `.github/workflows/apps-lint.yml`.
- [`scripts/argocd-tracking-sweep.sh`](./scripts/argocd-tracking-sweep.sh) —
  flag any cluster resource still on Argo's legacy `instance` label without
  the modern `tracking-id` annotation (silent-prune-orphan candidates; see #68).
- [`Makefile`](./Makefile) — `make smoke` runs post-bootstrap sanity checks
  against the current kubeconfig (`cilium connectivity test` plus a Ready=True
  assertion on the wildcard `Certificate`, the LE DNS-01 `ClusterIssuer`, and
  the `gsm` `ClusterSecretStore`). Run after every `tofu apply` against
  `terraform/bootstrap/`. Requires `cilium-cli` and `kubectl` on `PATH` and
  the kubeconfig pointed at the homelab cluster; the assertions are
  read-only.

## Documentation

[`CONTEXT.md`](./CONTEXT.md) is the canonical glossary used across this
repo's PRs, ADRs, code, and chat (cluster name, the `lab.jackhall.dev`
subzone, the LB pool, the ARC scale sets, Phase 1 vs Phase 2 storage, etc.).
Read it once before working in this repo so terms aren't re-derived each time.

[`docs/adr/`](./docs/adr) records the load-bearing decisions behind that
vocabulary — IaC split (ADR-0001), Cilium as the unified networking layer
(ADR-0002), and the public-domain DNS / TLS / split-horizon strategy
(ADR-0003). The per-root READMEs (`terraform/gcp/`, `terraform/bootstrap/`,
`kubernetes/bootstrap/`, `kubernetes/apps/`, `talos/`) cover their own areas;
per-addon detail lives in `kubernetes/apps/<name>/README.md`.

The public site lives in [`docs/`](./docs) and is published to GitHub Pages
at <https://jvcorredor.github.io/homelab/> by the `Deploy docs` workflow on
every push to `main`. Run the site locally with:

```sh
cd docs
npm install
npm run dev
```
