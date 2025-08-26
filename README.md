# Rockingham Homelab

This repository contains configuration files for the Rockingham Home lab, along with documentation and topology diagrams.

# Table of Contents
* [Introduction](#introduction)
* [Infrastructure](#infrastructure)
* [Workloads](#workloads)

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
The Kubernetes cluster is based on Talos Linux. The cluster nodes are based on the Kraken manifest in `kubernetes/`. They must be configured with `talosctl`.

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
