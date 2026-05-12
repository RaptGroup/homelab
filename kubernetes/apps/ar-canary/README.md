# `ar-canary`

Canary slice for the preview-environment Artifact Registry repo
(issue [#125](https://github.com/RaptGroup/homelab/issues/125),
ADR-0006). One namespace, one cluster-pull credential path,
end-to-end verification recipe — exercising the pull surface
before the broader preview-env baseline ([#127](https://github.com/RaptGroup/homelab/issues/127))
templates the same shape into every preview namespace.

## What it provisions

| Resource                              | What it does                                                                                        |
|---------------------------------------|-----------------------------------------------------------------------------------------------------|
| `Namespace ar-canary`                 | The single canary namespace for verification.                                                       |
| `ExternalSecret ar-pull-sa-key`       | Syncs the `tf-ci-cluster-pull` JSON key from GSM (`tf-ci-cluster-pull-key`) into a K8s Secret.      |
| `GCRAccessToken ar-pull-token`        | ESO generator that exchanges the JSON key for a short-lived GCP OAuth access token.                 |
| `ExternalSecret ar-pull`              | Renders the generator output as a `kubernetes.io/dockerconfigjson` Secret, refreshed every 30 min.  |

Pods in this namespace reference `ar-pull` as their
`imagePullSecrets` to pull from
`us-east4-docker.pkg.dev/rockingham-homelab/projects/<workload>:<tag>`.

## Credential path

```
GSM secret `tf-ci-cluster-pull-key`  (long-lived JSON key, value uploaded out of band)
        │  ESO ClusterSecretStore `gsm` (refresh 1h)
        ▼
K8s Secret `ar-pull-sa-key` (Opaque, namespace-scoped to ar-canary)
        │  GCRAccessToken generator
        ▼
K8s Secret `ar-pull` (kubernetes.io/dockerconfigjson, refresh 30m)
        │  imagePullSecrets reference
        ▼
Pod pulls from us-east4-docker.pkg.dev/rockingham-homelab/projects/<workload>:<tag>
```

The cluster-pull SA's role
(`roles/artifactregistry.reader`, scoped to the `projects` repo only)
is the only thing constraining what the resulting token can do. The
generator does not constrain scope; the IAM does.

## Why a JSON key and not native cluster→GCP WIF

The "no long-lived keys" stance is satisfied for the ARC push path
(GitHub OIDC → GCP WIF, no key anywhere). The cluster pull path
falls short of that bar because Talos has no GKE-style workload
identity: minting GCP credentials from a Pod requires either a
JSON key or a public Talos OIDC discovery document configured as
a trusted identity provider on a GCP WIF pool. Publishing the
cluster's OIDC discovery is meaningful work — Talos's default
issuer URL is cluster-internal, so it needs a separate
GCS-bucket-backed endpoint plus the matching `--service-account-issuer`
Talos config — and is out of scope for this issue.

The compromise the canary lives with:

- The JSON key is long-lived but lives in GSM, not in TF state or
  in Git. Same posture as `argocd-repo-ssh-key`,
  `arc-app-private-key`, and `talos-cluster-secrets` — three other
  load-bearing credentials this repo accepts in GSM.
- The key's role is repo-scoped (`roles/artifactregistry.reader`
  on `projects`), so a leak grants read on preview-env images only.
- The dockerconfigjson Pods reference is short-lived (30 min); the
  long-lived credential never leaves the
  `ar-canary` (eventually: `projects-*`) namespace.
- Migrating to cluster→GCP WIF is a one-resource swap: replace the
  ExternalSecret + GCRAccessToken pair with a Pod-mounted SA token
  exchange. Nothing about the AR repo, the SAs, or the IAM
  bindings changes.

## End-to-end verification

After `tofu apply` in `terraform/gcp/` has landed the AR repo, the
two SAs, and the GSM container, and after ArgoCD has reconciled
this addon:

1. Confirm the dockerconfigjson Secret is populated:

   ```sh
   kubectl -n ar-canary get secret ar-pull \
     -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq .
   ```

   Expect a single `auths` entry for `us-east4-docker.pkg.dev` with
   a non-empty `password` field. If `ar-pull` is missing, check
   the chain: `kubectl -n ar-canary get externalsecret`,
   `kubectl -n external-secrets logs deploy/external-secrets`.

2. Push a test image as the operator (one-time):

   ```sh
   gcloud auth login
   gcloud auth configure-docker us-east4-docker.pkg.dev --quiet
   docker pull docker.io/library/hello-world:latest
   docker tag docker.io/library/hello-world:latest \
     us-east4-docker.pkg.dev/rockingham-homelab/projects/hello-world:canary
   docker push us-east4-docker.pkg.dev/rockingham-homelab/projects/hello-world:canary
   ```

3. Schedule a Pod that pulls the image using `ar-pull`:

   ```sh
   kubectl -n ar-canary run pull-test \
     --image=us-east4-docker.pkg.dev/rockingham-homelab/projects/hello-world:canary \
     --restart=Never \
     --overrides='{"spec":{"imagePullSecrets":[{"name":"ar-pull"}]}}' \
     --attach --rm
   ```

   `hello-world` prints its greeting and exits 0. That's the
   acceptance criterion satisfied — a Pod scheduled in the cluster
   pulled a private image from the new repo via the cluster-pull
   SA's credentials.

   If the pull fails with `ImagePullBackOff` /
   `denied: Permission "artifactregistry.repositories.downloadArtifacts"
   denied`, walk back: is the dockerconfigjson populated (step 1)?
   Is the SA's reader binding present in
   `tofu state list -state=…` and on the repo in the GCP console?

## Cleanup

When the preview-env baseline ([#127](https://github.com/RaptGroup/homelab/issues/127))
templates the `ExternalSecret` + `GCRAccessToken` pair into every
preview namespace, this entire directory is deleted in the same PR.
The TF-managed SAs, IAM bindings, AR repo, and GSM key container
stay; only the cluster-side YAML moves to the preview-env baseline.
