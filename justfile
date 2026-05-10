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
