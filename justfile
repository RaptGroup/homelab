default:
    @just --list

# Run post-bootstrap smoke tests against the current kubeconfig context
smoke: smoke-cilium smoke-bootstrap

# cilium-cli's test namespaces — `cilium-test-1` plus the `cilium-test-ccnp*`
# pair for the CiliumClusterwideNetworkPolicy tests — would otherwise inherit
# Talos's cluster-wide PodSecurity default (`enforce: baseline`), which
# rejects the test fixtures: they need NET_RAW, hostNetwork, and hostPort.
# cilium-cli's `--namespace-labels` flag reaches only the primary namespace,
# so pre-create all of them `privileged` instead — cilium-cli reuses an
# existing namespace as-is. Names track cilium-cli's convention for the
# default `--test-concurrency 1`.
#
# Two checks are excluded as unreliable on this homelab, so `just smoke`
# stays a clean pass/fail gate:
#   - no-unexpected-packet-drops trips on ambient VLAN-tagged LAN traffic
#     that Cilium drops by design ("VLAN traffic disallowed by VLAN filter").
#   - check-log-errors scans the full agent log and re-flags benign
#     agent-startup transients (e.g. a one-off cilium-health socket poll
#     racing agent start) long after they stopped mattering.
# Run `cilium connectivity test` directly, without the excludes, for a full
# conformance pass.

# cilium-cli connectivity test against the current cluster
smoke-cilium:
    #!/usr/bin/env bash
    set -euo pipefail
    for ns in cilium-test-1 cilium-test-ccnp1 cilium-test-ccnp2; do
      kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
      kubectl label namespace "$ns" --overwrite \
        pod-security.kubernetes.io/enforce=privileged \
        pod-security.kubernetes.io/warn=privileged \
        pod-security.kubernetes.io/audit=privileged
    done
    cilium connectivity test --test '!no-unexpected-packet-drops' --test '!check-log-errors'

# Assert wildcard Certificate, LE ClusterIssuer, and gsm ClusterSecretStore are Ready=True
smoke-bootstrap:
    scripts/check-bootstrap.sh

# helm template + kubeconform every kubernetes/apps/<name>/
lint-apps:
    scripts/lint-apps.sh

# Bring up a preview namespace: gating label, baseline, optional --ttl=<dur>.
preview-up NAME *FLAGS:
    #!/usr/bin/env bash
    set -euo pipefail
    name="{{NAME}}"
    ttl=""
    for flag in {{FLAGS}}; do
      case "$flag" in
        --ttl=*) ttl="${flag#--ttl=}" ;;
        *) echo "preview-up: unknown flag: $flag" >&2; exit 2 ;;
      esac
    done

    kubectl create namespace "$name" --dry-run=client -o yaml | kubectl apply -f -
    kubectl label namespace "$name" projects.jackhall.dev/enabled=true --overwrite

    if [[ -n "$ttl" ]]; then
      num="${ttl%[smhd]}"
      unit="${ttl: -1}"
      case "$unit" in
        s) secs="$num" ;;
        m) secs="$(( num * 60 ))" ;;
        h) secs="$(( num * 3600 ))" ;;
        d) secs="$(( num * 86400 ))" ;;
        *) echo "preview-up: invalid --ttl unit '$unit' (use s/m/h/d)" >&2; exit 2 ;;
      esac
      if expiry="$(date -u -v+"${secs}"S +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)"; then
        :
      else
        expiry="$(date -u -d "+${secs} seconds" +"%Y-%m-%dT%H:%M:%SZ")"
      fi
      kubectl annotate namespace "$name" "projects.jackhall.dev/ttl=$expiry" --overwrite
    fi

    kubectl apply -k kubernetes/preview-env-baseline -n "$name"

    echo
    echo "preview namespace '$name' ready."
    echo "  HTTPRoute hostname pattern: <svc>-${name}.projects.jackhall.dev"
    if [[ -n "$ttl" ]]; then
      echo "  TTL: expires at $expiry (annotation projects.jackhall.dev/ttl)"
    fi

# Tear down a preview namespace (non-blocking, idempotent).
preview-down NAME:
    kubectl delete namespace {{NAME}} --wait=false --ignore-not-found
