# Rockingham Homelab

Configuration for the Rockingham Homelab: a 6-node bare-metal Kubernetes cluster.

This repository will hold:

- **Terraform** for provisioning and managing infrastructure.
- **Talos** machine configurations for the cluster nodes.

The repository was reset from an earlier VM-based design and is intentionally
empty until those pieces land.

## Documentation

Public docs live in [`docs/`](./docs) and are published to GitHub Pages at
<https://jvcorredor.github.io/homelab/> by the `Deploy docs` workflow on
every push to `main`. Run the site locally with:

```sh
cd docs
npm install
npm run dev
```
