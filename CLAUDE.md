# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is the Rockingham Homelab repository, which contains infrastructure configuration and workload definitions for a Kubernetes-based homelab environment. The lab runs on Talos Linux and uses ArgoCD for GitOps-based deployment management.

## Architecture

The homelab is structured around several key components:

### Infrastructure Components
- **Talos Linux Kubernetes Cluster**: 6 bare-metal NUCs — 3 small (6c/16GB/500GB) as control plane, 3 large (8c/64GB/1TB) as workers
- **ArgoCD**: GitOps deployment management (`argocd/values.yaml`)
- **MetalLB**: Load balancer for bare metal Kubernetes
- **Cert-Manager + Trust-Manager**: TLS certificate management
- **Longhorn**: Distributed block storage
- **Envoy Gateway**: Ingress gateway
- **GitHub Actions Runner Controller**: Self-hosted runners

### Go Applications
- **CA Server**: Simple HTTP server that serves the homelab CA certificate at `/ca` endpoint
  - Source: `homelab/ca-server/` and `homelab/cmd/ca-server/`
  - Serves CA certificate from `/etc/homelab/certificates/ca-cert.pem` (configurable)
  - Listens on port 8080

## Key Directories

- `apps/`: Helm chart for ArgoCD applications with workload definitions
- `apps/workloads/`: Individual workload Helm charts (metal-lb, infrastructure)
- `talos/`: Talos Linux configuration files (controlplane.yaml, worker.yaml)
- `homelab/`: Go application source code (CA server)
- `argocd/`: ArgoCD installation configuration

## Development Commands

### Go Development (homelab/)
```bash
# Build for current platform
make build

# Build for all platforms
make all

# Run tests
make test

# Format and lint code
make fmt
make vet
make lint  # requires golangci-lint

# Install dependencies
make deps

# Run the CA server locally
make run
```

### Kubernetes Operations
```bash
# Apply Talos configuration. Network address + MAC must be patched per node.
talosctl apply-config --insecure -n <node_ip> -e $CONTROL_PLANE_IP \
  --config-patch @talos/patches/<node>.yaml -f talos/controlplane.yaml
talosctl apply-config --insecure --nodes <ip> \
  --config-patch @talos/patches/<node>.yaml --file talos/worker.yaml

# Check cluster status
kubectl get nodes
kubectl get pods -A
```

### ArgoCD Application Management
Applications are defined in `apps/values.yaml` with sync waves to control deployment order:
- Wave -10: cert-manager
- Wave -9: trust-manager  
- Wave -5: metallb, longhorn, envoy-gateway-system
- Wave 0: infrastructure workloads
- Wave 5: github-arc (controller and runners)

## Important Configuration

### Sync Waves
Applications use ArgoCD sync waves for ordered deployment. Infrastructure components (cert-manager, metallb, longhorn) deploy before application workloads.

### Certificate Management
The homelab uses a custom CA managed by cert-manager. Trust-manager distributes the CA bundle to namespaces labeled with `trust: "enabled"`.

### GitHub Actions Integration
Self-hosted GitHub Actions runners are deployed via the Actions Runner Controller, configured for the `haljac/homelab` repository.

## Key Files to Understand

- `apps/values.yaml`: Complete application catalog with all workload definitions
- `apps/workloads/infrastructure/templates/`: Core infrastructure workload manifests
- `homelab/Makefile`: Go build system for CA server
- `talos/controlplane.yaml` & `talos/worker.yaml`: Cluster node configurations