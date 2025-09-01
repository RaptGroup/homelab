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
- 3 Node Scale Computing Hypercore HE-153 cluster (18 cores, 187GiB RAM, 6TB SSD Storage)
- 3 Node Scale Computing Hypercore HE-150 cluster (6 cores, 48GiB RAM, 647GiB SSD Storage)
- Linksys LGS328PC 24-port Managed Switch
- CyberPower CP1500PFCRM2U PFC Sinewave UPS System, 1500VA/1000W, 8 Outlets, AVR, Short Depth 2U Rackmount
- (future) Synology NAS

**Software**
- PiHole: Used for DNS management primarily
- Samba SMB Share (200GB)
- NGINX Proxy
- Talos Linux Kubernetes Cluster
- ArgoCD: GitOps continuous deployment
- MetalLB: Load balancer for bare metal Kubernetes
- Longhorn: Distributed block storage
- Cert-Manager + Trust-Manager: Automated TLS certificate management
- Envoy Gateway: Ingress gateway and traffic management
- GitHub Actions Runner Controller: Self-hosted CI/CD runners


# Workloads

All workloads in the lab run on Hypercore, either as virtual machines or workloads deployed to the Kubernetes cluster.

All virtual machines in the lab have the following characteristics, expressed as a _**Kraken Manifest**_:
- Ubuntu Server 24.04
- Podman

## Virtual Machines

**NGINX**
Nginx is a [Podman Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html) that is configured through the following host paths (via container mounts):
- nginx.conf: `/var/homelab/etc/nginx/nginx.conf`
- html: `/var/homelab/etc/nginx/`

It is running at port 80 on the host system (`-p 80:80`), configured to perform TCP forwarding with TLS passthrough.

## Kubernetes
The Kubernetes cluster is based on Talos Linux. The cluster nodes are based on the Kraken manifest in `talos/`. They must be configured with `talosctl`.

**Current Deployed Applications:**
- **MetalLB**: Provides LoadBalancer services for bare metal clusters
- **Cert-Manager**: Automated certificate provisioning and management  
- **Trust-Manager**: Distributes CA certificates across namespaces
- **Longhorn**: Cloud-native distributed storage for persistent volumes
- **Envoy Gateway**: Modern ingress controller and API gateway
- **GitHub Actions Runner Controller**: Self-hosted runners for CI/CD
- **Infrastructure Services**: Custom CA server and homelab-specific tooling

> Note: These steps have already been performed. 
> https://www.talos.dev/v1.10/introduction/getting-started/#configure-talos-linux

The only difference between the steps in the official documentation and what was necessary for this cluster was adding additional control plane nodes. The following command can be executed for each additional control plane node without any modification to the `controlplane.yml` used for the original kubernetes master node.

Add control plane nodes:
```
talosctl apply-config --insecure -f controlplane.yaml -n <new_control_plan_node> -e $CONTROL_PLANE_IP
```

Add additional worker nodes:
```
talosctl apply-config --insecure --nodes <ip> --file worker.yaml
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
├── talos/                  # Talos Linux configuration files
└── vms/                    # Virtual machine manifests
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
