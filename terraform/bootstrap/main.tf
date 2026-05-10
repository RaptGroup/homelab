# terraform/bootstrap is split by component for readability. Each step in
# the bootstrap order documented in README.md lives in its own file:
#
#   gateway-api-crds.tf  — step 1: Gateway API CRDs (standard channel)
#   cilium.tf            — step 2: Cilium CNI + LB pool + L2 announcements
#   cert-manager.tf      — step 3: cert-manager + ClusterIssuer + wildcard Certificate
#   external-secrets.tf  — step 4: ESO + bootstrap GSM SA Secret + ClusterSecretStore
#   local-path.tf        — step 5: local-path-provisioner (default StorageClass)
#   argocd.tf            — step 6: Argo CD + self-managed Application + root app-of-apps
#
# Ordering between steps is enforced via `depends_on` on the Helm releases
# and `kubectl_manifest` resources in those files. main.tf is intentionally
# empty of resources — there is nothing that doesn't belong to a numbered
# step.
