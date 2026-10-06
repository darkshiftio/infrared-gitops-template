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
| `.Edge` | `` \| `traefik` \| `gateway` | the Installation's `spec.edge`. `` and `traefik` both mean Traefik, as before; `gateway` turns on the edge (see "The edge"). Test it with `eq .Edge "gateway"`, never `if .Edge` |
| `.PlatformDomain` | `` or `preprod.example.com` | the Installation's `spec.previews.domain`; in gateway mode zones answer at `<zone>.<PlatformDomain>` |
| `.InfraredHost` | `` or `infrared.preprod.example.com` | the host of the Installation's `spec.previews.signInURL`, lowercase, no port; in gateway mode Infrared's own name |
| `.ImageRegistry` | `` or `ghcr.io/darkshiftio` | the registry of Infrared's own images (`INFRARED_IMAGE_REGISTRY`); empty keeps the chart's |
| `.Images` | `{"api": {"Tag": "v0.1.0", "Digest": "sha256:…"}, …}` | each component's pin (`INFRARED_IMAGES`), keyed `operator`, `api`, `ui`, `mcp`, `runner`, and `code-index`, which the chart hands on only with `codeIndex.enabled` (see "The code index"); empty keeps the chart's. Read an entry with `index .Images "api"` (a missing key is the zero pin; `.Images.api` would fail the render), and test its `.Tag` or `.Digest`: `with` on an entry always runs |
| `.Cloud` | `` \| `aws` \| `linode` | the cloud of the nodes, from their providerID; `` is any other, or none |
| `.SubstrateCapable` | `false` | the operator's preflight: whether the cluster can host Agent Substrate. With `.Stores` and `.Registry` too, the template runs Substrate (see "Agent Substrate"); while it is false, or either of those is unset, the template leaves Substrate out |
| `.Stores` | `false` \| `true` | the operator's `INFRARED_STORES`: `true` renders the platform's own stores, CloudNativePG with one Postgres Cluster and SeaweedFS (see "The stores"), and on k3s keeps VMSingle's metrics on an `emptyDir` (see "Metrics with the stores") |
| `.Backup` | `{"Bucket": "acme-backups", "Endpoint": "https://us-east-1.linodeobjects.com", "Region": "us-east-1", "Prefix": "", "Credentials": {"Secret": "", "AccessKeyIDKey": "", "SecretKeyKey": "", "Kind": ""}}` | the Installation's `spec.backup.destination`, which the operator seeds from its `INFRARED_BACKUP`: an S3-compatible bucket outside the cluster that the stores are copied to and the backups written to. An empty `.Backup.Bucket` turns backups off, and with `.Stores` false there is nothing to copy. `.Backup.Endpoint` is empty for AWS S3; `.Backup.Region` may be empty. `.Backup.Prefix` is the path everything is kept under in the bucket, `<prefix>` below; empty is `.ClusterName`, as before the field existed. `.Backup.Credentials` is where the bucket's key is: the Secret in `.InfraredNamespace` and its two keys, and the credential's kind; each empty field is today's, `infrared-platform-tokens`, `backup-access-key-id`, `backup-secret-access-key` and `accessKey`, and the operator may send those explicitly, which renders the same files. Day one reads no other Secret or kind (`hack/render` refuses them) |
| `.Disabled` | `[]` or `["infisical"]` | the operator's `INFRARED_DISABLED_COMPONENTS`: components, by Application name, that the template leaves out (see "Disabled components"), and `substrate-test-actors`, Substrate's test actors (see "Agent Substrate"). No helper tests a list, so a template ranges over it: `[[ range .Disabled ]][[ if eq . "infisical" ]][[ $on = false ]][[ end ]][[ end ]]` |
| `.Forge` | `` \| `gitea` | the forge the org's repos live on: `gitea` when the platform org's GitProvider is the Gitea the Infrared chart runs, `` for GitHub, as before (the operator never passes `github`). Test it with `eq .Forge "gitea"` |
| `.ForgeURL` | `` or `http://gitea-http.infrared.svc.cluster.local:3000` | the forge's root as the cluster reaches it, without a trailing slash: repos are `<ForgeURL>/<owner>/<repo>`. Empty for GitHub |
| `.Registry` | `` or `10.43.0.50:5000` | the operator's `INFRARED_REGISTRY` (chart value `registry.address`): the address of the registry inside the cluster, a private IPv4 address and a port. With `.Stores` the template runs Zot there, its Service's pinned ClusterIP and port, and builds push the builder to it (see "The registry"). Empty: no registry inside the cluster |
| `.Copies` | `{"Recipients": ["age1..."], "Mirror": {"Schedule": "17 * * * *", "Retention": "7d"}}` | the rest of the Installation's `spec.backup` that the template renders (the operator seeds it from its `INFRARED_COPIES`, chart values `backup.*`): the buckets' mirror, its schedule (five cron fields) and how long what a run replaced or deleted is kept (whole days, `spec.backup.retention`), and the age recipients the backups are encrypted to. With the stores, a backup bucket and `.Copies.Recipients`, backups are on: the mirror's run mark names the newest complete backup, and the Postgres roles the backup dumps as reach `.InfraredNamespace` (see "Backups"). Every empty field keeps today's literal |
| `.PostgresArchive` | `{"Enabled": false, "Schedule": "0 0 3 * * *", "Retention": "7d"}` | Barman's WAL archive of the platform's Postgres: `Enabled` is `spec.backup.postgres.archive`, which the `infrared` Application carries; `Schedule` is the base backup's (six cron fields, seconds first) and `Retention` the archive's (whole days). Every empty field keeps today's literal |
| `.RegistryRetention` | `{"UntaggedAfter": "24h", "KeepTags": ["^v[0-9]"], "KeepNewest": 10, "GCInterval": "1h", "GCDelay": "1h"}` | the operator's `INFRARED_REGISTRY_RETENTION` (chart value `registry.retention`): Zot's garbage collection and retention (see "The registry"). Every zero field keeps today's literal, shown here |
| `.Restore` | `{"Point": "20261006T010500Z", "Artifact": "20261006T010500Z.irbackup", "MirrorRun": "20261006T011700Z"}` | the restore in progress, which the operator reads from the ConfigMap `infrared/infrared-restore` while its phase is `ObjectsRestored` or `Failed`, and zero otherwise: `Point` is the stamp of the backup restored, `Artifact` its object under `<prefix>/backups/`, `MirrorRun` the mirror run the buckets come back from, a run after the point. With the stores and a backup bucket it brings the stores back (see "Restore") |
| `.PostgresServerName` | `` or `postgres-20261003T060000Z` | the server name the platform's Postgres archives under, `<Backup.Bucket>/<prefix>/postgres/<name>/`. The operator chooses one per install, and on a restore a new one: it must name an empty prefix, and it never changes for the life of the install. Empty archives under `postgres`, the Cluster's name, as before the field existed |

The operator's JSON uses camelCase names for the older fields (`clusterName`,
…) and the Go names for the newer ones (`Edge`, `PlatformDomain`, …);
encoding/json matches them case-insensitively, so `hack/render -data` reads
either, and `Backup`'s keys as `INFRARED_BACKUP` spells them (`bucket`, …).
`hack/render` takes `-stores`, `-backup` as JSON and `-disabled` as a JSON
array, exactly as the operator's environment carries them, `-forge` with
`-forge-url`, and `-registry`; `-registry-retention` as JSON, as
`INFRARED_REGISTRY_RETENTION` carries it (camelCase keys); `-copies`,
`-postgres-archive` and `-restore` as their Data in JSON (camelCase keys too);
and `-postgres-server-name`.

