---
title: Architecture decisions
description: Index of ADRs capturing the load-bearing architectural decisions for the Rockingham Homelab.
---

The lab keeps a small set of Architecture Decision Records under
[`docs/adr/`](https://github.com/jvcorredor/homelab/tree/main/docs/adr)
in the repo. Each ADR captures **one** load-bearing decision: what was
chosen, what was rejected, and why. ADRs explain **why**;
[`CONTEXT.md`](https://github.com/jvcorredor/homelab/blob/main/CONTEXT.md)
defines **what we call things**.

The ADR convention itself — format, lifecycle, when to write one — is
in [`docs/adr/README.md`](https://github.com/jvcorredor/homelab/blob/main/docs/adr/README.md).

## Accepted ADRs

### [ADR-0001 — IaC strategy: thin Terraform plus ArgoCD app-of-apps](https://github.com/jvcorredor/homelab/blob/main/docs/adr/0001-iac-strategy.md)

Terraform owns two roots — `terraform/gcp/` for cloud resources and
`terraform/bootstrap/` for the chicken-and-egg cluster pieces (Gateway
API CRDs, Cilium, cert-manager, ESO, local-path-provisioner, ArgoCD
itself). ArgoCD owns everything else via a single root `Application`
watching `kubernetes/apps/`. All cloud resources live in one GCP
project, `rockingham-homelab`. Rejected: pure Terraform, pure
ArgoCD-from-zero, Pulumi, Crossplane.

### [ADR-0002 — Cilium as the unified networking layer](https://github.com/jvcorredor/homelab/blob/main/docs/adr/0002-cilium-unified-networking.md)

A single Cilium Helm release covers CNI, kube-proxy replacement,
LoadBalancer IPAM with L2 announcements, and Gateway API. The required
Talos-specific Helm values (`kubeProxyReplacement`, KubePrism on
`localhost:7445`, the `cgroup` settings, the securityContext
capabilities) are pinned in `terraform/bootstrap/`. Rejected:
Flannel + MetalLB + Envoy Gateway, Calico, Kube-OVN.

### [ADR-0003 — Public domain, DNS-01 wildcard, split-horizon](https://github.com/jvcorredor/homelab/blob/main/docs/adr/0003-public-domain-dns-tls-split-horizon.md)

Public domain `jackhall.dev` with the `lab` subzone NS-delegated to
Google Cloud DNS. cert-manager issues a Let's Encrypt wildcard for
`*.lab.jackhall.dev` via DNS-01. AdGuard Home, in-cluster on
`192.168.1.200`, serves internal records to LAN devices configured to
use it (Path C — per-device manual DNS). Rejected: private CA + mkcert,
`.local` mDNS, Cloudflare Tunnel, Tailscale Funnel.

For the architecture diagram and per-OS recipes for pointing a device
at AdGuard, see [Split-horizon DNS](/homelab/networking/split-horizon-dns/).
