.PHONY: help smoke smoke-cilium smoke-bootstrap lint-apps

help:
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ {printf "  %-18s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

smoke: smoke-cilium smoke-bootstrap ## Run post-bootstrap smoke tests against the current kubeconfig context

smoke-cilium: ## cilium-cli connectivity test against the current cluster
	cilium connectivity test

smoke-bootstrap: ## Assert wildcard Certificate, LE ClusterIssuer, and gsm ClusterSecretStore are Ready=True
	scripts/check-bootstrap.sh

lint-apps: ## helm template + kubeconform every kubernetes/apps/<name>/
	scripts/lint-apps.sh
