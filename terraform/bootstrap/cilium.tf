resource "helm_release" "cilium" {
  name             = "cilium"
  namespace        = "kube-system"
  repository       = "https://helm.cilium.io"
  chart            = "cilium"
  version          = var.cilium_chart_version
  create_namespace = false # kube-system always exists
  atomic           = true
  wait             = true
  timeout          = 600

  # Talos-specific values pinned by ADR-0002. Edits here are load-bearing —
  # missing one (cgroup.autoMount.enabled is the canonical example) breaks
  # node bring-up in confusing ways.
  values = [yamlencode({
    # eBPF dataplane replaces kube-proxy entirely; Talos ships without one.
    kubeProxyReplacement = true

    # KubePrism: every node exposes the kube API on localhost:7445, so pods
    # don't depend on the control-plane VIP being reachable.
    k8sServiceHost = "localhost"
    k8sServicePort = 7445

    # Talos manages cgroup v2 itself; Cilium must not try to remount.
    cgroup = {
      autoMount = {
        enabled = false
      }
      hostRoot = "/sys/fs/cgroup"
    }

    ipam = {
      mode = "kubernetes"
    }

    # Bare-metal LoadBalancer: Cilium owns IP allocation and L2 ARP
    # announcement on the LAN. Replaces MetalLB.
    l2announcements = {
      enabled = true
    }

    # Gateway API support — CRDs are installed by the prior step.
    gatewayAPI = {
      enabled = true
    }

    # Hubble flow visibility ships with Cilium. The UI is exposed via
    # Gateway API later as an ArgoCD app, not here. Hubble UI stays the
    # live flow-forensic view; ADR-0007 adds a self-hosted Prometheus +
    # Grafana stack that scrapes Hubble's *metrics* endpoint for the
    # time-series view — `metrics` below turns that endpoint on.
    hubble = {
      enabled = true

      # Per-flow Prometheus metrics. The enabled list is the metric
      # families Hubble exports on its metrics endpoint; the
      # Cilium/Hubble Grafana dashboard shipped with the
      # kube-prometheus-stack addon reads exactly these. Keep this list
      # and the dashboard in sync. `serviceMonitor.enabled` makes the
      # chart render a ServiceMonitor — see the CRD-ordering note on
      # `prometheus` below.
      metrics = {
        enabled = [
          "dns",
          "drop",
          "tcp",
          "flow",
          "port-distribution",
          "icmp",
          "httpV2",
        ]
        serviceMonitor = {
          enabled = true
        }
      }

      relay = {
        enabled = true
      }
      ui = {
        enabled = true
      }
    }

    # Cilium agent Prometheus metrics. `enabled` opens the agent's
    # metrics endpoint; `serviceMonitor.enabled` makes the chart render
    # a `monitoring.coreos.com/v1` ServiceMonitor so Prometheus scrapes
    # it (ADR-0007).
    #
    # CRD-ORDERING NOTE — load-bearing for a cold re-bootstrap. The
    # ServiceMonitor CRD (`monitoring.coreos.com/v1`) ships with the
    # kube-prometheus-stack ArgoCD app, which lands *after* this
    # bootstrap root. On the running cluster the CRD already exists, so
    # `tofu apply` here is clean. On a from-scratch re-bootstrap this
    # step renders ServiceMonitors before that CRD exists — apply the
    # kube-prometheus-stack CRDs first, or re-run this root once ArgoCD
    # has synced kube-prometheus-stack.
    prometheus = {
      enabled = true
      serviceMonitor = {
        enabled = true
      }
    }

    # securityContext capabilities documented by Talos+Cilium upstream as
    # required for the eBPF agent and the cleanup init container.
    securityContext = {
      capabilities = {
        ciliumAgent = [
          "CHOWN",
          "KILL",
          "NET_ADMIN",
          "NET_RAW",
          "IPC_LOCK",
          "SYS_ADMIN",
          "SYS_RESOURCE",
          "DAC_OVERRIDE",
          "FOWNER",
          "SETGID",
          "SETUID",
        ]
        cleanCiliumState = [
          "NET_ADMIN",
          "SYS_ADMIN",
          "SYS_RESOURCE",
        ]
      }
    }
  })]

  depends_on = [
    kubectl_manifest.gateway_api_crds,
  ]
}

