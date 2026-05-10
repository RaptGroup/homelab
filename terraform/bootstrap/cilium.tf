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

    # Hubble flow visibility ships with Cilium and is the entire Tier 1
    # observability story (ADR-0003 / observability memory). UI is exposed
    # via Gateway API later as an ArgoCD app, not here.
    hubble = {
      enabled = true
      relay = {
        enabled = true
      }
      ui = {
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
resource "kubectl_manifest" "cilium_l2_announcement_policy" {
  yaml_body = yamlencode({
    apiVersion = "cilium.io/v2alpha1"
    kind       = "CiliumL2AnnouncementPolicy"
    metadata = {
      name = "lab-l2-workers"
    }
    spec = {
      # Match every Service of type LoadBalancer (no serviceSelector means all).
      loadBalancerIPs = true

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
