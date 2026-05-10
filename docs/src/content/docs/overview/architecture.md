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
- **Workers** — `worker-01` (`192.168.1.241`), `worker-02` (`.242`).
- Per-node patches live under `talos/patches/nodes/<hostname>.yaml` and
  carry only the bits that differ between nodes: hostname, static address,
  install disk, and VIP membership for control planes.

## Status

Rebuild in progress. Talos machine configs for five nodes are in place;
the remaining node, the bootstrap and bring-up runbooks, and the
Terraform layer are next. This page will grow as the cluster comes back
online.
