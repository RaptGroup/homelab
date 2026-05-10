# Rockingham Homelab

Configuration for the Rockingham Homelab: a 6-node bare-metal Kubernetes cluster.

This repository will hold:

- **Terraform** for provisioning and managing infrastructure.
- **Talos** machine configurations for the cluster nodes.

The repository was reset from an earlier VM-based design and is intentionally
empty until those pieces land.

## Documentation

[`CONTEXT.md`](./CONTEXT.md) is the glossary of canonical homelab
vocabulary (the `lab.jackhall.dev` subzone, the LB pool, the ARC scale
sets, Phase 1 vs Phase 2 storage, etc.). Read it once before working in
this repo so terms in PRs, ADRs, and chat aren't re-derived each time.

Public docs live in [`docs/`](./docs) and are published to GitHub Pages at
<https://jvcorredor.github.io/homelab/> by the `Deploy docs` workflow on
every push to `main`. Run the site locally with:

```sh
cd docs
npm install
npm run dev
```