The zero value of every newer field renders exactly the files the template
rendered before the field existed. Only `.Edge`, `.Stores`, `.Disabled`,
`.Forge`, `.Registry` and `.SubstrateCapable` turn anything on or off: a Traefik
cluster that carries `spec.previews` by hand, on any cloud, renders the same
files as one without (`make verify` checks it). A `.Backup` without the stores
changes only what the `infrared` Application carries (see "The install's
settings"); `.Forge` `gitea` turns Gitea on there and, with builds on, swaps
GitHub's token job for the operator's `gitea-git` (see "Builds"). `.Registry`
runs Zot only with `.Stores`, and turns builds to the registry inside the
cluster when they are on; with neither, it changes only what the `infrared`
Application carries. `.Cloud` only picks the StorageClass of the Postgres
volume, when `.Stores` is on, and of Gitea's, for `.Forge` `gitea` (Linode's
Retain class on `linode`). `.SubstrateCapable` runs Agent Substrate only with
`.Stores` and `.Registry` both set; without either, the preflight's yes changes
no file, so a Traefik cluster without the stores renders the same files
whatever its preflight says (`make verify` checks it). `.Copies`,
`.PostgresArchive`, `.RegistryRetention`, `.PostgresServerName` and
`.Backup.Prefix` change only settings that render today's literal when empty,
and `.Backup.Credentials` renders today's files with its defaults, empty or
spelled out. `.Copies.Recipients` turns backups on, with the stores and a
backup bucket: the Postgres roles' copy into `.InfraredNamespace` and the
backup in the mirror's run mark. `.Restore` adds the restore's pieces, with the
same two: with neither, both change only what the `infrared` Application
carries (`make verify` checks it).

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

Infrared's API reads **`infrared.darkshift.io/layer`** for the layer an
Application belongs to (see "Layers and wave bands").

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

#### The install's settings

Argo CD renders the chart from the Application's values alone, so every setting
the install gave `helm install` has to be in them too. Until then it survives
only while Helm still owns the field, and the next change drops it: the stores,
for one, which the operator reads at every render of this repo. The template
writes each setting from the Data the operator hands it, and only when it is
set, so a cluster without it renders the same file as before:

| Data | Chart value |
|---|---|
| `.ImageRegistry`, `.Images` | `image.registry`, each `<component>.image` (see "Images") |
| `.Edge` `gateway` | `installation.edge: gateway` |
| `.PlatformDomain` and `.InfraredHost`, in gateway mode | `installation.previews.domain`, and `installation.previews.signInURL: https://<InfraredHost>` |
| `.Stores` | `stores.enabled: true` |
| `.Backup.Bucket` (with its `.Endpoint`, `.Region` and `.Prefix` when set) | `backup` (`bucket`, `endpoint`, `region`, `prefix`) |
| `.Copies.Recipients`, `.Copies.Mirror.Schedule`, `.Copies.Mirror.Retention` and `.PostgresArchive.Enabled`, each that is set | `backup` (`recipients`, `mirror.schedule`, `retention`, `postgres.archive: true`), beside the bucket, or alone |
| `.Disabled` | `components.disabled`, without `substrate-test-actors` |
| `.Stores` and `.Registry`, with `substrate-test-actors` not in `.Disabled` | `substrate.testActors: true` (see "Agent Substrate") |
| `.Forge` `gitea` | `gitea.enabled: true`, `giteaAdmin.existingSecret: infrared-gitea-admin`, and on `.Cloud` `linode` `gitea.persistence.storageClass: linode-block-storage-retain` |
| `.Registry` | `registry.address` |
| `.RegistryRetention`, each field that is set | `registry.retention` (`untaggedAfter`, `keepTags`, `keepNewest`, `gcInterval`, `gcDelay`) |
| `.Images` `code-index`, with `.ImageRegistry` | `codeIndex: {enabled: true, image: {tag, digest}}`, and `platformTokens.existingSecret: infrared-platform-tokens` (see "The code index") |

The edge and its previews are carried in gateway mode only. The operator writes
`spec.edge` and `spec.previews` to the Installation only while each is empty, so
on a Traefik cluster they are the Installation's own, often set by a person,
and the chart never had them: carrying them would change that cluster's files
for nothing. `installation.previews` is rebuilt from the two names the Data has,
so a previews setting with more fields (`managedRoots`, `ingressHost`, ...)
loses them in Argo CD's render, which matters only if the Installation's
`spec.previews` is ever emptied.

`restore` is never carried: Argo CD's render of the chart is never a restore,
so the chart's restore Jobs and settings stay the install's alone.

`giteaAdmin.existingSecret` keeps Gitea's site admin as the install made it,
like the Secrets above: the chart generates `infrared-gitea-admin` once, and
`lookup` returns nothing under Argo CD. Gitea's volume keeps the install's
size only while that is the chart's default, 10Gi: Argo CD would try to shrink
a larger claim, which Kubernetes refuses, so a larger size goes in the org's
values file as well.

### The org's values file

The `infrared` Application has two sources: the chart first, then this gitops
repo at `.DefaultBranch` as `ref: values`. The chart takes the org's own values
from **`registry/clusters/<cluster>/values/infrared.yaml`** (`valueFiles` with
`ignoreMissingValueFiles: true`, so the file is optional). That path is
reserved for the org: the template never renders anything under
`registry/clusters/<cluster>/values/`, and hydration never deletes or
overwrites a file it does not render, so the file survives every template
bump. A bump re-renders `infrared.yaml` itself and keeps only its chart pin,
which the operator reads as the first `targetRevision` that starts with a
digit; the chart source comes first so that a branch name can never be taken
for it. Org settings such as `ui.extensions` therefore belong in the values
file, never in `infrared.yaml`. Argo CD gives `valuesObject` precedence over
`valueFiles`, so the values the template sets (cluster name, template version,
pull secret, existing Secrets, build registry, and the install's settings in
"The install's settings") win over the file.

## Components

