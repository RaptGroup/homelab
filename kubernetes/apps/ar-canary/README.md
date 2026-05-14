# `ar-canary`

Canary slice for the preview-environment Artifact Registry repo
(issue [#125](https://github.com/RaptGroup/homelab/issues/125),
ADR-0006). One namespace, one cluster-pull credential path,
end-to-end verification recipe — exercising the pull surface
before the broader preview-env baseline ([#127](https://github.com/RaptGroup/homelab/issues/127))
templates the same shape into every preview namespace.

## What it provisions

| Resource                          | What it does                                                                                                                                                                              |
|-----------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `Namespace ar-canary`             | The single canary namespace for verification.                                                                                                                                             |
| `ServiceAccount ar-canary-puller` | The K8s identity ESO mints projected tokens for. Bound 1:1 to `tf-ci-cluster-pull` via the cluster WIF binding in `terraform/gcp/`.                                                       |
| `GCRAccessToken ar-pull-token`    | ESO generator that exchanges a `ar-canary-puller` projected token at GCP STS for a federated access token, then impersonates `tf-ci-cluster-pull` for an Artifact-Registry-scoped OAuth token. |
| `ExternalSecret ar-pull`          | Renders the generator output as a `kubernetes.io/dockerconfigjson` Secret, refreshed every 30 min.                                                                                        |

Pods in this namespace reference `ar-pull` as their
`imagePullSecrets` to pull from
`us-east4-docker.pkg.dev/rockingham-homelab/projects/<workload>:<tag>`.

## Credential path

```
K8s ServiceAccount `ar-canary-puller`   (no credentials of its own)
        │  ESO calls kube-apiserver TokenRequest API
        │  with audience = WIF provider's full resource name
        ▼
projected JWT signed by the cluster's SA signing key
        │  ESO POSTs JWT to sts.googleapis.com
        │  GCP STS fetches <issuer>/.well-known/openid-configuration
        │  + JWKS from gs://rockingham-homelab-oidc/ to validate
        ▼
federated access token (subject = K8s SA principal)
        │  ESO calls iamcredentials.googleapis.com to impersonate
        │  tf-ci-cluster-pull, authorized by the workloadIdentityUser
        │  binding in terraform/gcp/
        ▼
GCP access token scoped to roles/artifactregistry.reader on `projects`
        │  GCRAccessToken generator returns it
        ▼
K8s Secret `ar-pull` (kubernetes.io/dockerconfigjson, refresh 30m)
        │  imagePullSecrets reference
        ▼
Pod pulls from us-east4-docker.pkg.dev/rockingham-homelab/projects/<workload>:<tag>
```

The cluster-pull SA's role (`roles/artifactregistry.reader`, scoped to
the `projects` repo only) is the only thing constraining what the
resulting token can do. The generator does not constrain scope; the
IAM does.

## Why cluster→GCP WIF and not a JSON key

The "no long-lived keys" stance is satisfied for the ARC push path
(GitHub OIDC → GCP WIF, no key anywhere). The cluster pull path used
to fall short of that bar — Talos has no GKE-style metadata server,
and the early shape (#125) accepted a JSON key in GSM as a bounded
shortcut. #139 closed the gap by:

- Publishing the cluster's OIDC discovery document + JWKS at a
  public URL (a public-read GCS bucket served at
  `https://storage.googleapis.com/rockingham-homelab-oidc`).
- Pointing `kube-apiserver --service-account-issuer` at that URL
  via `talos/patches/cluster/oidc-issuer.yaml`.
- Adding a dedicated `cluster` WIF pool with a `talos` provider
  trusting that issuer.
- Binding `tf-ci-cluster-pull` to a single
  `principal://…/subject/system:serviceaccount:ar-canary:ar-canary-puller`,
  so only the puller SA above can impersonate it.

The cluster mints a fresh JWT per token-exchange, signed by its own
key, with the projected SA as the subject. Nothing long-lived is
stored anywhere on the pull path.

The bound posture is wider in *who* can impersonate than the JSON-key
shortcut allowed (anything that could read GSM secrets could, in
principle, decode the key), but narrower in *what* a leak grants — a
stolen projected JWT expires within an hour and cannot be replayed
after the cluster's signing key rotates.

## End-to-end verification

Preconditions:

- `tofu apply` in `terraform/gcp/` has landed the AR repo, the SAs,
  the cluster WIF pool/provider, and the OIDC bucket.
- The Talos issuer patch (`talos/patches/cluster/oidc-issuer.yaml`)
  has been applied to every control plane.
- The cluster's JWKS has been uploaded to
  `gs://rockingham-homelab-oidc/openid/v1/jwks` (see talos/README.md).
- ArgoCD has reconciled this addon (`kubectl -n argocd get app ar-canary`
  shows `Synced + Healthy`).

1. Confirm the dockerconfigjson Secret is populated:

   ```sh
   kubectl -n ar-canary get secret ar-pull \
     -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq .
   ```

   Expect a single `auths` entry for `us-east4-docker.pkg.dev` with
   a non-empty `password` field. If `ar-pull` is missing, walk the
   chain:

   - `kubectl -n ar-canary get externalsecret ar-pull -o yaml` —
     the status conditions explain why ESO couldn't render the
     dockerconfigjson.
   - `kubectl -n external-secrets logs deploy/external-secrets` —
     look for "unable to exchange token" (STS rejection, usually
     means the JWKS hasn't been uploaded or doesn't match the
     cluster's current signing key), or "permission denied"
     (workloadIdentityUser binding missing or pointing at the wrong
     principal).
   - `curl -s https://storage.googleapis.com/rockingham-homelab-oidc/openid/v1/jwks | jq .keys[].kid`
     and compare against `kubectl get --raw /openid/v1/jwks | jq .keys[].kid`
     — they must match.

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
templates the `ServiceAccount` + `GCRAccessToken` + `ExternalSecret`
shape into every preview namespace, this entire directory is deleted
in the same PR. The TF-managed AR repo, the SAs (`tf-ci-cluster-pull`,
`tf-ci-arc-push`), the cluster WIF pool/provider, and the OIDC bucket
all stay; only the cluster-side YAML moves to the preview-env
baseline. The cluster WIF binding likely also widens at that point
from a single `principal://…/subject/system:serviceaccount:ar-canary:ar-canary-puller`
to a `principalSet://…/attribute.namespace/<preview-pattern>` so one
binding covers every preview namespace at once.