# LoadBalancer IP pool. Sits above the Optimum DHCP scope (.11–.199) and
# below the static cluster range (.240–.247). AdGuard Home is pinned to
# .200 by an ArgoCD-managed Service annotation; the rest of the pool is
# allocated on demand.
resource "kubectl_manifest" "cilium_lb_pool" {
  yaml_body = yamlencode({
    apiVersion = "cilium.io/v2alpha1"
    kind       = "CiliumLoadBalancerIPPool"
    metadata = {
      name = "lab-pool"
    }
    spec = {
      blocks = [
        {
          start = var.lb_pool_start
          stop  = var.lb_pool_end
        },
      ]
    }
  })

  server_side_apply = true
  force_conflicts   = true

  depends_on = [helm_release.cilium]
}

# L2 announcements happen on workers only — control planes don't carry user
# traffic and announcing from them risks ARP flapping during a CP failover.
#
# Services carrying `homelab.jackhall.dev/l2-announce: "false"` opt out of
# L2 announcement. Cilium still allocates an LB-pool IP for them, but no
# worker ARP-answers for it on the LAN — the IP is unreachable from any
# LAN device by construction. The opt-out is currently used by the
# `projects` Gateway's auto-generated Service (ADR-0006, #142) so the
# preview-env surface stays a Cloudflare-Tunnel-only path. Gateway API
# v1's `spec.infrastructure.labels` is what propagates the label from
# the Gateway resource onto the generated Service.
#
# `NotIn ["false"]` matches services without the label at all
# (existing AdGuard, the lab Gateway, future LB Services) AND services
# whose label value isn't "false". The standard k8s LabelSelector
# semantics for NotIn cover the absent-key case (apimachinery
# pkg/labels/selector.go: `if !ls.Has(r.key) { return true }`).
resource "kubectl_manifest" "cilium_l2_announcement_policy" {
  yaml_body = yamlencode({
    apiVersion = "cilium.io/v2alpha1"
    kind       = "CiliumL2AnnouncementPolicy"
    metadata = {
      name = "lab-l2-workers"
    }
    spec = {
      loadBalancerIPs = true

      # Skip services that explicitly opt out of L2 announcement.
      serviceSelector = {
        matchExpressions = [
          {
            key      = "homelab.jackhall.dev/l2-announce"
            operator = "NotIn"
            values   = ["false"]
          },
        ]
      }

      # Exclude control-plane nodes by node label.
      nodeSelector = {
        matchExpressions = [
          {
            key      = var.control_plane_node_selector
            operator = "DoesNotExist"
          },
        ]
      }
    }
  })

  server_side_apply = true
  force_conflicts   = true

  depends_on = [helm_release.cilium]
}

# L7 proxy-port resync — mitigation for the 2026-05-15 lab-Gateway
# outage (#196). Cilium runs Envoy as a separate long-lived DaemonSet
# (external-envoy mode). Any change to `helm_release.cilium` rolls the
# cilium-agent DaemonSet, and a restarted agent re-allocates the L7
# (Gateway API) proxy ports — but the chart never rolls `cilium-envoy`,
# so the envoy pods keep their listeners on the OLD ports. eBPF then
# redirects every `*.lab.jackhall.dev` Gateway flow to a dead proxy
# port and the lab Gateway blackholes until envoy is restarted too.
#
# This resource force-rolls `cilium-envoy` whenever the Cilium release
# revision moves, closing that gap automatically on every apply that
# touches Cilium. It needs a `kubectl` binary on the apply runner — the
# bootstrap root already requires cluster kubeconfig access for its
# providers, so this only adds the binary dependency.
#
# Mitigation, not cure: a brief (~1-2 min) degraded window remains
# during the apply itself, and the underlying proxy-port instability is
# tied to running Cilium on a Kubernetes minor (1.36) ahead of every
# released Cilium release's e2e-tested matrix. #196 walks Cilium up one
# minor at a time toward 1.19.x (this is hop 1: 1.16 → 1.17). Keep this
# resource until that staged upgrade lands and a cilium-agent restart is
# shown not to desync the L7 proxy ports.
resource "terraform_data" "cilium_envoy_resync" {
  # Bumps on every helm upgrade of the Cilium release.
  triggers_replace = [helm_release.cilium.metadata[0].revision]

  provisioner "local-exec" {
    # `kubectl` must be on the apply runner; `--context` is passed only
    # when var.kube_context is set, matching providers.tf.
    command = <<-EOT
      kubectl --kubeconfig "${var.kubeconfig_path}" ${var.kube_context != "" ? "--context ${var.kube_context}" : ""} -n kube-system rollout restart daemonset/cilium-envoy &&
      kubectl --kubeconfig "${var.kubeconfig_path}" ${var.kube_context != "" ? "--context ${var.kube_context}" : ""} -n kube-system rollout status  daemonset/cilium-envoy --timeout=300s
    EOT
  }
}
