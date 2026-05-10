#!/usr/bin/env bash
# Render each kubernetes/apps/<name>/ Helm chart against its helm-values.yaml
# and validate the output (plus any raw manifests/) with kubeconform.
#
# Usage:
#   scripts/lint-apps.sh                       # lint every kubernetes/apps/<name>/
#   scripts/lint-apps.sh kubernetes/apps/foo   # lint specific dirs
#
# Requires: helm, kubeconform, yq (mikefarah).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPS_DIR="${REPO_ROOT}/kubernetes/apps"

# Datreeio's catalog covers cilium.io, cert-manager.io,
# gateway.networking.k8s.io, and external-secrets.io.
SCHEMA_LOCATIONS=(
  -schema-location default
  -schema-location
  'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
)

# ArgoCD CRDs aren't in scope for this lint; skip the application.yaml kinds
# rather than pulling in another schema set.
SKIP_KINDS="Application,AppProject"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required tool: $1" >&2
    exit 127
  fi
}

require helm
require kubeconform
require yq

lint_app() {
  local app_dir="$1"
  local app_name
  app_name="$(basename "$app_dir")"
  local app_file="$app_dir/application.yaml"
  local values_file="$app_dir/helm-values.yaml"
  local manifests_dir="$app_dir/manifests"

  echo "==> ${app_name}"

  if [[ ! -f "$app_file" ]]; then
    echo "    application.yaml missing — skipping"
    return 0
  fi

  # Apps may use either spec.source (single) or spec.sources[] (multi-source
  # — chart in one source, $values from this repo in another). For linting
  # we only need the chart-bearing source.
  local repo chart version
  repo="$(yq -r '.spec.source.repoURL // (.spec.sources // [] | map(select(.chart != null)) | .[0].repoURL // "")' "$app_file")"
  chart="$(yq -r '.spec.source.chart // (.spec.sources // [] | map(select(.chart != null)) | .[0].chart // "")' "$app_file")"
  version="$(yq -r '.spec.source.targetRevision // (.spec.sources // [] | map(select(.chart != null)) | .[0].targetRevision // "")' "$app_file")"

  if [[ -n "$chart" && -n "$repo" ]]; then
    # kubeconform skips files without a recognised manifest extension, so
    # mktemp's bare name silently renders an empty validation. Force .yaml.
    local rendered
    rendered="$(mktemp).yaml"
    local helm_args=(template "$app_name" "$chart" --repo "$repo" --include-crds)
    [[ -n "$version" ]] && helm_args+=(--version "$version")
    [[ -f "$values_file" ]] && helm_args+=(-f "$values_file")
    local rc=0
    helm "${helm_args[@]}" >"$rendered" \
      && kubeconform -strict -summary -skip "$SKIP_KINDS" \
        "${SCHEMA_LOCATIONS[@]}" "$rendered" \
      || rc=$?
    rm -f "$rendered"
    [[ $rc -ne 0 ]] && return $rc
  else
    echo "    no spec.source.chart in application.yaml — skipping helm template"
  fi

  if [[ -d "$manifests_dir" ]]; then
    echo "    manifests/"
    kubeconform -strict -summary -skip "$SKIP_KINDS" \
      "${SCHEMA_LOCATIONS[@]}" "$manifests_dir"
  fi
}

main() {
  local targets=()
  if [[ $# -gt 0 ]]; then
    targets=("$@")
  else
    if [[ ! -d "$APPS_DIR" ]]; then
      echo "no apps directory at ${APPS_DIR} — nothing to lint"
      return 0
    fi
    shopt -s nullglob
    for d in "$APPS_DIR"/*/; do
      targets+=("${d%/}")
    done
    shopt -u nullglob
  fi

  if [[ ${#targets[@]} -eq 0 ]]; then
    echo "no apps to lint"
    return 0
  fi

  local failed=()
  for app_dir in "${targets[@]}"; do
    if ! lint_app "$app_dir"; then
      failed+=("$app_dir")
    fi
  done

  if [[ ${#failed[@]} -gt 0 ]]; then
    echo
    echo "FAILED: ${failed[*]}" >&2
    return 1
  fi
}

main "$@"
