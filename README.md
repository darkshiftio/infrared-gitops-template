# infrared-gitops-template

The template the Infrared operator renders into a customer's **gitops repo**
when it bootstraps a **management cluster**. The result is a kubefirst-style
repo: a **registry** (`registry/clusters/<cluster>/`) holding the root
**app-of-apps**, one Argo CD **Application** per component ordered by
**sync wave**, and the vendored components those Applications point at.

The operator pins a template version (a git tag of this repo) per
installation. Everything below the heading "The rendering contract" is what
the operator relies on; change it only together with the operator.

## The rendering contract

1. The operator renders **every file under `template/`** into the gitops repo,
   preserving relative paths.
2. A file whose name ends in **`.tmpl`** is a Go `text/template` with
   delimiters **`[[` and `]]`**, so Helm's and Argo CD's `{{ }}` pass through
   untouched. It is executed with `missingkey=error`, text/template's builtins
   (`if`, `eq`, `printf`, …) and exactly these helpers, needle first:
   `contains`, `hasPrefix`, `hasSuffix` (e.g.
   `[[ if contains ".dkr.ecr." .BuildRegistry ]]`), `trimPrefix`,
   `trimSuffix`, `replace old new s`, `lower`, `upper`, `quote`,
   `default def v`. Nothing else (no sprig). The `.tmpl` suffix is stripped
   from the output path.
3. Every other file is **copied byte for byte**.
4. Any path **segment exactly equal to `__cluster__`** becomes the cluster
   name (the `.tmpl` suffix is stripped from the path first).
5. A template may render to a file that holds no objects (only comments);
   the file is still written. Argo CD reads it as empty.
   (`aws-load-balancer-controller.yaml` does this on k3s.)

### Data

Every `.tmpl` is executed against this value (JSON names equal Go names):

