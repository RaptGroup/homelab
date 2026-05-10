---
title: Architecture
description: High-level shape of the Rockingham Homelab.
---

The Rockingham Homelab is a 6-node bare-metal Kubernetes cluster running
[Talos Linux](https://www.talos.dev/). It is being rebuilt from an earlier
VM-based design that ran on Hypercore.

## Goals

- **Reproducible from source.** Every node is provisioned from machine
  configs checked into this repository.
- **Minimal host footprint.** Talos has no SSH and no shell — the cluster
  is configured through its API and the manifests applied to it.
- **Public documentation.** Anything host-specific that isn't safe to
  publish lives outside this repo.

## Repository layout

- `talos/` — Machine configurations for each node, plus the workflow for
  generating secrets, patching the base controlplane/worker configs, and
  applying them to nodes in maintenance mode. See
  [`talos/README.md`](https://github.com/RaptGroup/homelab/tree/main/talos)
  for the apply and bootstrap commands.
- `terraform/` — Two roots, split per
  [ADR-0001](/homelab/architecture/decisions/).
  `terraform/gcp/` owns the cloud resources (Cloud DNS zones, Secret
  Manager containers, the IAM service accounts cert-manager and ESO
  impersonate, the Workload Identity Federation pool GitHub Actions
  authenticates through, the Terraform state bucket) — all in one
  `rockingham-homelab` GCP project, documented under
  [Cloud](/homelab/cloud/gcp/).
  `terraform/bootstrap/` brings a fresh Talos cluster from "kubeconfig
  works, nothing installed" to "ArgoCD reconciles `kubernetes/apps/`" —
  Gateway API CRDs, Cilium, cert-manager, External Secrets Operator,
  local-path-provisioner, and ArgoCD itself. The four
  non-Cilium services are documented in the
  [Platform section](/homelab/platform/).
- `kubernetes/` — Everything ArgoCD reconciles after bootstrap.
  `kubernetes/bootstrap/` holds the root `Application` and the ArgoCD
  values consumed by the bootstrap Terraform; `kubernetes/apps/` is one
  directory per addon (AdGuard Home, Homepage, Hubble UI, the ARC
  controller and runner scale sets). Dropping a new directory under
  `kubernetes/apps/` is how a new addon gets into the cluster. See the
  [Applications index](/homelab/applications/) for the current set.
- `docs/` — This site.

## Cluster

- Name: `rockingham`.
- Control-plane endpoint: `https://192.168.1.240:6443` — a shared VIP held
  by whichever control-plane node currently owns it.
- **Control plane** — `cp-01` (`192.168.1.245`), `cp-02` (`.246`), `cp-03`
  (`.247`). All three carry the VIP membership.
- **Workers** — `worker-01` (`192.168.1.241`), `worker-02` (`.242`),
  `worker-03` (`.243`).
- Per-node patches live under `talos/patches/nodes/<hostname>.yaml` and
  carry only the bits that differ between nodes: hostname, static address,
  install disk, and VIP membership for control planes.

## Hardware

Two tiers of Intel NUC. Control planes are the older, smaller boxes;
workers are the newer ones with the headroom. Pulled live from
`talosctl get systeminformation` / `cpu` / `ram` / `disks`.

| Node | Model | CPU | Cores / Threads | RAM | NVMe |
|---|---|---|---|---|---|
| `cp-01` | Intel NUC8i3BEK | i3-8109U @ 3.0 GHz | 2 / 4 | 16 GB DDR4-2400 (2×8) | Samsung 970 EVO Plus 250 GB |
| `cp-02` | Intel NUC8i3BEK | i3-8109U @ 3.0 GHz | 2 / 4 | 16 GB DDR4-2400 (2×8) | Samsung 970 EVO Plus 250 GB |
| `cp-03` | Intel NUC8i3BEK | i3-8109U @ 3.0 GHz | 2 / 4 | 16 GB DDR4-2400 (2×8) | Samsung 970 EVO Plus 250 GB |
| `worker-01` | Intel NUC10i7FNK | i7-10710U @ 1.1 GHz | 6 / 12 | 64 GB DDR4-3200 (2×32) | Samsung 970 EVO Plus 2 TB |
| `worker-02` | Intel NUC10i7FNK | i7-10710U @ 1.1 GHz | 6 / 12 | 64 GB DDR4-2667 (2×32) | Samsung 970 EVO Plus 2 TB |
| `worker-03` | Intel NUC10i7FNK | i7-10710U @ 1.1 GHz | 6 / 12 | 64 GB DDR4-2667 (2×32) | Samsung 970 EVO Plus 2 TB |

Cluster totals: 24 cores / 48 threads, 240 GB RAM, ~6.75 TB NVMe.

## Status

Phase 1 cluster is up. Talos is installed on all six nodes, both
Terraform roots apply cleanly, and the ArgoCD root `Application` is
reconciling the addons under
[`kubernetes/apps/`](https://github.com/RaptGroup/homelab/tree/main/kubernetes/apps):
AdGuard Home (LAN resolver behind the split-horizon setup), Homepage
(the dashboard at `dashboard.lab.jackhall.dev`), Hubble UI, and the
GitHub Actions Runner Controller plus its two runner scale sets. Phase 2
work — Longhorn for replicated storage and the deeper observability
stack — is deferred.
