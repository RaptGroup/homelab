# ADR-0002: Cilium as the unified networking layer

- **Status:** Accepted
- **Date:** 2026-05-10

## Context

The cluster runs on bare metal. There is no cloud LoadBalancer
controller and no cloud-provided ingress. Three networking
responsibilities have to be solved before any addon is reachable from
a browser:

1. **CNI** — pod-to-pod networking, NetworkPolicy, kube-proxy or its
   replacement.
2. **LoadBalancer for `Service` objects** — IP allocation from a LAN
   range plus L2 announcement so the LAN actually routes to the
   chosen IP. On a cloud this is the cloud controller; on bare metal
   it's a homegrown problem.
3. **Gateway API** — north-south HTTP routing for `*.lab.jackhall.dev`
   services. Plain `Ingress` is being phased out across the ecosystem
   in favour of Gateway API and there is no reason to start on the
   legacy path.

Talos has its own opinions about how the dataplane is wired —
`kubeProxyReplacement`, KubePrism on `localhost:7445` for
control-plane access independent of the VIP, no privileged init
containers, specific securityContext capabilities required for eBPF
and host-network operations. Whatever CNI is chosen has to honour
these.

The operator is one person. Each additional addon installed at the
networking layer is more code paths, metrics, CRDs, release schedules,
and integration seams to debug at 11 PM when something is wrong.

## Decision

Use **Cilium as a single Helm release covering CNI, LB IPAM with L2
announcements, and Gateway API.** No MetalLB. No Envoy Gateway. No
separate kube-proxy. Concretely:

1. Helm values required for Cilium on Talos:
   - `kubeProxyReplacement: true`
   - `k8sServiceHost: localhost`, `k8sServicePort: 7445` — KubePrism,
     so the cluster keeps working when the control-plane VIP is in
     transit.
   - `cgroup.autoMount.enabled: false`, `cgroup.hostRoot: /sys/fs/cgroup`
     — Talos mounts cgroup v2 itself; Cilium must not try to remount.
   - `ipam.mode: kubernetes`
   - `l2announcements.enabled: true`
   - `gatewayAPI.enabled: true`
   - The Talos-documented securityContext capabilities for the agent
     and operator pods.
2. Gateway API CRDs are installed **before** Cilium in the bootstrap
   order. Cilium expects them present.
3. LoadBalancer IPs come from a `CiliumLoadBalancerIPPool` covering
   `192.168.1.200`–`192.168.1.230`. AdGuard Home is pinned to
   `192.168.1.200` so LAN devices have one stable address to point
   manual DNS at. L2 announcements are done via a
   `CiliumL2AnnouncementPolicy` that excludes the control-plane nodes
   (announcements are workers-only).
4. `HTTPRoute` is the only Gateway API route type used in this pass.
   `TLSRoute` stays disabled. TLS terminates at the Gateway, not at
   the workload.

## Consequences

**Positive**

- One Helm chart, one CRD set, one set of metrics and logs to learn.
  Cilium owns the entire dataplane question; no integration seam to
  Cilium ⇄ MetalLB ⇄ Envoy at homelab scale.
- Hubble UI ships with Cilium. Network-flow visibility is free, which
  is the entire Tier 1 observability story (kube-prometheus-stack is
  deferred). See ADR-0003 context note: `hubble.lab.jackhall.dev` is
  exposed via Gateway API like any other addon.
- KubePrism makes pods independent of the control-plane VIP for kube
  API access. A VIP failover doesn't drop pod-side reconcilers.
- eBPF dataplane removes the kube-proxy DaemonSet entirely.

**Negative**

- All eggs in one basket. A Cilium bug is simultaneously a CNI bug, a
  LoadBalancer bug, and a Gateway API bug. Mitigated by Cilium being
  the most active CNI project in the ecosystem and by ArgoCD-driven
  rollback.
- Cilium's LB IPAM and L2 announcement code is younger than MetalLB's
  equivalent. This is acceptable at homelab scale; it would warrant a
  second look at production scale.
- Cilium's Gateway API implementation lags Envoy Gateway in feature
  breadth. `HTTPRoute` is sufficient for current needs; if a future
  workload needs `TCPRoute`, `GRPCRoute`, or experimental features,
  this decision will need revisiting.
- Talos-specific Helm values are non-obvious. Missing one
  (`cgroup.autoMount.enabled` is the canonical example) breaks node
  bring-up in confusing ways. The values are pinned in
  `terraform/bootstrap/` and treated as load-bearing, not cosmetic.

## Alternatives considered

### Flannel (CNI) + MetalLB (LB IPAM + L2) + Envoy Gateway (Gateway API)

Rejected. Three best-in-slot tools, three Helm releases, three CRD
groups, three sets of metrics and dashboards. The integration surface
between them — particularly MetalLB's interaction with kube-proxy
replacement on Talos and Envoy Gateway's routing-into-MetalLB-Service
contract — is real homework. For a single-operator homelab the
operational tax outweighs any per-tool depth advantage. None of the
three has a feature this homelab actually needs that Cilium lacks.

### Calico

Rejected. Calico is a strong CNI with NetworkPolicy and BGP, but it
ships no LoadBalancer IPAM and no Gateway API implementation. Choosing
Calico would still require MetalLB and an additional Gateway API
controller — the multi-tool problem above without the per-tool
strengths that motivated it. Cilium's eBPF dataplane and Hubble are
net wins on top.

### Kube-OVN

Rejected. Kube-OVN is a full SDN with VPC, subnet, and overlay
abstractions. Those are wasted on a flat home LAN with one VLAN. The
community is smaller, the Talos integration story is less established,
and the operational complexity is materially higher than the workload
demands.
