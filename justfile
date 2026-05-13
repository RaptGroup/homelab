default:
    @just --list

# Run post-bootstrap smoke tests against the current kubeconfig context
smoke: smoke-cilium smoke-bootstrap

# cilium-cli connectivity test against the current cluster
smoke-cilium:
    cilium connectivity test

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
