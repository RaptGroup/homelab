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


## Workloads

All workloads in the lab run on Hypercore, either as virtual machines or workloads deployed to the Kubernetes cluster.

### Virtual Machines

All virtual machines in the lab have the following characteristics, expressed as a _**Kraken Manifest**_:
- Ubuntu Server 24.04
- Podman

