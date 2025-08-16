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


# TODOS:

- [x] PiHole for DNS Sanity in the lab
- [ ] NGINX Proxy VM:
    - [x] Base VM with podman, nginx
    - [x] Rules for hypercore clusters with load balancing
    - [ ] Rules for kubernetes cluster API
- [ ] Kubernetes Cluster
    - [ ] Provision talos cluster
        - [ ] MachineConfig
    - [ ] Kraken Manifest
    - [ ] Hypercore 1:
        - [ ] 1 control plane node
        - [ ] 2 worker nodes
    - [ ] Hypercore 2:
        - [ ] 2 control plane nodes
        - [ ] 3 worker nodes
