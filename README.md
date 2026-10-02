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
| `.Images` | `{"api": {"Tag": "v0.1.0", "Digest": "sha256:…"}, …}` | each component's pin (`INFRARED_IMAGES`), keyed `operator`, `api`, `ui`, `mcp`, `runner`; empty keeps the chart's. Read an entry with `index .Images "api"` (a missing key is the zero pin; `.Images.api` would fail the render), and test its `.Tag` or `.Digest`: `with` on an entry always runs |
| `.Cloud` | `` \| `aws` \| `linode` | the cloud of the nodes, from their providerID; `` is any other, or none |
| `.SubstrateCapable` | `false` | the operator's preflight: whether the cluster can host Agent Substrate. While it is false the template leaves Substrate out |
| `.Stores` | `false` \| `true` | the operator's `INFRARED_STORES`: `true` renders the platform's own stores, CloudNativePG with one Postgres Cluster and SeaweedFS (see "The stores") |
| `.Backup` | `{"Bucket": "acme-backups", "Endpoint": "https://us-east-1.linodeobjects.com", "Region": "us-east-1"}` | the operator's `INFRARED_BACKUP`: an S3-compatible bucket outside the cluster that the stores are copied to. An empty `.Backup.Bucket` turns backups off, and with `.Stores` false there is nothing to copy. `.Backup.Endpoint` is empty for AWS S3; `.Backup.Region` may be empty |
| `.Disabled` | `[]` or `["infisical"]` | the operator's `INFRARED_DISABLED_COMPONENTS`: components, by Application name, that the template leaves out (see "Disabled components"). No helper tests a list, so a template ranges over it: `[[ range .Disabled ]][[ if eq . "infisical" ]][[ $on = false ]][[ end ]][[ end ]]` |

The operator's JSON uses camelCase names for the older fields (`clusterName`,
…) and the Go names for the newer ones (`Edge`, `PlatformDomain`, …);
encoding/json matches them case-insensitively, so `hack/render -data` reads
either, and `Backup`'s keys as `INFRARED_BACKUP` spells them (`bucket`, …).
`hack/render` takes `-stores`, `-backup` as JSON and `-disabled` as a JSON
array, exactly as the operator's environment carries them. The zero value of every newer field renders exactly the files the
template rendered before the field existed. Only `.Edge` turns anything on: a
Traefik cluster that carries `spec.previews` by hand, on any cloud, renders
the same files as one without (`make verify` checks it). `.Cloud` and
`.SubstrateCapable` switch nothing yet; they are for the components that need
them (Linode's volume driver, Substrate).

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
pull secret, existing Secrets, build registry) win over the file.

## Components

| Wave | Application | Source | Pin |
|---|---|---|---|
| — | `registry-<cluster>` (root) | this repo, `registry/clusters/<cluster>/components` | `.DefaultBranch` |
| 0 | `appprojects` | `components/appprojects` | — |
| 10 | `cert-manager` | https://charts.jetstack.io `cert-manager` | v1.21.2 |
| 10 | `external-secrets` | https://charts.external-secrets.io `external-secrets` | 2.11.0 |
| 10 | `aws-load-balancer-controller` (eks only) | https://aws.github.io/eks-charts | 3.5.0 |
| 11 | `platform-tokens` (gateway, or backups) | `components/platform-tokens`: ClusterSecretStore `infrared-platform` | — |
| 11 | `envoy-gateway` (gateway only) | `docker.io/envoyproxy` `gateway-crds-helm` (its own CRDs) and `gateway-helm` | v1.9.2 |
| 11 | `origin-ca-issuer` (gateway only) | `ghcr.io/cloudflare/origin-ca-issuer-charts` `origin-ca-issuer`, CRDs from https://github.com/cloudflare/origin-ca-issuer `deploy/crds` | chart 0.6.10, v0.15.0 |
| 12 | `external-dns` (gateway only) | https://kubernetes-sigs.github.io/external-dns/ `external-dns` + `components/external-dns` | 1.22.0 (v0.22.0) |
| 13 | `edge` (gateway, with a name) | `components/edge` | — |
| 15 | `infisical` | cloudsmith `infisical-standalone` + `components/infisical` | 1.11.0 |
| 16 | `cloudnative-pg` (Stores only) | https://cloudnative-pg.github.io/charts `cloudnative-pg`, with a backup bucket also `plugin-barman-cloud` + `components/cloudnative-pg` | chart 0.29.1 (CloudNativePG 1.30.1), chart 0.8.1 (Barman Cloud plugin 0.15.1), by digest |
| 17 | `postgres` (Stores only) | `components/postgres` | PostgreSQL 18.6, by digest |
| 18 | `seaweedfs` (Stores only) | https://seaweedfs.github.io/seaweedfs/helm `seaweedfs` + `components/seaweedfs` | chart 4.48.0 (SeaweedFS 4.48, by digest) |
| 25 | `kpack` | `components/kpack` (vendored `release-0.18.0.yaml`) | v0.18.0 |
| 26 | `builds` (only with `.BuildRegistry`) | `components/builds` | Paketo buildpacks and stack by digest |
| 30 | `victoria-metrics-k8s-stack` | https://victoriametrics.github.io/helm-charts/ | 0.95.0 |
| 40 | `infrared` | `.InfraredChartRepo` `infrared`, values from this repo's `registry/clusters/<cluster>/values/infrared.yaml` | `.InfraredChartVersion` |
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
| `platform-tokens` | ClusterSecretStore `infrared-platform` (Kubernetes provider) reading the Secret `infrared-platform-tokens` in `.InfraredNamespace`, which the Infrared chart keeps, as ServiceAccount `platform-tokens-reader` (get on that one Secret). `conditions` limit it to the namespaces below. |
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
number, so the Cluster is the only object that names a Linode class, and
`make verify` checks it. On any other cloud the volume comes from the
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
outside the cluster, under `<Bucket>/<ClusterName>/`, and kept seven days.
`.Backup.Endpoint` is the S3 endpoint (empty for AWS S3) and `.Backup.Region`
its region. The keys are the platform's: the Secret `infrared-platform-tokens`
keys `backup-access-key-id` and `backup-secret-access-key`, which the store
`infrared-platform` copies into `stores` (`postgres-backup`,
`seaweedfs-backup`); the store's `conditions` then admit `stores` as well, and
`platform-tokens` renders even without a Gateway.

