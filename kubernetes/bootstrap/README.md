# `kubernetes/bootstrap/`

Manifests applied by `terraform/bootstrap/` to hand the cluster over to
ArgoCD. After bootstrap, ArgoCD reconciles these too — they are committed
here so chart upgrades and root-app changes go through a normal PR rather
than a Terraform apply.

## Contents

- `root.yaml.tftpl` — the root `Application` watching `kubernetes/apps/`
  (the app-of-apps; not `ApplicationSet`).
- `argocd/application.yaml.tftpl` — the self-managed ArgoCD `Application`,
  multi-source: chart from `argoproj.github.io/argo-helm`, values from
  `argocd/values.yaml` in this repo via `$values`.
- `argocd/values.yaml` — Helm values for ArgoCD. Read by both the
  Terraform bootstrap (initial install) and the self-managed
  `Application` (every reconcile after).

## `.tftpl` files

The two `Application` files are Terraform templates so the chart version,
git repo URL, and target revision come from a single place
(`terraform/bootstrap/variables.tf`). After bootstrap, the rendered
manifests live in the cluster and ArgoCD reconciles directly against the
committed file once you remove the templating — but in steady state these
values rarely change, so the template indirection is paid only on the
first apply or on an explicit chart bump.
