#!/usr/bin/env bash
# Assert that the bootstrap-managed resources whose Ready condition gates the
# rest of the cluster are actually Ready against the current kubeconfig
# context. Read-only — uses the operator's existing credentials.
#
# Checked:
#   1. Certificate cert-manager/wildcard-lab-jackhall-dev (the *.lab.jackhall.dev
#      wildcard every addon Gateway TLS-terminates with)
#   2. ClusterIssuer letsencrypt-dns01 (the LE DNS-01 issuer the wildcard
#      Certificate above renews against)
#   3. ClusterSecretStore gsm (the cluster-wide GSM backend every ExternalSecret
#      in kubernetes/apps/<name>/ binds to)
#
# Each resource is given $TIMEOUT (default 60s) to reach Ready=True so the
# script is useful immediately after `tofu apply terraform/bootstrap/`, where
# the wildcard Certificate can take ~2 minutes to issue against staging or
# production LE.
#
# Usage:
#   scripts/check-bootstrap.sh
#   TIMEOUT=180s scripts/check-bootstrap.sh

set -euo pipefail

TIMEOUT="${TIMEOUT:-60s}"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required tool: $1" >&2
    exit 127
  fi
}

require kubectl

# Resources to assert as `kind|namespace-or-empty|name`. Cluster-scoped kinds
# leave the namespace field empty.
RESOURCES=(
  "certificate.cert-manager.io|cert-manager|wildcard-lab-jackhall-dev"
  "clusterissuer.cert-manager.io||letsencrypt-dns01"
  "clustersecretstore.external-secrets.io||gsm"
)

failed=()
for entry in "${RESOURCES[@]}"; do
  IFS='|' read -r kind ns name <<<"$entry"
  label="${kind}/${name}"
  [[ -n "$ns" ]] && label="${kind} -n ${ns}/${name}"

  # Cluster-scoped kinds leave ns_args empty. Expansions below use the
  # `"${ns_args[@]+"${ns_args[@]+"${ns_args[@]}"}"}"` form because a bare `"${ns_args[@]+"${ns_args[@]}"}"`
  # on an empty array under `set -u` is an "unbound variable" error in
  # bash 3.2 (macOS's /bin/bash) — only made safe in bash 4.4.
  ns_args=()
  [[ -n "$ns" ]] && ns_args=(-n "$ns")

  echo "==> ${label}"
  if ! kubectl wait "${ns_args[@]+"${ns_args[@]}"}" --for=condition=Ready=True \
      --timeout="$TIMEOUT" "${kind}/${name}"; then
    failed+=("$label")
    # Surface the underlying status so the operator does not need a second
    # describe to see *why* the wait failed (e.g. DNS-01 propagation,
    # missing GSM SA key).
    kubectl describe "${ns_args[@]+"${ns_args[@]}"}" "${kind}/${name}" >&2 || true
  fi
done

if [[ ${#failed[@]} -gt 0 ]]; then
  echo
  echo "FAILED: ${failed[*]}" >&2
  exit 1
fi

echo
echo "bootstrap resources Ready=True"