| What | How | Where | Kept |
|---|---|---|---|
| Postgres's WAL | continuously: CloudNativePG's Barman Cloud plugin archives each segment as it is written (the Cluster's plugin, `isWALArchiver`) | `s3://<Bucket>/<ClusterName>/postgres/` | seven days of point-in-time recovery (`retentionPolicy: 7d` on the ObjectStore `backup`) |
| Postgres's base backup | every day at 03:00 UTC, and once at the first sync (ScheduledBackup `postgres-daily`, `method: plugin`) | the same | the same |
| SeaweedFS's buckets `ate-snapshots` and `registry` | every hour at 17 past, CronJob `seaweedfs-backup`: rclone 1.75.1 makes `current/<bucket>/` match the bucket, and keeps what that run replaced or deleted under `archive/<run>/<bucket>/`; a mark `runs/<run>.json` says the run finished | `<Bucket>/<ClusterName>/seaweedfs/` | archives and marks for seven days, by the run's name |

A copy of every object at every hour would take 168 times the buckets' size,
so the buckets are kept as one mirror and the hourly changes to it. rclone reads
SeaweedFS as the S3 identity `backup`, which may only read and list the two
buckets. The plugin (chart 0.8.1, `plugin-barman-cloud` 0.15.1 and its sidecar,
by digest) is a second chart of `cloudnative-pg`; its mTLS certificates come
from `components/cloudnative-pg`, in waves of their own ahead of the charts,
with the chart's own turned off. Restoring is not here: the install's restore
comes later.

A Cluster built again from nothing writes its WAL to the same prefix, which
Barman refuses while an older server's archive is there: a restore names a new
server for the new Cluster.

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
make verify                             # the CI gate
scripts/compare-render.sh origin/main   # this tree's zero-value render against another ref's
```

`scripts/compare-render.sh <ref>` renders `<ref>` and this tree with the same
flags and fails unless every file `<ref>` renders is the same byte for byte
and every file only this tree renders holds no objects. Extra flags after the
ref are passed to both renders (e.g. `-flavor eks`).

`hack/render` (Go, stdlib only) implements the contract exactly; run it with
`-h` for every Data flag, or `-data file.json` to render from the same JSON
the operator uses. `scripts/verify.sh` renders both flavors, each with and without a build
registry (plus a non-ECR one), and checks: no template syntax or
`__cluster__` left, flavor-specific components, YAML parses, Application
conventions, the `infrared` Application's sources (chart pin first, the org's
values file as `$values`, nothing rendered into `values/`, the `$values` repo
allowed by AppProject `infrared`), every non-empty `components/*`
kustomization builds, builds is fully present with a registry (ECR login only
for ECR) and renders no objects without one, and kubeconform (`-strict`, Argo
CD kinds against the public CRDs-catalog).

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