| Wave | Application | Source | Pin |
|---|---|---|---|
| — | `registry-<cluster>` (root) | this repo, `registry/clusters/<cluster>/components` | `.DefaultBranch` |
| 0 | `appprojects` | `components/appprojects` | — |
| 10 | `cert-manager` | https://charts.jetstack.io `cert-manager` | v1.21.2 |
| 10 | `external-secrets` | https://charts.external-secrets.io `external-secrets` | 2.11.0 |
| 10 | `aws-load-balancer-controller` (eks only) | https://aws.github.io/eks-charts | 3.5.0 |
| 11 | `platform-tokens` (gateway, backups, Substrate's pull secret, or the code index) | `components/platform-tokens`: ClusterSecretStore `infrared-platform` | — |
| 11 | `envoy-gateway` (gateway only) | `docker.io/envoyproxy` `gateway-crds-helm` (its own CRDs) and `gateway-helm` | v1.9.2 |
| 11 | `origin-ca-issuer` (gateway only) | `ghcr.io/cloudflare/origin-ca-issuer-charts` `origin-ca-issuer`, CRDs from https://github.com/cloudflare/origin-ca-issuer `deploy/crds` | chart 0.6.10, v0.15.0 |
| 12 | `external-dns` (gateway only) | https://kubernetes-sigs.github.io/external-dns/ `external-dns` + `components/external-dns` | 1.22.0 (v0.22.0) |
| 13 | `edge` (gateway, with a name) | `components/edge` | — |
| 15 | `infisical` | cloudsmith `infisical-standalone` + `components/infisical` | 1.11.0 |
| 16 | `cloudnative-pg` (Stores only) | https://cloudnative-pg.github.io/charts `cloudnative-pg`, with a backup bucket also `plugin-barman-cloud` + `components/cloudnative-pg` | chart 0.29.1 (CloudNativePG 1.30.1), chart 0.8.1 (Barman Cloud plugin 0.15.1), by digest |
| 17 | `postgres` (Stores only) | `components/postgres` | PostgreSQL 18.6, by digest |
| 18 | `seaweedfs` (Stores only) | https://seaweedfs.github.io/seaweedfs/helm `seaweedfs` + `components/seaweedfs` | chart 4.48.0 (SeaweedFS 4.48, by digest) |
| 18 | `stores-restore` (Stores and a backup bucket, while a restore is in progress) | `components/stores-restore`: the file index's reset and the buckets' copy back | PostgreSQL 18.6, rclone 1.75.1, by digest |
| 19 | `stores-credentials` (Stores, with Registry or the backups' recipients) | `components/stores-credentials`: ClusterSecretStore `infrared-stores` | — |
| 20 | `zot` (Stores and Registry) | https://zotregistry.dev/helm-charts `zot` + `components/zot` | chart 0.1.125 (Zot v2.1.21, by digest) |
| 20 | `substrate-crds` (Stores, Registry and SubstrateCapable) | `components/substrate-crds`, vendored from Agent Substrate | `ce05e5d` (see "Agent Substrate") |
| 21 | `substrate-podcert` (the same) | `components/substrate-podcert` | the same, images by digest |
| 22 | `substrate` (the same) | `components/substrate` | the same, images by digest |
| 23 | `substrate-actors` (the same) | `components/substrate-actors` | the same, images by digest |
| 25 | `kpack` | `components/kpack` (vendored `release-0.18.0.yaml`) | v0.18.0 |
| 26 | `builds` (only with `.BuildRegistry`) | `components/builds` | Paketo buildpacks and stack by digest |
| 30 | `victoria-metrics-k8s-stack` | https://victoriametrics.github.io/helm-charts/; VMSingle keeps its data on a 10Gi claim of the default class, but on k3s with the stores on an `emptyDir` of up to 10Gi (see "Metrics with the stores") | 0.95.0 (operator v0.75.0) |
| 40 | `infrared` | `.InfraredChartRepo` `infrared`, values from this repo's `registry/clusters/<cluster>/values/infrared.yaml` | `.InfraredChartVersion` |
| 41 | `code-index` (with the code index's pin and `.ImageRegistry`) | `components/code-index`: Infrared's code index, Zoekt and the code service | `<ImageRegistry>/infrared-codeindex`, the pin in `.Images` |
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

### Layers and wave bands

Infrared shows the management cluster's platform layer by layer, in the order
the layers become available, each one Ready, Partly ready or Not ready and
naming what blocks it; the sync waves stay one click away. The API computes
the layers (infrared-api `internal/server/layers.go`): from Argo CD's
Applications, a few workloads Argo CD keeps no health for, the stores' backups,
and the operator's record of which components a hydration rendered and why it
left the others out (`GitopsRepo` `status.components`, in the words of the
comment a file renders when it holds no objects).

An Application names its layer with the label **`infrared.darkshift.io/layer`**.
The root app-of-apps and the ten Applications that existed before layers
(`appprojects`, `argocd`, `aws-load-balancer-controller`, `builds`,
`cert-manager`, `external-secrets`, `infisical`, `infrared`, `kpack`,
`victoria-metrics-k8s-stack`) carry none, so a gitops repo hydrated before this
renders the same files; the API knows their layers by their names. Every other
Application carries the label, and `make verify` refuses one without it, or one
whose value is not a layer the API knows.

| # | Layer (label value) | Applications, by wave | What else the API reads |
|---|---|---|---|
| 1 | Infrared (`infrared`) | `infrared` (40), sync only; `code-index` (41) | the chart's operator, api, ui and mcp Deployments |
| 2 | Version control (`version-control`) | none | Gitea's Deployment, from the chart (`gitea.enabled`) |
| 3 | GitOps (`gitops`) | `registry-<cluster>`, `appprojects` (0), `argocd` (100) | Argo CD's application controller and repo server |
| 4 | Secrets (`secrets`) | `external-secrets` (10), `platform-tokens` (11), `infisical` (15), `stores-credentials` (19) | |
| 5 | Certificates (`certificates`) | `cert-manager` (10) | |
| 6 | Edge and DNS (`edge`) | `aws-load-balancer-controller` (10), `envoy-gateway` (11), `origin-ca-issuer` (11), `external-dns` (12), `edge` (13) | |
| 7 | Databases (`databases`) | `cloudnative-pg` (16), `postgres` (17) | |
| 8 | Object storage (`object-storage`) | `seaweedfs` (18) | |
| 9 | Registry (`registry`) | `zot` (20) | |
| 10 | Agent runtime (`agent-runtime`) | `substrate-crds` (20), `substrate-podcert` (21), `substrate` (22), `substrate-actors` (23) | |
| 11 | Build runtime (`build-runtime`) | `kpack` (25), `builds` (26) | |
| 12 | Observability (`observability`) | `victoria-metrics-k8s-stack` (30) | |
| 13 | Backups (`backups`) | `stores-restore` (18), only while a restore is in progress | the WAL archive and the last base backup of `stores/postgres`, and the last run of the CronJob `stores/seaweedfs-backup` |

Which members serve a layer and which only support it, the layers each one
needs, and how a state is judged are the API's; this repo only places each
Application in its layer. A Product's zones and a workload cluster's registry
belong to no layer and appear in the sync waves alone.

No sync wave moved for the layers. Waves order what Argo CD applies, and on a
fresh cluster a wave never waits for the one before it ("Order on a fresh
cluster"); the layers order what a person reads. The waves still fall in bands
that follow the layers, and a new component takes a wave in the band of its
layer:

| Waves | Band |
|---|---|
| 0 | the AppProjects |
| 10 to 13 | secrets, certificates, and the edge with its DNS |
| 15 to 19 | Infisical, then the stores: CloudNativePG, Postgres, SeaweedFS and the stores' credentials |
| 20 to 23 | the registry inside the cluster, and Agent Substrate |
| 25 to 26 | builds |
| 30 | observability |
| 40 to 41 | Infrared adopting itself, then its code index |
| 100 | Argo CD managing itself |

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

With `.Forge` `gitea` the org's repos are on Gitea: there is no `github-token`
job and no ConfigMap of its scripts, and the builder lists `gitea-git` where it
listed `github-git`. The operator writes `builds/gitea-git` once the namespace
exists: `kubernetes.io/basic-auth`, the org's bot user with its read-only token
as the password, annotation `kpack.io/git: <ForgeURL>`. A product's kpack Image
clones `<ForgeURL>/<owner>/<repo>.git`.

The `infrared` Application passes `builds.registry: .BuildRegistry` to the
chart, so Argo CD's render keeps the operator's `INFRARED_BUILD_REGISTRY`.

With `.Registry` too, builds push to the registry inside the cluster (see "The
registry"), by its address. The ClusterBuilder's tag is
`<Registry>/platform/kpack-builder`, pushed as the user `platform` with the
ServiceAccount `kpack/infrared-builder`, which lists `kpack/registry-push`: the
operator writes that Secret once the namespace `kpack` exists, and no platform
credential lives in `builds`. There is no `builds/builder`, no ECR login job and
no namespace `build-credentials`. A Sync hook, `builds/registry-wait` (wave -1),
holds the builder (wave 1) until Zot's Service has a ready endpoint and the
Secret exists: kpack retries a failed push with a delay that doubles each time.
Each organization's builds run as the operator's `builds/builder-<org>`, which
lists `builds/registry-push-<org>`, and push under `<org>/`; the source
credentials are as above.

### Images

With `.ImageRegistry` set the `infrared` Application also passes
`image.registry`, and for each entry of `.Images` that component's
`<component>.image.tag` and `.digest` (`operator`, `api`, `ui`, `runner`, and
`mcp.image` beside the MCP Secrets), so Argo CD's adoption keeps every image
where the install pinned it. A template version that is not a `v` tag (a
commit SHA) renders quoted, so a SHA of digits stays a string.

### The edge

With `.Edge` `gateway` the cluster is served by one Envoy Gateway behind
Cloudflare's proxy, with an origin certificate from Cloudflare. Each file of
it renders to a comment only otherwise.

| Application | What |
|---|---|
| `platform-tokens` | ClusterSecretStore `infrared-platform` (Kubernetes provider) reading the Secret `infrared-platform-tokens` in `.InfraredNamespace`, which the Infrared chart keeps, as ServiceAccount `platform-tokens-reader` (get on that one Secret). `conditions` limit it to the namespaces below. With Agent Substrate and an `.ImagePullSecret`, it also reads that Secret, for Substrate's namespaces (see "Agent Substrate"), and renders even without a Gateway; so it does with the code index, for whose namespace it copies the install's record and credential (see "The code index"). |
| `envoy-gateway` | Envoy Gateway's CRDs and controller. The Gateway API CRDs are the cluster's (k3s ships them) and are never installed here. |
| `origin-ca-issuer` | Cloudflare's origin issuer and its CRDs. |
| `external-dns` | Cloudflare, every record proxied, TXT owner `.ClusterName` (prefix `_edns.`). It publishes only HTTPRoutes labelled `infrared.darkshift.io/dns=edge` on the Gateway `edge`, and changes or deletes only records it owns. No domain filter: Cloudflare would match it against zone names and hide the zone; the label, the listener hostnames and the token's zones bound what it writes. Its token: ExternalSecret `external-dns/cloudflare-api-token`. |
| `edge` | Needs `.PlatformDomain` or `.InfraredHost`. GatewayClass and EnvoyProxy `edge`, Gateway `edge` (namespace `envoy-gateway-system`), OriginIssuer `cloudflare-origin` with its token (ExternalSecret `envoy-gateway-system/cloudflare-api-token`), Certificate `edge` (Secret `edge-tls`), BackendTrafficPolicy `edge` (no request timeout), HTTPRoute `https-redirect` and HTTPRoute `.InfraredNamespace`/`infrared`. In waves: the token's copy (-5), the issuer (-4), the certificate (-3), EnvoyProxy (-2), GatewayClass (-1), then the rest. |

All three that read or make a token wait first, in a PreSync hook (see
"Order on a fresh cluster"): `platform-tokens` for External Secrets' webhook,
`external-dns` for the store, and `edge` for the store, cert-manager's webhook
and the CRDs it uses.

The Gateway's listeners:

| Listener | Hostname | Who attaches |
|---|---|---|
| `http` | `*.<PlatformDomain>` | the redirect only (same namespace) |
| `https` | `*.<PlatformDomain>` | zones: namespaces labelled `infrared.darkshift.io/zone` |
| `infrared-http` | `.InfraredHost` | the redirect only |
| `infrared-https` | `.InfraredHost` | `.InfraredNamespace` only; an exact name beats the wildcard, so nothing else can answer for Infrared |

No load balancer is ever made: on Linode a LoadBalancer Service is a
NodeBalancer. Envoy runs as a DaemonSet that binds each node's ports 80 and
443 (hostPort onto its 10080 and 10443), and its Service is NodePort with
`externalTrafficPolicy: Local`, which makes Envoy Gateway report the
ExternalIP of every node with a ready Envoy as the Gateway's addresses.
external-dns publishes those, so a rebuilt node's address reaches DNS by
itself. The redirect route names no host, so it takes each listener's: one
proxied wildcard record `*.<PlatformDomain>`, which covers every zone, and one
for `.InfraredHost`. The certificate is `*.<PlatformDomain>`, plus
`.InfraredHost` when the wildcard does not cover it. The cluster's firewall
must admit only Cloudflare to ports 80 and 443; nothing here opens the node
ports to anyone.

### The stores

With `.Stores` the template runs the platform's own stores, owned once: one
Postgres for every consumer that needs a database and one object store for
every consumer that needs a bucket, both in the namespace `stores`.

| Application | What |
|---|---|
| `cloudnative-pg` | The CloudNativePG operator and its CRDs, in `cnpg-system`. Its webhook CA is its own, so the webhook configurations' `caBundle` is ignored. |
| `postgres` | `components/postgres`: the Cluster `postgres`, one instance (PostgreSQL 18.6 with the standard extensions, pgvector among them, by digest), and a `DatabaseRole` and a `Database` for each consumer: `seaweedfs`, SeaweedFS's filer metadata, and `substrate`, Agent Substrate's records, ready before Substrate is installed. A PreSync hook makes each role's Secret `postgres-<role>` (`kubernetes.io/basic-auth`, label `cnpg.io/reload`) once and never replaces it; CloudNativePG sets the role's password from it, and the consumer reads the same Secret. |

The Cluster has one volume of 20 GiB, for its data and its WAL together. On
`.Cloud` `linode` its StorageClass is `linode-block-storage-retain`, the Retain
class of Linode's volume driver (CSI 1.1.4), which the cluster brings: the
driver is installed with the nodes, so the template never installs it. Every
Linode volume is a service on the Linode account, which holds a limited
number, so the Cluster and, with `.Forge` `gitea`, Gitea's volume (through the
`infrared` Application's values) are the only things that name a Linode class,
and `make verify` checks it. On any other cloud the volume comes from the
cluster's default StorageClass. A deleted node takes no data with it: the
instance starts again on another node, on the same volume. There is no
disruption budget, which would keep one instance from moving on a drain.

None of the three carries a resources finalizer. Leaving one out, or
turning `.Stores` off, stops managing it but deletes nothing: deleting the
operator's CRDs or the Cluster would delete the data. A person removes them on
purpose. SeaweedFS's data stays on the nodes' disks either way.

To add a consumer: a file in `components/postgres/` with its `DatabaseRole`
(wave 1) and `Database` (wave 2), its role in the PreSync hook's list and in
its Role's `resourceNames`. The consumer reads `postgres-<role>`.

`seaweedfs` (wave 18) is SeaweedFS 4.48 across the nodes: three masters (Raft),
a volume server on each node with its data under `/var/lib/seaweedfs` on the
node's own disk, two filers and two S3 gateways, each pod on a node of its own.
Every file is written to two volume servers (replication `001`), so with
SeaweedFS stopped on any one node every object still reads. Every 17 minutes the
masters' leader copies under-replicated volumes back to two servers
(`volume.fix.replication`), e.g. onto a node that replaced a lost one; there is
no erasure coding, which needs more servers than three nodes give. The filers
keep every entry in the platform's Postgres (database `seaweedfs`), so they are
stateless. No SeaweedFS object claims a volume, so none is a Linode volume.

S3 answers at `http://seaweedfs-s3.stores.svc:8333`. The chart's bucket hook
makes the buckets `ate-snapshots` (Agent Substrate's snapshots) and `registry`
(the registry's images and charts) after each sync, with `weed shell`. Each
bucket has an S3 identity that reaches it alone (Read, Write, List and Tagging
on that bucket; no identity is an administrator), in
`components/seaweedfs/identities.yaml`, which holds no key: each key is an
environment variable of the gateway, from the Secret
`seaweedfs-s3-<identity>` (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`) that a
PreSync hook makes once and never replaces. A consumer reads the same Secret.
The hook also waits for the platform's Postgres to answer before the filers
start. A new set of identities changes the gateways' annotation
`infrared.darkshift.io/s3-identities`, so they restart and read it.

### Backups

With `.Stores` and a `.Backup.Bucket`, the stores are copied to that bucket,
outside the cluster, under `<Bucket>/<prefix>/`, and kept seven days, where
`<prefix>` is `.Backup.Prefix`, or `.ClusterName` when that is empty.
`.Backup.Endpoint` is the S3 endpoint (empty for AWS S3) and `.Backup.Region`
its region. The keys are the platform's: the Secret `infrared-platform-tokens`
keys `backup-access-key-id` and `backup-secret-access-key`
(`.Backup.Credentials`), which the store `infrared-platform` copies into
`stores` (`postgres-backup`, `seaweedfs-backup`); the store's `conditions` then
admit `stores` as well, and `platform-tokens` renders even without a Gateway.

| What | How | Where | Kept |
|---|---|---|---|
| Postgres's WAL | continuously: CloudNativePG's Barman Cloud plugin archives each segment as it is written (the Cluster's plugin, `isWALArchiver`) | `s3://<Bucket>/<prefix>/postgres/` | seven days of point-in-time recovery (`retentionPolicy: 7d` on the ObjectStore `backup`) |
| Postgres's base backup | every day at 03:00 UTC, and once at the first sync (ScheduledBackup `postgres-daily`, `method: plugin`) | the same | the same |
| SeaweedFS's buckets `ate-snapshots` and `registry` | every hour at 17 past, CronJob `seaweedfs-backup`: rclone 1.75.1 makes `current/<bucket>/` match the bucket, and keeps what that run replaced or deleted under `archive/<run>/<bucket>/`; a mark `runs/<run>.json` says the run finished | `<Bucket>/<prefix>/seaweedfs/` | archives and marks for seven days, by the run's name |

`.Copies.Mirror` sets the mirror's schedule and how long its archives and
marks are kept, `.PostgresArchive` the base backup's schedule (six cron fields,
seconds first) and the archive's retention. Each retention is whole days.
Empty, each is the default above. `.PostgresServerName` is the archive's server
name, `<server name>` below `postgres/`. Empty archives under `postgres`, the
Cluster's own name.

With `.Copies.Recipients` as well, the install makes a backup every hour: the
Infrared operator's CronJob, not this template, writes one artifact per backup
straight to `<Bucket>/<prefix>/backups/`, `<stamp>.irbackup`, encrypted with
age to the recipients (Infrared's objects, Gitea's dump and a dump of each
consumer database of the platform's Postgres), and its clear manifest
`<stamp>.json`. The template's part:

| What | How |
|---|---|
| The backup's Postgres roles | the backup dumps each consumer database as that database's own role. The store `infrared-stores` copies each role's Secret (`username`, `password`) from `stores` into `.InfraredNamespace` under its own name, today `postgres-substrate` (`components/stores-credentials/backup.yaml`, wave 2, after the store), and its `conditions` then admit that namespace too. The database `seaweedfs` is not dumped: a restore's copy back of the buckets makes the file index again |
| The mirror's mark | each run's mark also names the newest complete backup when the run started, `{"run", "finished", "buckets", "backup"}`: the newest `<stamp>` under `<prefix>/backups/` with both `<stamp>.irbackup` and `<stamp>.json`, the artifact's size the manifest's own `size`; `""` while there is none. The run looks before it copies any bucket, so the buckets in `current/` are never older than the backup a mark names, and a restore pairs a backup with a run that names it or a newer one. The mirror never reads an artifact; the restore checks its sha256 |

No recipient, no backup: an install changes nothing until a person makes the
key.

A copy of every object at every hour would take 168 times the buckets' size,
so the buckets are kept as one mirror and the hourly changes to it. rclone reads
SeaweedFS as the S3 identity `backup`, which may only read and list the two
buckets. The plugin (chart 0.8.1, `plugin-barman-cloud` 0.15.1 and its sidecar,
by digest) is a second chart of `cloudnative-pg`; its mTLS certificates come
from `components/cloudnative-pg`, in waves of their own ahead of the charts,
with the chart's own turned off.

A Cluster built again from nothing writes its WAL to the same prefix, which
Barman refuses while an older server's archive is there. So each install
archives under a server name of its own, `.PostgresServerName`, and a restore
under a new one.

### Restore

The Infrared chart restores an install at install time, and the operator hands
the restore to the template as `.Restore`, from the ConfigMap
`infrared/infrared-restore`, while it is in progress. With the stores and a
backup bucket, the template then brings the stores back. The objects are the
operator's; the template does not render them.

| What | How |
|---|---|
| Postgres | the Cluster bootstraps empty, with `initdb`, as on any install, and no archive is recovered: the Infrared chart's restore brings each consumer database's records back from the backup's dump. With an archive, the new Cluster archives under a new `.PostgresServerName` |
| SeaweedFS's file index | the Job `stores/stores-index-reset` drops what the role `seaweedfs` owns, once per point, so no index of a lost cluster's names data that went with its nodes: a comment on the database `seaweedfs`, written in the same transaction, makes a second run do nothing |
| SeaweedFS's buckets | the Job `stores/stores-restore` copies each bucket back from `<prefix>/seaweedfs/current/` of the copy outside, as the S3 identity `restore` (Read, Write, List on every bucket, only during a restore), and never overwrites an object that is there. A bucket whose copy lists empty is skipped; a listing that fails (a key, the network, a missing bucket) fails the Job, which runs again, so it never marks a bucket it did not copy |
| The order | each Job marks the ConfigMap `stores/restore-stores` (`point`, then `postgres`, then `buckets`, each a UTC time). SeaweedFS's sync waits for `postgres`; Zot's and Agent Substrate's for `buckets`, each in a PreSync hook that reads that ConfigMap alone; the hourly mirror copies nothing and fails until `buckets`, so it never makes the copy outside match empty buckets |
| The end | the operator marks the restore Complete once `buckets` is marked, and stops passing `.Restore`: the next render drops the `stores-restore` Application, the identity `restore` and the waits |

`stores-restore` (wave 18, layer `backups`) holds the two Jobs. A PreSync hook
in `.InfraredNamespace` first waits for Postgres's Service `postgres-rw` to have
a ready endpoint, which is when Postgres has started. Neither Job is ever
deleted by a timer: Argo CD would make a deleted one again, and run it again.

### The registry

With `.Registry` and `.Stores` the template runs the registry inside the
cluster: Zot v2.1.21 (chart 0.1.125, by digest) in the namespace `registry`,
every layer and manifest in SeaweedFS's bucket `registry`. Its Service
`registry/zot` is a ClusterIP pinned to `.Registry`'s address, on its port, plain
HTTP: each node mirrors that address to it (k3s's `registries.yaml`, written when
the node is made, so the template never sets it), and anything in the cluster
pulls without a login. Builds name the registry by that address, never by a
name: go-containerregistry, which kpack and the buildpack lifecycle push with,
falls back to plain HTTP only for a private address.

| Application | What |
|---|---|
| `stores-credentials` (wave 19) | ClusterSecretStore `infrared-stores` (Kubernetes provider), which reads the Secrets the stores keep for their consumers in `stores`, each by name, as the ServiceAccount `stores/stores-credentials-reader`; `conditions` admit `registry`, and with Agent Substrate `ate-system` too, for `seaweedfs-s3-ate-snapshots` and `postgres-substrate`; with `.Copies.Recipients` and a backup bucket, `.InfraredNamespace` too, for the Postgres roles the backup dumps as (`postgres-substrate`), which its ExternalSecret copies there (wave 2, after the store), and then it renders without `.Registry` as well. A new consumer adds its Secret to the Role and its namespace to the conditions. It waits, in a PreSync hook in `.InfraredNamespace`, for External Secrets' webhook and SeaweedFS's S3 gateway, and never creates `stores`. |
| `zot` (wave 20) | `components/zot`: the ConfigMap `zot-base`, the ExternalSecret `zot-s3` (the S3 identity `registry`'s keys, from `stores/seaweedfs-s3-registry`) and two waits; and the chart: one replica, `strategy: Recreate`, not root, a read-only root filesystem, and the Service above. |

Zot's config and its users are split between the template and the operator:

| Object | Written by | What |
|---|---|---|
| ConfigMap `registry/zot-base`, key `config.json` | the template | storage on S3, with no keys (Zot's S3 driver reads `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` from its environment, the Secret `zot-s3`), garbage collection and the retention rules (`.RegistryRetention`; by default every hour, a blob an hour after its last use, untagged images after a day, every v-tag and each repository's ten newest tags kept), `compat: ["docker2s2"]` (Paketo's images are Docker schema 2, which Zot otherwise refuses), htpasswd at `/etc/zot-auth/htpasswd` and API keys, and the rules: anyone reads, the user `platform` writes under `platform/`, the user `infrared` reads and deletes anywhere |
| Secret `registry/zot-config`, key `config.json` | the operator | `zot-base` with one rule per organization added under `http.accessControl.repositories` (`<org>/**`, user `<org>`), mounted at `/etc/zot` |
| Secret `registry/zot-auth`, key `htpasswd` | the operator | the bcrypt hashes of `infrared`, `platform` and each organization's user, mounted at `/etc/zot-auth` |

Zot rereads both Secrets within seconds of a change, without a restart: its
watch also compares each file's identity, so a Secret volume's swap reaches it.
Nothing rolls the pod when they change. The operator writes them once `zot-base`
and the namespace exist, so the `zot` Application holds its sync twice: a
PreSync hook waits for the store `infrared-stores` and SeaweedFS's S3 gateway,
and a Sync hook at wave -1, after `zot-base` (-3) and the S3 keys (-2), waits for
`zot-config`, `zot-auth` and `zot-s3` before Zot starts (0). A PreSync wait for
the operator's Secrets would never end on a fresh install, because `zot-base` is
applied by the same sync.

Zot's own database, the users' API keys among it, is on the pod's disk: a new pod
reads every repository back from the bucket, so an image outlives every registry
pod and an API key does not. The pods carry `app.kubernetes.io/name: zot`, which
the operator's network rule for publishing steps selects. Removing the `zot`
Application removes Zot and nothing in the bucket.

Two checks run against a cluster, never from CI:

```bash
scripts/registry-check.sh <context> <org>    # D1, D2: <org> pushes only under <org>/, a copy outlives Zot's pod, and the admin's delete of it leaves the source's blobs
scripts/registry-build-check.sh <context>    # D3: kpack pushes a whole build to the registry's address over plain HTTP, and a node runs it by digest
```

### Agent Substrate

With `.Stores`, `.Registry` and `.SubstrateCapable` together the template runs
Agent Substrate, the agent runtime: actors in gVisor sandboxes on warm worker
pods, suspended to SeaweedFS and resumed on demand. Four Applications, each
labelled `infrared.darkshift.io/layer: agent-runtime`, in the waves 20 to 23:

| Wave | Application | What |
|---|---|---|
| 20 | `substrate-crds` | WorkerPool, SandboxConfig and CSIDriverConfig, and the ValidatingAdmissionPolicy every SandboxConfig passes. No resources finalizer: removing it leaves them. |
| 21 | `substrate-podcert` | The pod-certificate controller, in `podcertificate-controller-system` (Pod Security baseline): it signs each component's short-lived certificate through the cluster's `certificates.k8s.io/v1beta1` and publishes their trust bundles. A PreSync hook makes its two CAs. |
| 22 | `substrate` | The control plane, in `ate-system` (privileged): the API (two replicas), the controller, atelet on every labelled node, the router and the egress gateway, and the NetworkPolicies on the API and the router. A PreSync hook makes the actor-identity pools, writes the API's authentication settings, labels the nodes and waits for what the control plane needs. |
| 23 | `substrate-actors` | The WorkerPool `platform` in `ate-workers` (privileged): three gVisor workers of one CPU and 1 GiB. Sync hooks copy the actor images into the registry (wave 1), then make the atespace `platform` and its ActorTemplates (wave 2). |

The manifests are upstream's at the commit in `scripts/substrate-images.json`,
vendored by `scripts/vendor-substrate.sh` with every image by digest, and each
component's kustomization patches them: the namespaces are Argo CD's
(`CreateNamespace`, with their Pod Security label), the API and atelet keep
snapshots in S3, atelet's image settings are below, and every pod pulls with the
install's pull secret. Left out: upstream's `atenet-router-monitoring.yaml`, a
GKE Managed Prometheus PodMonitoring; its OTLP settings, which name GKE's
collector (here the endpoint is empty, which Substrate reads as no collector);
and its bundled Postgres.

| What | Where |
|---|---|
| Records | The database `substrate` on the platform's Postgres, as the role `substrate` (`stores/postgres-substrate`), schema `public`, TLS as SeaweedFS's filers use it (`sslmode=require`). Its DSN is the Secret `ate-system/ate-api-server-secret-envvars`, made by an ExternalSecret through `infrared-stores`. |
| Snapshots | The bucket `ate-snapshots`, as the S3 identity `ate-snapshots` (`stores/seaweedfs-s3-ate-snapshots`, copied to `ate-system/ate-s3-credentials` through `infrared-stores`), path-style at `http://seaweedfs-s3.stores.svc:8333`, for the API and atelet. A template's snapshots go under `platform/<template>/`. |
| Substrate's images | ghcr, by digest. With an `.ImagePullSecret`, the store `infrared-platform` copies that Secret into `podcertificate-controller-system`, `ate-system`, `ate-workers` and, for the copy of the test actors' images, `registry`; the workers pull with it through the ServiceAccount `default` of `ate-workers`, because a WorkerPool cannot name a pull secret. The router's Envoy (`envoyproxy/envoy`) and the SandboxConfig's pause image (`registry.k8s.io/pause`) are upstream's, by digest, and atelet fetches gVisor from Google's public bucket, as upstream's `gvisor-default` names it. |
| Actor images | atelet pulls them itself, without a login and without the nodes' registry mirrors. It runs with `--gcp-auth-for-image-pulls=false` and `--localhost-registry-replacement=<Registry>`: an image named on `localhost` (or a loopback address) is pulled from the registry inside the cluster, over plain HTTP. A template names `localhost/platform/substrate/<image>:<tag>@sha256:...`, so an immutable template never holds the registry's address, and the pull takes the path the Substrate spike proved with its node registry. |

The hooks do what Substrate's installer (`ate-setup`) does by hand, and each is
safe to run again:

| Hook | What it does |
|---|---|
| `substrate-podcert-prepare` (PreSync) | The CA pools `service-dns-ca-pool` and `pod-identity-ca-pool` in `podcertificate-controller-system`, made once. |
| `substrate-prepare` (PreSync) | The pools `actor-id-jwt-pool` (ES256), `actor-id-ca-pool` and `actor-id-ca-certs` (its root alone), made once; the ConfigMap `ate-api-authentication`, which trusts the cluster's ServiceAccount tokens for the audience `api.ate-system.svc`, the issuer read from the cluster's discovery document; the label `ate.dev/substrate-version=<version>` on each node without one; then waits for Substrate's CRDs, the trust bundles, the Postgres, SeaweedFS's S3 gateway and the stores. |
| CronJob `substrate-node-labels` | Every ten minutes, labels a node that joined since, so atelet runs there. |
| `substrate-actors-wait` (PreSync) | Waits for the API, the router and Zot to answer. |
| `substrate-images` (Sync, wave 1, in `registry`; with the test actors) | Copies the counter demo's image and the test actor's (`sandbox`) from ghcr to `<Registry>/platform/substrate/` with crane, as the registry's user `platform` (`registry/platform-push`, which the operator writes), then checks that each pulls by digest without a login. |
| `substrate-templates` (Sync, wave 2; with the test actors) | Makes the atespace `platform` and the ActorTemplates `counter-v1` and `sandbox-v1` through the API, then waits for each golden snapshot. A template of the same name with other images fails the hook: templates are immutable, so a change is a new version in the name. |

The CAs are made with OpenSSL, in memory in the hook's own pod, in the formats
Substrate's `localca` and `localjwtauthority` read: one Ed25519 root each,
valid 365 days, never replaced. Each CA Secret is labelled
`infrared.darkshift.io/substrate-ca=true` and carries its root's expiry in the
annotation `infrared.darkshift.io/not-after`, which the hooks print at each
sync. Nothing rotates them yet; read the dates with:

```bash
kubectl --context <cluster> get secrets -A -l infrared.darkshift.io/substrate-ca=true \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,NOT_AFTER:.metadata.annotations.infrared\.darkshift\.io/not-after'
```

**Only Infrared's operator reaches Substrate.** Its API accepts any
ServiceAccount token issued for its audience and authorizes nothing, and its
router authenticates nothing. So two NetworkPolicies admit, to the API's port
443, Infrared's operator (namespace `.InfraredNamespace`, pods
`app.kubernetes.io/name=infrared` and `app.kubernetes.io/component=operator`),
Substrate's atelet, router, egress gateway and controller, and pods in
`ate-system` labelled `infrared.darkshift.io/substrate-client=true` (the
templates hook and the checks below); to the router's Service ports, the
operator and those pods; and to port 9090 of both, the namespace `monitoring`.
Nothing else: no organization's namespace, no zone, no worker pod. An actor's
own traffic leaves its sandbox only through the egress gateway, which refuses
every destination its EgressPolicy does not name, and no template here has one.

**Substrate's test actors are off by default.** `counter-v1` (upstream's
counter demo) and `sandbox-v1` (upstream's sandbox demo, which runs any command
it is sent) exist only for the two checks below. `substrate-test-actors` in
`.Disabled` leaves them out: no copy of their images, no `substrate-templates`
hook, so no atespace and no ActorTemplate, and no pull secret in `registry`.
The WorkerPool `platform` and the wait stay. Without the name the template
renders them, exactly as before the setting existed. The Infrared chart names
`substrate-test-actors` among the components it hands the operator
(`INFRARED_DISABLED_COMPONENTS`) whenever the stores and a registry are on,
unless its value `substrate.testActors` is true. So the template never carries
the name in the `infrared` Application's `components.disabled`, and carries
`substrate.testActors: true` when the stores and a registry are on and the name
is absent, which keeps the setting through adoption (see "The install's
settings"). Turning them off later leaves the atespace and the ActorTemplates
in Substrate's database, as removing `substrate-actors` does.

Two checks run against a cluster, never from CI, from the place the policy
admits. Each needs the test actors, and stops at once, saying so, without them:

```bash
scripts/substrate-counter-test.sh <context>   # E5: a counter actor keeps both counters through a suspend and a resume on another worker
scripts/substrate-fence-check.sh <context>    # E4: the API and the router refuse an organization's namespace, ate-workers and the inside of an actor
```

The atespace, the templates and every actor are records in Substrate's
database: removing `substrate-actors` leaves them. A new Substrate version is a
new atelet DaemonSet and a new node label; the hooks label only nodes without
one, as `ate-setup` does, so an upgrade moves the nodes' label and the workers
by hand until upgrades are a version bump. The API's two replicas aside, the
router, the egress gateway and the pod-certificate controller are one pod each.

### The code index

With the code index's pin in `.Images` (key `code-index`) and `.ImageRegistry`
set, the template runs Infrared's code index: Zoekt and the code service in one
pod, in the namespace `code-index` (Pod Security restricted), behind
infrared-api's code endpoints. The Infrared chart hands that pin to the operator
only with its value `codeIndex.enabled`, so the code index is off unless the
install turns it on, and without the pin every file of it renders to comments
only. The `code-index` Application is wave 41, right after Infrared (40), in
the layer `infrared`.

| Object | What |
|---|---|
| Deployment `code-index` | One replica, replaced and never rolled (strategy `Recreate`), from `<ImageRegistry>/infrared-codeindex:<tag>@<digest>`. Two containers of that image, both not root on a read-only filesystem: the code service on 8080 and `zoekt-webserver` on the pod's loopback address. Ready once the first wave is indexed; `progressDeadlineSeconds` is an hour, so the first index never reads as stuck |
| Service `code-index` | `http://code-index.code-index.svc:8080`, the address infrared-api calls by default |
| NetworkPolicy `code-index` | Admits only infrared-api's pods (namespace `.InfraredNamespace`, `app.kubernetes.io/name: infrared`, `app.kubernetes.io/component: api`), on 8080. The code service has no authentication of its own |
| Its cache | An `emptyDir` of up to 40Gi: the mirrors and the shards, rebuilt from upstream whenever the pod starts, and never backed up |
| ExternalSecrets `code-index-settings` and `code-index-credentials` (wave -1) and the hook `code-index-wait` (PreSync) | Its record and its credential, copied from the install's Secret `infrared-platform-tokens` through the store `infrared-platform`, which then admits `code-index`, after a wait for that store (below) |
| ExternalSecret `<ImagePullSecret>` (wave -1) | With an `.ImagePullSecret`: its image is private, so it pulls with a copy of the install's pull secret through the same store |

Its settings are the install's, never this repo's, because they name a stack.
The Infrared chart writes them into the install's Secret
`infrared-platform-tokens` (`codeIndex.knowledge`, and the GitHub App in
`platformTokens`), and the two ExternalSecrets copy them into `code-index`:

| Key in `infrared-platform-tokens` | Copied to | Mounted at |
|---|---|---|
| `code-index-knowledge-url`, `code-index-knowledge-ref` | Secret `code-index-settings`, keys `knowledge-url` and `knowledge-ref`: the knowledge repository the record is read from, and its ref | `/etc/code-index/settings` (`CODEINDEX_SETTINGS`) |
| `code-index-github-app-id`, `code-index-github-app-installation-id`, `code-index-github-app-private-key` | Secret `code-index-credentials`, keys `github-app-id`, `github-app-installation-id` and `github-app-private-key`: the GitHub App it mints read-only installation tokens from for private repositories | `/etc/code-index/credentials` (`CODEINDEX_CREDENTIALS`) |

With the code index on, the chart always writes all five keys; without an App
the App's three are empty, which the code index reads as no credential (public
repositories only). Both mounts are optional: the pod starts without them and
says at `/readyz` what it lacks. A change to the install's Secret arrives
within the hour (`refreshInterval`), and the code index reads its record again
every hour and its credential at every use, so neither needs a restart. The
`infrared` Application carries `codeIndex: {enabled: true, image: ...}` while
the pin is there, so adoption keeps the code index on, and
`platformTokens.existingSecret: infrared-platform-tokens`, so Argo CD's render
of the chart never makes that Secret again, even with the record in the org's
values file (see "The install's settings"). Removing the Application, or naming
`code-index` in `.Disabled`, removes the code index and nothing else.

### Metrics with the stores

The `victoria-metrics-k8s-stack` Application runs VictoriaMetrics' single node
(VMSingle), with 30 days' retention, on a 10Gi claim of the default class. With
`.Stores` the cluster is several servers, each with its own disk, and is built
to lose one: SeaweedFS keeps every file on two of them. There, on k3s, the
default class, `local-path`, would keep VMSingle's claim on one server's disk,
and once that server is lost the pod stays Pending until a person deletes the
claim. So on k3s with the stores VMSingle keeps its data on the pod's own disk
instead, an `emptyDir` of up to 10Gi:

- `storage.resources.requests.storage: "0"`: the VictoriaMetrics operator
  (v0.75.0, from the chart) makes no claim for a request of no space. A `null`
  would not do: an apply of the Application deletes a key set to null, and the
  chart's own 20Gi claim would come back.
- `volumes: [{name: data, emptyDir: {sizeLimit: 10Gi}}]`: the operator mounts
  the volume named `data` where VictoriaMetrics keeps its data.

The metrics start empty after a node loss or a pod restart, and a pod that
outgrows 10Gi is evicted and starts empty. Grafana, vmagent and Alertmanager
keep nothing on a claim either. Without the stores VMSingle keeps its claim, as
before: on one k3s server, whose disk is the cluster's own, the claim keeps 30
days of metrics across pod restarts, and on EKS the default class is a volume
that follows the pod within its zone. A cluster with the stores hydrated from an
older template keeps its old claim, which nothing uses once VMSingle has moved:
the operator never deletes it, so a person does
(`kubectl -n monitoring delete pvc vmsingle-victoria-metrics-k8s-stack`).

### Order on a fresh cluster

On a fresh cluster the root app-of-apps creates every Application within
seconds: waves order the Applications, but Argo CD has no health check for
an Application, so a wave never waits for the one before it to be Healthy.
Each Application then syncs at once, and one that needs another component's
webhook, CRD or store can reach the API server before that component answers.
On a first install, the `edge` Application's ExternalSecret
was refused by External Secrets' webhook, which had no endpoint yet. Argo CD
applied the rest of that wave and waited for its health, which never came: the
certificate needed the token, the Gateway the certificate. The failed apply was
never retried, and the sync had to be restarted by hand.

Two rules keep that from happening again, and `make verify` checks both on
every component the template builds:

1. **Wait before applying.** A component that needs another component's
   webhook or store carries a PreSync hook, `<component>-wait` (alpine/k8s,
   read-only RBAC on CRDs, EndpointSlices and ClusterSecretStores). It waits
   until the CRDs it names are established, the Services it names have a ready
   endpoint and the ClusterSecretStores it names are Ready, for up to half an
   hour; then the sync applies. A webhook Service with a ready endpoint is
   what admits the objects, and the store cannot be Ready before External
   Secrets has admitted it. The wait spends none of the sync's five retries,
   so a slow first start, an image pull say, no longer exhausts them. A
   component that copies a token waits for its store, one that asks
   cert-manager waits for cert-manager's webhook, and one that makes a store
   waits for External Secrets' webhook.
2. **An object a webhook admits has a wave of its own.** An ExternalSecret, a
   cert-manager object or a CloudNativePG object never shares a sync wave with
   an object of another kind in its component, and comes before what depends on
   it. If its apply is refused after all, nothing in its wave waits on its
   health, so the sync fails and Argo CD retries it.

An Application health check in `argocd-cm`, the other cure, would make every
wave wait for the one before it to be Healthy: one Degraded component would
then hold back everything after it, the `infrared` Application included, and
`components/argocd` is verbatim, so every cluster would get it.

### Products

A product's gitops lives in `products/<product>/` of the gitops repo
(`build/image.yaml`, the kpack Image, and `zones/<zone>/values.yaml` per zone). The org adds its
Applications in `registry/clusters/<cluster>/components/` with file names
starting `product-<product>-`. The template never renders into `products/`
or a `product-*` name, and hydration never deletes or overwrites a file it
does not render, so a re-hydration leaves both alone. Keep it that way: no
template file may be named `product-*` or live under `products/` or
`registry/clusters/__cluster__/values/`.

The operator's scaffold writes those files for a Product it delivers, and also
`registry/clusters/<cluster>/components/products-project.yaml`, the AppProject
`products`, when the gitops repo has none; it adds each later Product's
destination to it. The template never renders that file either.

Two checks run against a cluster with a Gateway edge, never from CI. They go
through Infrared's API with a bearer token, as the UI does, and remove what they
made unless `KEEP=1`. The publish check starts one agent run, which is billed
to the org's Anthropic key, so it starts nothing without `SPEND=1`:

```bash
scripts/product-check.sh <context> <org> <token file>           # G1, G3 to G5: a Product from a starter zip is built, released and promoted, and its zone answers over HTTPS behind sign-in
SPEND=1 scripts/publish-check.sh <context> <org> <token file>   # G6: a step publishes an image and a chart, a zone runs the image by digest, and the step's key is refused outside its org's path
```

### Disabled components

`.Disabled` names components the template leaves out, by their Application
name: any Application in the table above but `appprojects`, `infrared` and
`argocd`, which `hack/render` refuses. The component's Application renders to
comments only, the root app-of-apps prunes it, and its resources finalizer
deletes what it deployed; the stores carry none, so they are only no longer
managed (see "The stores"). Only the Application is left out: the files under
`components/<name>/` still render, and nothing points at them. The repo's
README lists what was left out. `make verify` disables each optional component
in turn and checks that nothing else changes.

One name is not an Application: `substrate-test-actors` leaves Substrate's test
actors out of `substrate-actors` (see "Agent Substrate"). The Infrared chart
adds it, so it is neither carried in the `infrared` Application's
`components.disabled` nor listed in the repo's README as left out.

The template does not follow dependencies, so leave out only what nothing
else needs: without `external-secrets` the edge gets no tokens, without
`cert-manager` no certificates, without `kpack` there are no builds, and without
`postgres` SeaweedFS has no filer store.

Data that the component's chart never tracked outlives it, Infisical's
PersistentVolumeClaims and the Secret `infisical-secrets` for one. Deleting
the namespace removes them. A cluster that leaves out `infisical` runs
neither Infisical nor its bundled Postgres and Redis.

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
make render EDGE=gateway PLATFORM_DOMAIN=preprod.example.com INFRARED_HOST=infrared.preprod.example.com
make render STORES=true CLOUD=linode DISABLED='["infisical"]' \
  BACKUP='{"bucket": "acme-backups", "endpoint": "https://us-east-1.linodeobjects.com", "region": "us-east-1"}'
make render FORGE=gitea FORGE_URL=http://gitea-http.infrared.svc.cluster.local:3000
make render STORES=true REGISTRY=10.43.0.50:5000 BUILD_REGISTRY=10.43.0.50:5000
make render STORES=true REGISTRY=10.43.0.50:5000 SUBSTRATE_CAPABLE=true PULL_SECRET=ghcr-pull
make verify                             # the CI gate
scripts/compare-render.sh origin/main   # this tree's zero-value render against another ref's
```

`scripts/compare-render.sh <ref>` renders `<ref>` and this tree with the same
flags and fails unless every file `<ref>` renders is the same byte for byte,
or held no objects and is no longer rendered, and every file only this tree
renders holds no objects. Extra flags after the ref are passed to both renders
(e.g. `-flavor eks`); after `--`, to this tree's only (a field `<ref>` does not
know); after `--ref`, to `<ref>`'s only (what a renamed field was called
there).

`hack/render` (Go, stdlib only) implements the contract exactly; run it with
`-h` for every Data flag, or `-data file.json` to render from the same JSON
the operator uses. `scripts/verify.sh` renders both flavors, each with and without a build
registry (plus a non-ECR one), and checks: no template syntax or
`__cluster__` left, flavor-specific components, YAML parses, Application
conventions, the `infrared` Application's sources (chart pin first, the org's
values file as `$values`, nothing rendered into `values/`, the `$values` repo
allowed by AppProject `infrared`), every non-empty `components/*`
kustomization builds, builds is fully present with a registry (ECR login only
for ECR) and renders no objects without one, the registry inside the cluster
with `.Registry` and `.Stores` (Zot's chart, Service, Secrets and waits, the
store over `stores`, and builds pushed as `platform`) and nothing of it
without, Agent Substrate with `.Stores`, `.Registry` and `.SubstrateCapable`
(its four Applications and their layer label, every image by digest from the
pins, no PodMonitoring, its records and snapshots through `infrared-stores`,
atelet's image settings, the pull secret wherever it pulls, the
NetworkPolicies, the hooks and the ActorTemplates) and none of it without, and
kubeconform (`-strict`, Argo CD kinds against the public CRDs-catalog).

Bump upstream with `scripts/vendor-argocd.sh` / `scripts/vendor-kpack.sh`
(edit the version at the top), or by editing a chart `targetRevision`. Agent
Substrate: copy the new `substrate-images.json` over
`scripts/substrate-images.json`, run `scripts/vendor-substrate.sh`, and give each
ActorTemplate in `components/substrate-actors/templates.yaml` a new version in
its name.

## Cutting a version

1. Merge to `main` with `make verify` green.
2. Tag `vX.Y.Z` (semver) on that commit and push the tag. Tags are
   immutable: never move one.
3. Set infrared-chart's `gitops.templateVersion` to the tag in the chart's
   next release, in the same change as the operator image that can render it
   (a template that names a newer Data field needs an operator that has it).
   The chart's default always names a released tag, never a commit; the
   operator renders the version the API hands it from that value. Existing
   installations keep the version they were bootstrapped with; the rendered
   repo is theirs from then on.

Breaking the rendering contract or the Data fields is a major version.
