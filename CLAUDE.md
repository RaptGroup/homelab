# CLAUDE.md

Guidance for Claude Code working in this repository.

## Repository Overview

The Rockingham Homelab: a 6-node bare-metal Kubernetes cluster (`rockingham`)
running Talos Linux. Two Terraform roots — `terraform/gcp/` (project, DNS
zone, SAs, GSM, WIF) and `terraform/bootstrap/` (Gateway API CRDs → Cilium →
cert-manager → ESO → local-path → ArgoCD) — hand the cluster off to ArgoCD,
which reconciles every addon under `kubernetes/apps/` via app-of-apps. Adding
an addon is a new directory there; Terraform is not touched.

[`CONTEXT.md`](./CONTEXT.md) is the canonical glossary (cluster name, LB pool,
DNS subzone, ARC scale sets, Phase 1/2 storage). The load-bearing decisions
behind that vocabulary live in [`docs/adr/`](./docs/adr/). Per-root READMEs
under `terraform/`, `kubernetes/`, and `talos/` cover their own areas; per-app
detail lives in `kubernetes/apps/<name>/README.md`. Read CONTEXT once before
working in this repo.
