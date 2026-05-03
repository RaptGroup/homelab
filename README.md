# Rockingham Homelab

This repository contains configuration files for the Rockingham Home lab, along with documentation and topology diagrams.

# Table of Contents
* [Introduction](#introduction)
* [Infrastructure](#infrastructure)
* [Workloads](#workloads)
* [Repository Structure](#repository-structure)
* [Development](#development)
* [Deployment Management](#deployment-management)

# Introduction

The Rockingham Homelab provides a compute environment that supports self-sustained and sustainable local development including:
- Container and package registries (Harbor)
- Self-hosted Github Actions runners
- JupyterHub for Data Science and Machine Learning projects
- Kubernetes for hosting a variety of software projects

# Infrastructure

Rockingham Homelab infrastructure has the following components:

**Hardware**
- 3 small Intel NUCs (6 cores, 16GB RAM, 500GB SSD each) — Talos control plane
- 3 large Intel NUCs (8 cores, 64GB RAM, 1TB SSD each) — Talos workers
- Linksys LGS328PC 24-port Managed Switch
- CyberPower CP1500PFCRM2U PFC Sinewave UPS System, 1500VA/1000W, 8 Outlets, AVR, Short Depth 2U Rackmount
- (future) Synology NAS

**Software**
- PiHole: Used for DNS management primarily
- Talos Linux Kubernetes Cluster (single cluster across all 6 NUCs)
- ArgoCD: GitOps continuous deployment
- MetalLB: Load balancer for bare metal Kubernetes
- Longhorn: Distributed block storage
- Cert-Manager + Trust-Manager: Automated TLS certificate management
- Envoy Gateway: Ingress gateway and traffic management
- GitHub Actions Runner Controller: Self-hosted CI/CD runners


# Workloads

All workloads in the lab run on the Talos Kubernetes cluster.

## Kubernetes
The Kubernetes cluster is based on Talos Linux. The cluster nodes are configured with `talosctl` using the manifests in `talos/`.

**Current Deployed Applications:**
- **MetalLB**: Provides LoadBalancer services for bare metal clusters
- **Cert-Manager**: Automated certificate provisioning and management  
- **Trust-Manager**: Distributes CA certificates across namespaces
- **Longhorn**: Cloud-native distributed storage for persistent volumes
- **Envoy Gateway**: Modern ingress controller and API gateway
- **GitHub Actions Runner Controller**: Self-hosted runners for CI/CD
- **Infrastructure Services**: Custom CA server and homelab-specific tooling

> See https://www.talos.dev/v1.10/introduction/getting-started/#configure-talos-linux for the official bootstrap flow.

`talos/controlplane.yaml` and `talos/worker.yaml` are templates: the network address and `deviceSelector.hardwareAddr` block must be overridden per node before apply (e.g. via `--config-patch @patches/<node>.yaml`).

Add control plane nodes:
```
talosctl apply-config --insecure -n <node_ip> -e $CONTROL_PLANE_IP \
  --config-patch @patches/<node>.yaml -f talos/controlplane.yaml
```

Add worker nodes:
```
talosctl apply-config --insecure --nodes <node_ip> \
  --config-patch @patches/<node>.yaml --file talos/worker.yaml
```

# Repository Structure

This repository is organized to support GitOps workflows and infrastructure as code:

```
├── apps/                    # ArgoCD Applications (Helm chart)
│   ├── workloads/          # Individual workload Helm charts
│   │   ├── infrastructure/ # Core infrastructure services
│   │   └── metal-lb/      # MetalLB configuration
│   └── values.yaml        # Application catalog and configurations
├── argocd/                 # ArgoCD installation and configuration
├── homelab/                # Go applications (CA server, CLI tools)
└── talos/                  # Talos Linux configuration files
```

# Development

## Go Applications

The repository includes custom Go applications for homelab infrastructure:

### CA Server (`homelab/ca-server/`)
A simple HTTP server that serves the homelab root CA certificate for trust distribution.

**Development Commands:**
```bash
cd homelab/
make build          # Build for current platform
make test           # Run tests
make run            # Build and run locally
make lint           # Lint code (requires golangci-lint)
make all            # Build for all platforms
```

The CA server serves certificates at `http://localhost:8080/ca` and can be configured with custom certificate paths.

# Deployment Management

The homelab uses **ArgoCD** for GitOps-based continuous deployment. All applications are defined in `apps/values.yaml` and deployed automatically when changes are pushed to the main branch.

## Application Sync Waves

Applications are deployed in ordered waves to ensure dependencies are satisfied:

- **Wave -10**: cert-manager (foundational certificate management)
- **Wave -9**: trust-manager (CA certificate distribution)  
- **Wave -5**: metallb, longhorn, envoy-gateway-system (core infrastructure)
- **Wave 0**: infrastructure workloads (custom services)
- **Wave 5**: github-arc (CI/CD runners)

## Managing Applications

Applications are managed through the ArgoCD UI or by modifying `apps/values.yaml`. Each application entry supports:

- Custom Helm charts (local or remote repositories)
- OCI-based Helm charts  
- Custom values and configuration overrides
- Sync wave ordering for deployment dependencies

**ArgoCD Access:** The ArgoCD instance manages all cluster applications and provides a web UI for monitoring deployment status.
