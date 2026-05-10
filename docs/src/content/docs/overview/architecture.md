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

The repository is intentionally sparse during the rebuild. As pieces land
they will be documented here:

- `terraform/` — infrastructure provisioning (planned).
- `talos/` — machine configurations for each node (planned).
- `docs/` — this site.

## Status

Rebuild in progress. This page will grow as the cluster comes back online.
