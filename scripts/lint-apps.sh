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

# Skip:
#  - Application/AppProject — ArgoCD CRDs, out of scope for this lint.
#  - AutoscalingRunnerSet — ARC's CR; actions.github.com isn't on the
#    datreeio catalog and ARC ships no JSON schema upstream.
#  - CustomResourceDefinition — kubeconform's default set deliberately
#    excludes apiextensions.k8s.io. Charts that ship CRDs (the controller
#    chart's --include-crds output is the trigger here) would otherwise
#    fail with "could not find schema for CustomResourceDefinition" on
#    every entry. CRDs ship from upstream charts and are trusted as-is.
SKIP_KINDS="Application,AppProject,AutoscalingRunnerSet,CustomResourceDefinition"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required tool: $1" >&2
    exit 127
  fi
}

require helm
require kubeconform
require yq

# Scan YAML files for Gateway and LoadBalancer Service resources that are
# missing the `lbipam.cilium.io/ips` annotation. Cilium's lbipam.cilium.io
# IPAM hands out the first free address from the pool when no pin is
# requested; the pin is what makes the assignment deterministic across
# re-deploys and out-of-order merges. Without it, a new addon's Gateway can
# silently grab a pinned IP another addon depends on (see #28/#38, the
# incidents this guard prevents). Presence-only — value format and pool
# membership are Cilium's concern.
#
# Carve-out: Gateways whose listeners are gated by a namespaceSelector
# (`allowedRoutes.namespaces.from == "Selector"`) are by-construction not
# LAN-routable surfaces — they exist to receive traffic from a known set
# of namespaces, not to be advertised at a pinned LAN IP. The first such
# Gateway is `projects` (ADR-0006), which intentionally takes whatever
# free address Cilium assigns (or, on a future Cilium 1.18+ upgrade, no
# LB IP at all). Pinning the IP would put a preview-env surface on the
# LB pool's LAN-visible range, contradicting ADR-0006's "no LAN
# exposure" intent. The selector form is the structural marker; the
# script trusts it instead of needing a separate opt-out annotation.
check_lb_pins() {
  local app_name="$1"
  shift

  local rc=0
  local f
  for f in "$@"; do
    [[ -f "$f" ]] || continue

    local missing
    missing="$(yq eval-all '
      select(
        (
          .kind == "Gateway"
          and
          ([.spec.listeners[]?.allowedRoutes.namespaces.from] | all_c(. == "Selector") | not)
        )
        or
        (.kind == "Service" and .spec.type == "LoadBalancer")
      )
      | select((.metadata.annotations."lbipam.cilium.io/ips" // "") == "")
      | (.kind + " " + (.metadata.namespace // "default") + "/" + .metadata.name)
    ' "$f")" || missing=""

    if [[ -n "$missing" ]]; then
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        echo "    missing lbipam.cilium.io/ips on ${line} (source: $(basename "$f"))" >&2
      done <<< "$missing"
      rc=1
    fi
  done

  if [[ $rc -ne 0 ]]; then
    echo "    add the annotation to each resource above; see CONTEXT.md 'LB pool' for the next free IP" >&2
  fi

  return $rc
}

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

  local rendered=""
  local rc=0

  if [[ -n "$chart" && -n "$repo" ]]; then
    # kubeconform skips files without a recognised manifest extension, so
    # mktemp's bare name silently renders an empty validation. Force .yaml.
    rendered="$(mktemp).yaml"
    local helm_args=(template "$app_name")
    # OCI repos can't be passed via --repo (helm errors with "could not
    # find protocol handler"). The Argo convention stores them with the
    # bare hostname as repoURL — fold that back into an oci:// chart URL
    # for the CLI. HTTP(S) repos take the classic --repo form.
    if [[ "$repo" =~ ^https?:// ]]; then
      helm_args+=("$chart" --repo "$repo")
    else
      helm_args+=("oci://${repo%/}/${chart}")
    fi
    helm_args+=(--include-crds)
    [[ -n "$version" ]] && helm_args+=(--version "$version")
    [[ -f "$values_file" ]] && helm_args+=(-f "$values_file")
    helm "${helm_args[@]}" >"$rendered" \
      && kubeconform -strict -summary -skip "$SKIP_KINDS" \
        "${SCHEMA_LOCATIONS[@]}" "$rendered" \
      || rc=$?
  else
    echo "    no spec.source.chart in application.yaml — skipping helm template"
  fi

  if [[ $rc -eq 0 && -d "$manifests_dir" ]]; then
    echo "    manifests/"
    kubeconform -strict -summary -skip "$SKIP_KINDS" \
      "${SCHEMA_LOCATIONS[@]}" "$manifests_dir" || rc=$?
  fi

  if [[ $rc -eq 0 ]]; then
    local check_files=()
    [[ -n "$rendered" ]] && check_files+=("$rendered")
    if [[ -d "$manifests_dir" ]]; then
      while IFS= read -r m; do
        check_files+=("$m")
      done < <(find "$manifests_dir" -type f \( -name '*.yaml' -o -name '*.yml' \))
    fi
    if [[ ${#check_files[@]} -gt 0 ]]; then
      check_lb_pins "$app_name" "${check_files[@]}" || rc=$?
    fi
  fi

  [[ -n "$rendered" ]] && rm -f "$rendered"
  return $rc
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
