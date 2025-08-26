argocd repo add us-central1-docker.pkg.dev \
    --name artifact-registry \
    --type helm \
    --enable-oci \
    --username _json_key \
    --password "$(cat gcp-service-account-key.json)"

kubectl create secret generic gcp-artifact-registry-secret \
    --from-file=.dockerconfigjson=config.json \
    --type=kubernetes.io/dockerconfigjson \
    --namespace=homelab
