---
title: Platform
description: The cluster-side services Terraform installs before ArgoCD takes over — ArgoCD itself, cert-manager, External Secrets Operator, and local-path-provisioner.
---

The platform layer is the small set of cluster-side services that have to
exist before ArgoCD has anything to reconcile against. It is what
[`terraform/bootstrap/`](https://github.com/RaptGroup/homelab/tree/main/terraform/bootstrap)
installs onto an empty Talos cluster, in a fixed order, ending with
ArgoCD pointing at `kubernetes/apps/`. After that the platform is
hands-off: every addon under [Applications](/homelab/applications/)
lands via ArgoCD without another Terraform run.

This section covers the four platform services that aren't otherwise
documented:

| Service | Role | Operational entry point |
|---|---|---|
| [ArgoCD](./argocd/) | GitOps controller — reconciles every addon under `kubernetes/apps/`. | UI at `https://argocd.lab.jackhall.dev` |
| [cert-manager](./cert-manager/) | Issues the cluster-wide Let's Encrypt wildcard for `*.lab.jackhall.dev`. | `ClusterIssuer/letsencrypt-dns01` |
| [External Secrets Operator](./external-secrets/) | Syncs Google Secret Manager values into Kubernetes `Secret`s. | `ClusterSecretStore/gsm` |
| [local-path-provisioner](./local-path/) | Cluster-default `StorageClass` backing every PVC for now. | `StorageClass/local-path` (default) |

Cilium is the fifth service `terraform/bootstrap/` installs but it has
its own dedicated treatment in
[ADR-0002 — Cilium as the unified networking layer](https://github.com/RaptGroup/homelab/blob/main/docs/adr/0002-cilium-unified-networking.md)
and across the [Networking](/homelab/networking/split-horizon-dns/) and
[Applications](/homelab/applications/lab-gateway/) sections, so it is
deliberately out of scope here.

This section also carries one page that is not a bootstrapped service:
[Observability for developers](./observability-for-developers/) — the
one-page contract for instrumenting an app with metrics, logs, alerts,
and traces on the [observability stack](/homelab/applications/observability/).

## Why these four are bootstrapped via Terraform

The full rationale lives in
[ADR-0001 — IaC strategy](https://github.com/RaptGroup/homelab/blob/main/docs/adr/0001-iac-strategy.md).
The short version: ArgoCD cannot reconcile itself before it exists, and
several of the addons that follow it depend on cert-manager, ESO, and a
default `StorageClass` already being present. Something has to run the
bootstrap; Terraform is the tool that already owns the GCP side of the
lab, so it owns this seam too.

The boundary is sharp: a service installed by `terraform/bootstrap/` is
**not** also tracked by an ArgoCD `Application`. Two controllers
fighting over the same Helm release is the failure mode this convention
exists to avoid. The exception is ArgoCD itself, which manages its own
chart via a self-managed `Application` so post-bootstrap version bumps
flow through a normal PR.

## Bootstrap order

Components are installed in this exact order, enforced via `depends_on`
between Helm releases and `kubectl_manifest` resources. Re-running on a
fresh cluster cannot apply pieces in the wrong order.

1. **Gateway API CRDs** — applied first so Cilium's operator finds the
   CRDs at startup and registers its `GatewayClass`.
2. **Cilium** — CNI, kube-proxy replacement, LB IPAM, Gateway API.
3. **cert-manager** — chart only; the `ClusterIssuer` and the wildcard
   `Certificate` come up later, after ESO can sync the DNS-01 SA key.
4. **External Secrets Operator** — chart, the bootstrap GSM SA key
   `Secret` (the *only* Kubernetes `Secret` Terraform creates
   directly), and the cluster-wide `ClusterSecretStore/gsm`. Once this
   is up, the cert-manager `ExternalSecret` syncs the DNS-01 key, then
   the `ClusterIssuer` and wildcard `Certificate` come up.
5. **local-path-provisioner** — applied from the upstream
   `deploy/local-path-storage.yaml` and annotated as the cluster's
   default `StorageClass`.
6. **ArgoCD** — Helm chart, a self-managed `Application`, and the root
   app-of-apps `Application` watching `kubernetes/apps/`.

## How the platform pieces connect

The interesting cross-talk is between cert-manager, ESO, and the
addons:

```
Google Secret Manager (terraform/gcp)
    │
    │  cert-manager DNS-01 SA key, ArgoCD repo SSH key, …
    ▼
External Secrets Operator (ClusterSecretStore: gsm)
    │
    │  ExternalSecret → K8s Secret in target namespace
    ▼
cert-manager (ClusterIssuer: letsencrypt-dns01)
    │
    │  DNS-01 against Cloud DNS → real LE wildcard cert
    ▼
Secret cert-manager/wildcard-lab-jackhall-dev-tls
    │
    │  cross-namespace ReferenceGrant
    ▼
the lab Gateway (kubernetes/apps/lab-gateway/)  ← TLS for *.lab.jackhall.dev
```

The wildcard cert that fronts every web-exposed addon is the load-bearing
output of cert-manager + ESO + Cloud DNS together. local-path is the
quieter dependency: every addon that asks for a PVC without naming a
`StorageClass` gets one carved out of a node's local disk. ArgoCD ties
the rest of the cluster to git — every directory under
[`kubernetes/apps/`](https://github.com/RaptGroup/homelab/tree/main/kubernetes/apps)
becomes an `Application` automatically via the root app-of-apps.

## More

The repo-side
[`terraform/bootstrap/README.md`](https://github.com/RaptGroup/homelab/blob/main/terraform/bootstrap/README.md)
covers the operator's run book — prerequisites, what to do on a partial
apply, idempotency guarantees, and the chart-version variables for
upgrading any of these services.