| Field | Example | Meaning |
|---|---|---|
| `.ClusterName` | `infrared-mgmt` | the management cluster's name; also the `__cluster__` segment |
| `.ClusterFlavor` | `k3s` \| `eks` | selects flavor-specific components |
| `.Region` | `us-east-1` | cloud region (may be empty for k3s outside a cloud) |
| `.OrgName` | `acme` | the Infrared Organization |
| `.GitopsRepoURL` | `https://github.com/acme/gitops.git` | clone URL Argo CD uses for this repo |
| `.GitopsRepoOwner` | `acme` | |
| `.GitopsRepoName` | `gitops` | |
| `.DefaultBranch` | `main` | `targetRevision` of every git-sourced Application |
| `.TemplateVersion` | `v0.1.0` | the tag of this repo that was rendered |
| `.InfraredVersion` | `v0.1.0` | the Infrared appVersion |
| `.InfraredChartRepo` | `ghcr.io/darkshiftio/charts` | OCI chart repo, **no `oci://`** |
| `.InfraredChartVersion` | `0.1.0` | the `infrared` chart version to pin |
| `.InfraredNamespace` | `infrared` | where the release lives |
| `.ImagePullSecret` | `` or `infrared-pull` | name of a pull Secret in `.InfraredNamespace`, empty for none |
| `.BuildRegistry` (JSON `buildRegistry`) | `` or `123456789012.dkr.ecr.us-east-1.amazonaws.com/acme` | registry prefix kpack pushes product images to (the operator's `INFRARED_BUILD_REGISTRY`, chart value `builds.registry`); empty turns builds off |

The operator's JSON uses camelCase names (`clusterName`, …); encoding/json
matches them case-insensitively, so `hack/render -data` reads either.

### What the operator does after rendering

1. Runs a kustomize build of **`components/argocd`** and **server-side
   applies** it (the CRDs outgrow the last-applied annotation). This
   directory is verbatim and needs no network to build.
2. Writes the Argo CD repository Secrets: one for the gitops repo itself, and
   **`argocd/infrared-oci-charts`** (labels
   `argocd.argoproj.io/secret-type: repository`; `type: helm`,
   `url: ghcr.io/darkshiftio/charts`, `enableOCI: "true"`, credentials when
   the charts are private). The template does not create either.
3. Applies **`registry/clusters/<cluster>/registry.yaml`**, the root
   Application `registry-<cluster>`. Everything else follows from it.

### Labels the operator selects on

Every Application this template creates carries
**`app.kubernetes.io/part-of: infrared-gitops`**. The template cannot know the
`<namespace>.<name>` of the GitopsRepo object, so the operator falls back to
this label to find the Applications it reports Synced/Healthy on.

### The infrared Application and adoption

The first `helm install` of the chart creates the release and its Secrets
(`infrared-setup`, `infrared-session`, `infrared-mcp-token`,
`infrared-api-tokens`) using `lookup`. Argo CD renders charts with
`helm template`, where `lookup` returns nothing, so the wave-40 `infrared`
Application sets `setup.existingSecret`, `session.existingSecret` and
`mcp.existingSecret`, which stop the chart rendering those Secrets at all.
Adoption therefore never rotates them. It uses `releaseName: infrared`,
`ServerSideApply=true`, and carries no resources finalizer, so deleting the
Application never deletes the CRDs and with them every Infrared object.

## Components

| Wave | Application | Source | Pin |
|---|---|---|---|
| — | `registry-<cluster>` (root) | this repo, `registry/clusters/<cluster>/components` | `.DefaultBranch` |
| 0 | `appprojects` | `components/appprojects` | — |
| 10 | `cert-manager` | https://charts.jetstack.io `cert-manager` | v1.21.2 |
| 10 | `external-secrets` | https://charts.external-secrets.io `external-secrets` | 2.11.0 |
| 10 | `aws-load-balancer-controller` (eks only) | https://aws.github.io/eks-charts | 3.5.0 |
| 15 | `infisical` | cloudsmith `infisical-standalone` + `components/infisical` | 1.11.0 |
| 25 | `kpack` | `components/kpack` (vendored `release-0.18.0.yaml`) | v0.18.0 |
| 26 | `builds` (only with `.BuildRegistry`) | `components/builds` | Paketo buildpacks and stack by digest |
| 30 | `victoria-metrics-k8s-stack` | https://victoriametrics.github.io/helm-charts/ | 0.95.0 |
| 40 | `infrared` | `.InfraredChartRepo` `infrared` | `.InfraredChartVersion` |
| 100 | `argocd` | `components/argocd` (vendored `install.yaml`) | v3.5.3 |

Every component Application has a sync wave, `SkipDryRunOnMissingResource=true`
(on an empty cluster CRDs arrive from sibling Applications in the background),
`CreateNamespace=true` where it owns a namespace, `ServerSideApply=true` where
it ships large CRDs, and `retry: {limit: 5, backoff: {duration: 10s, factor: 2,
maxDuration: 3m}}`, because Argo CD does not retry a failed automatic sync of
the same commit without one, and waves do not wait for a child Application to
be Healthy.

`components/argocd` patches upstream with `server.insecure: "true"` (access
is by port-forward), `kustomize.buildOptions: --enable-helm` and
`application.resourceTrackingMethod: annotation`. The `argocd` Application
does not prune automatically.

### Builds

With `.BuildRegistry` set, the wave-26 `builds` Application syncs
`components/builds`: namespaces `builds` (Pod Security restricted, where
products' kpack Images live) and, for ECR, `build-credentials` (privileged,
for the ECR login job's hostNetwork), ClusterStore `paketo`, ClusterStack
`noble`, ClusterBuilder `infrared-builder` (tag `<BuildRegistry>/kpack-builder`),
ServiceAccount `builds/builder`, and two credential jobs: `ecr-login` (ECR
only, node IAM role, every 6h) writes `builds/registry-push`, and
`github-token` (Infrared's GitHub App for the org, every 45m) writes
`builds/github-git` and `builds/git-credentials`. For a non-ECR registry the
org creates `builds/registry-push` itself. With `.BuildRegistry` empty, every
file of the component and `builds.yaml` render to a comment only.
`components/builds/README.md` is the operator's and org's reference.

The `infrared` Application passes `builds.registry: .BuildRegistry` to the
chart, so Argo CD's render keeps the operator's `INFRARED_BUILD_REGISTRY`.

### Products

A product's gitops lives in `products/<product>/` of the gitops repo
(`image.yaml`, the kpack Image, and one directory per zone). The org adds its
Applications in `registry/clusters/<cluster>/components/` with file names
starting `product-<product>-`. The template never renders into `products/`
or a `product-*` name, and hydration never deletes or overwrites a file it
does not render, so a re-hydration leaves both alone. Keep it that way: no
template file may be named `product-*` or live under `products/`.

### Infisical: known MVP limitations

- `infisical-secrets` (`ENCRYPTION_KEY`, `AUTH_SECRET`, `SITE_URL`) is created
  once by a PreSync hook Job in `components/infisical` (image
  `alpine/k8s:1.37.0`, pinned by digest) if absent, and never overwritten. To
  bring your own, create the Secret before the first sync.
- The bundled postgres and redis use the chart's **default passwords**
  (`root`, `mysecretpassword`). They are reachable only inside the cluster,
  but they are well known. Before anything real is stored, move to an
  external database (`postgresql.useExistingPostgresSecret`) or override
  `postgresql.auth.password` / `redis.auth.password` from a Secret.
- The chart stamps `updatedAt: now` on its Deployment; the Application
  ignores that annotation so it does not read as drift.

## Working on the template

```bash
make render CLUSTER=demo FLAVOR=k3s     # renders into out/
make render CLUSTER=demo FLAVOR=eks REGION=us-west-2
make render BUILD_REGISTRY=123456789012.dkr.ecr.us-east-1.amazonaws.com/acme
make verify                             # the CI gate
```

`hack/render` (Go, stdlib only) implements the contract exactly; run it with
`-h` for every Data flag, or `-data file.json` to render from the same JSON
the operator uses. `scripts/verify.sh` renders both flavors, each with and without a build
registry (plus a non-ECR one), and checks: no template syntax or
`__cluster__` left, flavor-specific components, YAML parses, Application
conventions, every non-empty `components/*` kustomization builds, builds is
fully present with a registry (ECR login only for ECR) and renders no objects
without one, and kubeconform (`-strict`, Argo CD kinds against the public
CRDs-catalog).

Bump upstream with `scripts/vendor-argocd.sh` / `scripts/vendor-kpack.sh`
(edit the version at the top), or by editing a chart `targetRevision`.

## Cutting a version

1. Merge to `main` with `make verify` green.
2. Tag `vX.Y.Z` (semver) on that commit and push the tag. Tags are
   immutable: never move one.
3. Bump the operator's default template version in a PR to
   infrared-operator. Existing installations keep the version they were
   bootstrapped with; the rendered repo is theirs from then on.

Breaking the rendering contract or the Data fields is a major version.
