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
  [`talos/README.md`](https://github.com/jvcorredor/homelab/tree/main/talos)
  for the apply and bootstrap commands.
- `terraform/` — Infrastructure provisioning (planned).
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

Rebuild in progress. Talos machine configs for all six nodes are in
place; the bootstrap and bring-up runbooks and the Terraform layer are
next. This page will grow as the cluster comes back online.
