#!/usr/bin/env bash
# =============================================================================
# The gate for infrared-gitops-template. Runs locally (`make verify`) and in CI.
# =============================================================================
# It renders the template for both cluster flavors, each with and without a
# build registry, with hack/render (the same contract the operator implements)
# and asserts, on the rendered trees:
#   - the render tool builds, is gofmt-clean, vets and passes its tests
#   - no template syntax or __cluster__ segment survives rendering
#   - aws-load-balancer-controller exists on eks and not on k3s
#   - every file parses as YAML
#   - every Application under registry/ is labelled
#     app.kubernetes.io/part-of=infrared-gitops, and every component carries a
#     sync wave, a retry block and SkipDryRunOnMissingResource
#   - every Application names its layer with infrared.darkshift.io/layer, one
#     infrared-api knows, but the root and the ten on main, which keep their
#     files byte for byte and take their layer from their names
#   - the infrared Application takes the chart first (the operator reads its
#     pin as the first numeric targetRevision) and the org's values file from
#     this repo as $values; nothing renders into the org's values/ directory
#   - every kustomization under components/ that holds objects builds
#   - builds: with a build registry the Application, builder and credential
#     jobs are there (ECR login only for an ECR registry); without one no file
#     of it holds an object
#   - the edge: with Edge gateway (a variant rendered from a -data file, as the
#     operator passes it) Envoy Gateway, the origin issuer, external-dns, the
#     platform's tokens and the edge's Gateway, certificate and routes are
#     there and wired to each other; without it no file of them holds an object
#   - the stores: with Stores, CloudNativePG and one Postgres instance on one
#     20Gi volume (Linode's Retain class on Linode), with a role and a database
#     each for seaweedfs and substrate; SeaweedFS across the nodes with every
#     file on two of them, its filer metadata in that Postgres, the buckets
#     ate-snapshots and registry with an identity each and no key in the repo;
#     without Stores, no object of them
#   - only the Postgres Cluster and, with Forge gitea, Gitea's volume name a
#     Linode volume class, and only on Linode: each makes one volume
#   - the infrared Application carries the operator's image registry and pins,
#     and exactly the install's settings that are set: the edge and its
#     previews in gateway mode, the stores, the backup bucket, the components
#     left out, and Gitea with its admin Secret for Forge gitea
#   - order: a component that needs another one's webhook or store waits for it
#     in a PreSync hook, and an object a webhook admits has a sync wave of its
#     own in its component (the edge race of a first install)
#   - every chart or repo a platform Application pulls from is a source of the
#     AppProject platform, and nothing renders a LoadBalancer Service
#   - the infrared chart's repository is InfraredChartRepo, carried as the
#     chart's gitops.chartRepository, and the template registers none of it
#     with Argo CD (the operator does, with the pull secret's credential)
#   - the registry token (RegistryToken): the infrared Application carries
#     registryToken and names no pull secret; Substrate's images all come from
#     SubstrateRegistry by the pins' tags and digests, none from ghcr; the pull
#     secret's copies refresh every 5 minutes, and every hour without it
#   - nothing renders where the org's own files live (products/, product-*,
#     products-project.yaml, values/)
#   - with Edge "" or traefik, a platform domain, Infrared's host, a cloud and
#     the preflight's result change nothing: the render equals the plain one;
#     a backup bucket without the stores, and Forge gitea, change only the
#     infrared Application's values
#   - the registry inside the cluster, with Registry and Stores: Zot's
#     Application (chart, image by digest, one replica replaced not rolled, its
#     Service pinned to Registry's address, the operator's Secrets mounted and
#     never rendered, S3 keys from the store infrared-stores), zot-base's
#     config, the waits before Zot, and the store over stores; builds push the
#     builder as platform, by address, with kpack/infrared-builder; without
#     both, no object of them; Registry alone changes only the infrared
#     Application
#   - Agent Substrate, with Stores, Registry and SubstrateCapable together and
#     only then: four Applications, waves 20 to 23, labelled
#     infrared.darkshift.io/layer: agent-runtime; every image by digest, its
#     own the pins in scripts/substrate-images.json, nothing left to ko, no
#     PodMonitoring; snapshots in SeaweedFS's ate-snapshots and records in the
#     platform's Postgres, copied through infrared-stores; atelet pulling
#     localhost images from the registry inside the cluster; the pull secret
#     wherever Substrate pulls; the NetworkPolicies that admit only Infrared's
#     operator, Substrate and the platform's jobs; the hooks that make the CAs,
#     label the nodes, copy the actor images and make the ActorTemplates; and
#     the preflight's yes alone, without the stores or the registry, changes no
#     file
#   - Substrate's test actors: substrate-test-actors in Disabled leaves out
#     counter-v1, sandbox-v1, the copy of their images and the registry's pull
#     secret, and changes nothing else but the README, the comments that name
#     them and the infrared Application, which never carries the name and
#     carries substrate.testActors: true with the stores and a registry exactly
#     when the name is absent
#   - Infrared's code index, with the image registry and its pin among the
#     images (INFRARED_IMAGES, code-index), as the chart hands it over with
#     codeIndex.enabled: its Application (wave 41, layer infrared, namespace
#     code-index under Pod Security restricted); one replica replaced not
#     rolled, both containers not root on a read-only filesystem, the image the
#     pin names, the cache on an emptyDir, its settings and credential Secrets
#     optional; the Service code-index on 8080; a NetworkPolicy that admits
#     infrared-api's pods alone; its record and its GitHub App copied from the
#     install's infrared-platform-tokens through infrared-platform, which then
#     admits code-index, after a wait for that store; with a pull secret, its
#     copy too; the infrared Application carrying codeIndex and
#     platformTokens.existingSecret; and without both, no object of it, and the
#     pin alone changes nothing
#   - metrics: on k3s with the stores VMSingle's data on an emptyDir of 10Gi
#     and no claim (a request of no space), otherwise its 10Gi claim as before;
#     and nothing else in the stack asks for a claim
#   - backups, with a backup bucket: the buckets copied hourly, kept 7 days,
#     with the platform's backup keys, under the install's name or
#     .Backup.Prefix; with .PostgresArchive.Enabled as well, Postgres's WAL
#     and a daily base backup through the Barman Cloud plugin, and without it
#     (the default) nothing of the plugin, the ObjectStore, the ScheduledBackup
#     or Postgres's key copy; without a bucket, no backup object
#   - backups on Google Cloud Storage (.Backup.Provider gcs): the mirror and
#     the copy back use rclone's own backend as the ServiceAccounts
#     seaweedfs-backup (rendered beside the CronJob) and stores-restore, which
#     the cluster grants the bucket's role through Workload Identity; no key
#     Secret, ExternalSecret or endpoint in stores, the WAL archive refused;
#     the other providers render as before
#   - the backups' settings (.Copies, .PostgresArchive): the mirror's and
#     Postgres's schedules and retentions as set, today's when not; with
#     recipients, no bucket or identity of their own: the mirror's run mark
#     names the newest complete backup under <prefix>/backups/ (a run of the
#     mark's script against a fake bucket proves which), and the Postgres role
#     substrate's Secret is copied into the Infrared namespace for the backup's
#     dump through infrared-stores, which then renders even without a
#     registry; Zot's retention as set (.RegistryRetention); the archive's
#     server name (.PostgresServerName); and the backup key's Secret and keys
#     (.Backup.Credentials), whose defaults sent explicitly render the same
#     files as none
#   - a restore (.Restore): Postgres starts empty, with no index reset; the
#     stores-restore Application's one Job waits for the mark postgres, which
#     the Infrared chart's restore Job sets once the backup's dumps are back,
#     then copies every bucket back without overwriting and marks buckets in
#     stores/restore-stores; SeaweedFS waits for postgres, Zot and Substrate
#     for the buckets, and the mirror copies nothing until they are back; a
#     restore changes only those files, and the infrared Application never
#     carries it
#   - each of the new settings without the stores changes only the infrared
#     Application, or nothing
#   - a component named in Disabled renders its Application to comments only,
#     and nothing else changes but the repo's README.md and the infrared
#     Application's components.disabled
#   - kubeconform accepts all of it (-strict; CRD kinds are checked against the
#     public CRDs-catalog schemas, Agent Substrate's against its vendored CRDs,
#     and kinds neither has are skipped)
#
# Needs: go, kubectl, kubeconform, yq (mikefarah v4). Network for kubeconform's
# schemas.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

for tool in go kubectl kubeconform yq; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done

fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }
ok() { echo "ok:   $*"; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- render tool ---------------------------------------------------------------
unformatted="$(gofmt -l hack)"
[ -z "$unformatted" ] && ok "gofmt" || bad "gofmt: $unformatted"
go vet ./... && ok "go vet" || bad "go vet"
go test ./... >/dev/null && ok "go test" || bad "go test"
go build -o "$work/render" ./hack/render

# --- render ----------------------------------------------------------------------
# The gateway variant's Data, as the operator passes it: camelCase for the older
# fields, Go names for the newer, images from a registry other than the chart's,
# and a commit SHA for the template version.
gw_domain=preprod.example.com
gw_host=infrared.preprod.example.com
cat >"$work/gateway.json" <<EOF
{
  "orgName": "demo-org",
  "gitopsRepoOwner": "demo-org",
  "gitopsRepoName": "gitops",
  "gitopsRepoURL": "https://github.com/demo-org/gitops",
  "defaultBranch": "main",
  "templateVersion": "0123456789012345678901234567890123456789",
  "infraredVersion": "v0.1.0",
  "infraredChartRepo": "ghcr.io/darkshiftio/charts",
  "infraredChartVersion": "0.1.0",
  "infraredNamespace": "infrared",
  "imagePullSecret": "infrared-pull",
  "Edge": "gateway",
  "PlatformDomain": "$gw_domain",
  "InfraredHost": "$gw_host",
  "ImageRegistry": "ghcr.io/demo-org",
  "Images": {
    "operator": {"tag": "v0.1.0", "digest": "sha256:0000000000000000000000000000000000000000000000000000000000000001"},
    "api": {"tag": "v0.1.0", "digest": "sha256:0000000000000000000000000000000000000000000000000000000000000002"},
    "ui": {"tag": "v0.1.0", "digest": "sha256:0000000000000000000000000000000000000000000000000000000000000003"},
    "mcp": {"tag": "v0.1.0", "digest": "sha256:0000000000000000000000000000000000000000000000000000000000000004"},
    "runner": {"tag": "v0.1.0", "digest": "sha256:0000000000000000000000000000000000000000000000000000000000000005"}
  },
  "Cloud": "linode",
  "SubstrateCapable": false
}
EOF

# The gateway variant off Linode (Cloud ""): the same edge on a cluster that
# does not bring the Gateway API CRDs itself, such as GKE, where Envoy's chart
# installs them (Google Cloud run 1, 2026-10-07).
yq -p json -o json '. + {"Cloud": ""}' "$work/gateway.json" >"$work/gateway-nocloud.json"

# The stores variant: the gateway's Data plus the platform's own stores, on
# Linode, with Infisical left out, the stores backed up outside, and Gitea as
# the forge: the shape of a Linode install that runs Gitea.
backup_bucket=acme-backups
backup_endpoint=https://objects.example.com
gitea_url=http://gitea-http.infrared.svc.cluster.local:3000
yq -p json -o json '. + {"Stores": true, "Disabled": ["infisical"],
    "Backup": {"Bucket": "'"$backup_bucket"'", "Endpoint": "'"$backup_endpoint"'", "Region": "region-1"},
    "Forge": "gitea", "ForgeURL": "'"$gitea_url"'"}' \
  "$work/gateway.json" >"$work/stores.json"

# The registry variant: the stores' Data plus the registry inside the cluster,
# which builds push to by address: the shape of the one install.
zot_registry=10.43.0.50:5000
yq -p json -o json '. + {"Registry": "'"$zot_registry"'"}' "$work/stores.json" >"$work/registry.json"

# The Substrate variant: the registry's Data with the preflight's yes, the shape
# of the one install. Agent Substrate renders with Stores, Registry and
# SubstrateCapable together, and only then. Its images are the pins in
# scripts/substrate-images.json.
yq -p json -o json '. + {"SubstrateCapable": true}' "$work/registry.json" >"$work/substrate.json"
substrate_pins=scripts/substrate-images.json

# The copies variant: Substrate's Data with backups on: an age recipient (age's
# own example key), the mirror's and Postgres's schedules and retentions, the
# archive on, a prefix of its own, the backup key's credentials as the operator
# sends them (today's defaults, spelled out), Zot's retention and the archive's
# server name: the one install with backups on. copies-noreg: the stores' Data
# with a recipient alone, no registry. The restore variants: a restore in
# progress, with and without backups.
age_recipient=age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
server_name=postgres-20261003T060000Z
restore_point=20261006T010500Z
restore_run=20261006T011700Z
backup_prefix=acme-mgmt
yq -p json -o json '. + {
    "Copies": {"Recipients": ["'"$age_recipient"'"], "Mirror": {"Schedule": "47 * * * *", "Retention": "10d"}},
    "PostgresArchive": {"Enabled": true, "Schedule": "0 30 2 * * *", "Retention": "14d"},
    "RegistryRetention": {"UntaggedAfter": "48h", "KeepTags": ["^v[0-9]", "^release-"], "KeepNewest": 20, "GCInterval": "2h", "GCDelay": "30m"},
    "PostgresServerName": "'"$server_name"'"}
  | .Backup.Prefix = "'"$backup_prefix"'"
  | .Backup.Credentials = {"Secret": "infrared-platform-tokens", "AccessKeyIDKey": "backup-access-key-id",
      "SecretKeyKey": "backup-secret-access-key", "Kind": "accessKey"}' "$work/substrate.json" >"$work/copies.json"
# The test actors off: Substrate's Data with substrate-test-actors among the
# components left out, as the Infrared chart hands it over by default.
yq -p json -o json '.Disabled += ["substrate-test-actors"]' "$work/substrate.json" >"$work/substrate-off.json"
# The code index on: Substrate's Data with the code index's image among
# Infrared's own (INFRARED_IMAGES, code-index), as the Infrared chart hands it
# over with codeIndex.enabled, the one install's shape with the code index; the
# gateway's Data with it and no pull secret; and below, on Traefik with a pull
# secret and nothing else, and with nothing else at all, where the code index
# alone brings the store infrared-platform.
ci_tag=one-install-0123456
ci_digest=sha256:00000000000000000000000000000000000000000000000000000000000000c1
ci_images="{\"code-index\":{\"tag\":\"$ci_tag\",\"digest\":\"$ci_digest\"}}"
yq -p json -o json '.Images["code-index"] = {"tag": "'"$ci_tag"'", "digest": "'"$ci_digest"'"}' "$work/substrate.json" >"$work/code-index.json"
yq -p json -o json '.Images["code-index"] = {"tag": "'"$ci_tag"'", "digest": "'"$ci_digest"'"} | .imagePullSecret = ""' \
  "$work/gateway.json" >"$work/code-index-plain.json"
yq -p json -o json '. + {"Copies": {"Recipients": ["'"$age_recipient"'"]}}' "$work/stores.json" >"$work/copies-noreg.json"
yq -p json -o json '. + {"Restore": {"Point": "'"$restore_point"'", "Artifact": "'"$restore_point"'.irbackup", "MirrorRun": "'"$restore_run"'"}}' \
  "$work/copies.json" >"$work/restore.json"
yq -p json -o json '. + {"Restore": {"Point": "'"$restore_point"'"}, "PostgresServerName": "'"$server_name"'"}' "$work/substrate.json" >"$work/restore-plain.json"
# The Google variant: the copies' Data with the bucket on Google Cloud Storage
# (Provider gcs, the credential's kind serviceAccount, no key) and Barman's
# archive off, which gcs refuses; and a restore from it.
gcs_bucket=acme-google-backup
gcs_endpoint=https://storage.googleapis.com
yq -p json -o json '.Backup = {"Bucket": "'"$gcs_bucket"'", "Provider": "gcs", "Endpoint": "'"$gcs_endpoint"'", "Region": "us-central1",
    "Prefix": "'"$backup_prefix"'", "Credentials": {"Kind": "serviceAccount"}} | .PostgresArchive.Enabled = false' "$work/copies.json" >"$work/gcs.json"
yq -p json -o json '. + {"Restore": {"Point": "'"$restore_point"'", "Artifact": "'"$restore_point"'.irbackup", "MirrorRun": "'"$restore_run"'"}}' \
  "$work/gcs.json" >"$work/gcs-restore.json"
# The registry token: Substrate's Data on GKE (Cloud ""), the chart and
# Substrate's images on a private Artifact Registry, and the pull secret an
# access token of a Google service account the chart rewrites every 30 minutes
# (the chart's registryToken), the shape of a Google install.
ar_host=us-central1-docker.pkg.dev
ar_repo=$ar_host/acme-preprod/infrared
token_gsa="registry-reader@acme-preprod.iam.gserviceaccount.com"
yq -p json -o json '. + {"Cloud": "", "imagePullSecret": "registry-token", "infraredChartRepo": "'"$ar_repo"'/charts",
    "SubstrateRegistry": "'"$ar_repo"'/substrate",
    "RegistryToken": {"GCPServiceAccount": "'"$token_gsa"'", "Registry": "'"$ar_host"'"}}' "$work/substrate.json" >"$work/registry-token.json"
# The registry token on AWS: the chart and Substrate's images in ECR, and the
# pull secret an ECR token of the cluster's role (an IRSA role here) the chart
# rewrites every 30 minutes, the shape of an install on EKS or EC2.
ecr_host=123456789012.dkr.ecr.us-east-1.amazonaws.com
yq -p json -o json '. + {"Cloud": "", "imagePullSecret": "registry-token", "infraredChartRepo": "'"$ecr_host"'/charts",
    "SubstrateRegistry": "'"$ecr_host"'/substrate",
    "RegistryToken": {"AWSRegion": "us-east-1", "AWSRoleARN": "arn:aws:iam::123456789012:role/infrared-registry-token", "Registry": "'"$ecr_host"'"}}' \
  "$work/substrate.json" >"$work/registry-token-aws.json"
# The same on EC2 nodes: the node's own role, no IRSA, read on the node's network.
yq -p json -o json '.RegistryToken = {"AWSRegion": "us-east-1", "AWSHostNetwork": true, "Registry": "'"$ecr_host"'"}' \
  "$work/registry-token-aws.json" >"$work/registry-token-aws-ec2.json"

# <variant> <cluster> <flavor> <build registry> [extra render flags]
ecr_registry=123456789012.dkr.ecr.us-east-1.amazonaws.com/acme
variants=(
  "k3s demo k3s -"
  "eks demo-eks eks - -region us-west-2 -repo-url git@github.com:demo-org/gitops.git -pull-secret infrared-pull"
  "k3s-builds demo-b k3s $ecr_registry"
  "eks-builds demo-eks-b eks $ecr_registry -region us-west-2 -pull-secret infrared-pull"
  "gateway demo-gw k3s - -data $work/gateway.json"
  "gateway-nocloud demo-gn k3s - -data $work/gateway-nocloud.json"
  "stores demo-st k3s - -data $work/stores.json"
  "stores-plain demo-sp k3s - -stores"
  "stores-backup demo-sb k3s - -stores -backup {\"bucket\":\"$backup_bucket\"}"
  "gitea demo-gt k3s - -forge gitea -forge-url $gitea_url"
  "gitea-builds demo-gb k3s 10.43.0.50:5000/demo-org -forge gitea -forge-url $gitea_url"
  "registry demo-rg k3s $zot_registry -data $work/registry.json"
  "registry-plain demo-rp k3s $zot_registry -stores -registry $zot_registry"
  "substrate demo-su k3s $zot_registry -data $work/substrate.json"
  "substrate-off demo-so k3s $zot_registry -data $work/substrate-off.json"
  "substrate-plain demo-ss k3s - -stores -registry $zot_registry -substrate-capable"
  "substrate-pull demo-sl k3s - -stores -registry $zot_registry -substrate-capable -pull-secret ghcr-pull"
  "registry-token demo-rt k3s $zot_registry -data $work/registry-token.json"
  "registry-token-aws demo-ra k3s $zot_registry -data $work/registry-token-aws.json"
  "registry-token-aws-ec2 demo-re k3s $zot_registry -data $work/registry-token-aws-ec2.json"
  "copies demo-cp k3s $zot_registry -data $work/copies.json"
  "copies-noreg demo-cn k3s - -data $work/copies-noreg.json"
  "restore demo-rs k3s $zot_registry -data $work/restore.json"
  "restore-plain demo-rr k3s $zot_registry -data $work/restore-plain.json"
  "gcs demo-gc k3s $zot_registry -data $work/gcs.json"
  "gcs-restore demo-gr k3s $zot_registry -data $work/gcs-restore.json"
  "code-index demo-ci k3s $zot_registry -data $work/code-index.json"
  "code-index-plain demo-cx k3s - -data $work/code-index-plain.json"
  "code-index-pull demo-cq k3s - -image-registry ghcr.io/demo-org -pull-secret ghcr-pull -images $ci_images"
  "code-index-nopull demo-cy k3s - -image-registry ghcr.io/demo-org -images $ci_images"
)
for v in "${variants[@]}"; do
  read -r variant cluster flavor registry extra <<<"$v"
  [ "$registry" = - ] && registry=""
  # shellcheck disable=SC2086
  "$work/render" -out "$work/$variant" -cluster "$cluster" -flavor "$flavor" -build-registry "$registry" $extra
done

# Agent Substrate's own kinds have no public schema: kubeconform checks them
# against the vendored CRDs' (WorkerPool, SandboxConfig, CSIDriverConfig).
mkdir -p "$work/schemas"
kubectl kustomize "$work/substrate/components/substrate-crds" >"$work/substrate-crds.yaml"
for kind in $(yq -N -r 'select(.kind == "CustomResourceDefinition") | .spec.names.kind' "$work/substrate-crds.yaml"); do
  for version in $(yq -N -r "select(.spec.names.kind == \"$kind\") | .spec.versions[].name" "$work/substrate-crds.yaml"); do
    yq -o json "select(.spec.names.kind == \"$kind\") | .spec.versions[] | select(.name == \"$version\") | .schema.openAPIV3Schema" \
      "$work/substrate-crds.yaml" >"$work/schemas/$(tr '[:upper:]' '[:lower:]' <<<"$kind")_$version.json"
  done
done

# The platform's layers, as infrared-api names them (internal/server/layers.go),
# in the order they become available; and the Applications on main, which carry
# no layer label so that their files stay byte for byte as they were: the root
# app-of-apps (registry-$cluster) and the ten under components/.
known_layers="infrared version-control gitops secrets certificates edge databases object-storage registry agent-runtime build-runtime observability backups"
# shellcheck disable=SC2016 # $cluster is replaced per variant, below.
unlabelled='registry-$cluster appprojects argocd aws-load-balancer-controller builds cert-manager external-secrets infisical infrared kpack victoria-metrics-k8s-stack'
layers_labelled=0 layers_by_name=0

# holds_objects <file>: true when the YAML file has at least one object.
holds_objects() { [ -n "$(yq -N -r '.kind // ""' "$1" 2>/dev/null | grep -v '^$' || true)" ]; }
# sel <file> <yq expression>: what the expression yields, one value a line.
sel() { yq -N -r "$2" "$1" 2>/dev/null || true; }
# line <file> <yq expression>: the same, joined on one line with spaces.
line() { sel "$1" "$2" | grep -v '^$' | tr '\n' ' ' | sed 's/ $//'; }

for v in "${variants[@]}"; do
  read -r variant cluster flavor registry extra <<<"$v"
  [ "$registry" = - ] && registry=""
  out="$work/$variant"
  # The pull secret this variant passes, by flag or in its -data file.
  pull_secret="$(sed -n -E 's/.*-pull-secret ([^ ]+).*/\1/p' <<<"${extra:-}")"
  data_file="$(sed -n -E 's/.*-data ([^ ]+).*/\1/p' <<<"${extra:-}")"
  if [ -z "$pull_secret" ] && [ -n "$data_file" ]; then
    pull_secret="$(yq -p json -r '.imagePullSecret // .ImagePullSecret // ""' "$data_file")"
  fi
  # The variant's edge, stores, cloud, names, backup bucket, components left
  # out and forge, by flag or in its -data file.
  edge="$(sed -n -E 's/.*-edge ([^ ]+).*/\1/p' <<<"${extra:-}")"
  stores=false cloud="" backup="" endpoint="" region="" provider="" domain="" host="" disabled="[]"
  forge="$(sed -n -E 's/.*-forge ([^ ]+).*/\1/p' <<<"${extra:-}")"
  grep -qw -- -stores <<<"${extra:-}" && stores=true
  capable=false
  grep -qw -- -substrate-capable <<<"${extra:-}" && capable=true
  # The backups' settings, Zot's retention, the archive's server name and a
  # restore: only the -data variants set them. *_app is what the infrared
  # Application carries.
  copies_recipients="[]" pg_archive=false pg_schedule="" pg_retention="" mirror_schedule="" mirror_retention=""
  pg_server="" restoring_point="" prefix="" backup_app="{}" retention_app="{}"
  zot_addr="$(sed -n -E 's/(^|.* )-registry ([^ ]+).*/\2/p' <<<"${extra:-}")"
  backup="$(sed -n -E 's/.*-backup [^ ]*"bucket":"([^"]*)".*/\1/p' <<<"${extra:-}")"
  if [ -n "$data_file" ]; then
    edge="$(yq -p json -r '.Edge // ""' "$data_file")"
    stores="$(yq -p json -r '.Stores // false' "$data_file")"
    cloud="$(yq -p json -r '.Cloud // ""' "$data_file")"
    backup="$(yq -p json -r '.Backup.Bucket // ""' "$data_file")"
    endpoint="$(yq -p json -r '.Backup.Endpoint // ""' "$data_file")"
    region="$(yq -p json -r '.Backup.Region // ""' "$data_file")"
    provider="$(yq -p json -r '.Backup.Provider // ""' "$data_file")"
    domain="$(yq -p json -r '.PlatformDomain // ""' "$data_file")"
    host="$(yq -p json -r '.InfraredHost // ""' "$data_file")"
    disabled="$(yq -p json -o json -I0 '.Disabled // []' "$data_file")"
    forge="$(yq -p json -r '.Forge // ""' "$data_file")"
    zot_addr="$(yq -p json -r '.Registry // ""' "$data_file")"
    capable="$(yq -p json -r '.SubstrateCapable // false' "$data_file")"
    copies_recipients="$(jq -c '.Copies.Recipients // []' "$data_file")"
    pg_archive="$(jq -r '.PostgresArchive.Enabled // false' "$data_file")"
    pg_schedule="$(jq -r '.PostgresArchive.Schedule // ""' "$data_file")"
    pg_retention="$(jq -r '.PostgresArchive.Retention // ""' "$data_file")"
    mirror_schedule="$(jq -r '.Copies.Mirror.Schedule // ""' "$data_file")"
    mirror_retention="$(jq -r '.Copies.Mirror.Retention // ""' "$data_file")"
    pg_server="$(jq -r '.PostgresServerName // ""' "$data_file")"
    restoring_point="$(jq -r '.Restore.Point // ""' "$data_file")"
    prefix="$(jq -r '.Backup.Prefix // ""' "$data_file")"
    # The backups' settings that are set, as the chart's backup values name
    # them: recipients, mirror.schedule, retention (the mirror's) and
    # postgres.archive.
    backup_app="$(jq -c '(.Copies // {}) as $c
      | {recipients: ($c.Recipients // []), mirror: {schedule: ($c.Mirror.Schedule // "")},
         retention: ($c.Mirror.Retention // ""), postgres: {archive: (.PostgresArchive.Enabled // false)}}
      | .mirror |= with_entries(select(.value != "")) | .postgres |= with_entries(select(.value == true))
      | with_entries(select(.value != {} and .value != [] and .value != ""))' "$data_file")"
    retention_app="$(jq -c '(.RegistryRetention // {})
      | {untaggedAfter: .UntaggedAfter, keepTags: .KeepTags, keepNewest: .KeepNewest, gcInterval: .GCInterval, gcDelay: .GCDelay}
      | with_entries(select(.value != null and .value != "" and .value != [] and .value != 0))' "$data_file")"
  fi
  # Agent Substrate: the stores, the registry and the preflight's yes.
  substrate=false
  [ "$stores" = true ] && [ -n "$zot_addr" ] && [ "$capable" = true ] && substrate=true
  # The infrared Application carries the install's backup bucket even without
  # the stores, but backups need the stores.
  carried_backup="$backup"
  [ "$stores" = true ] || backup=""
  # The copies' buckets need the stores, a backup bucket and a recipient; a
  # restore the stores and a backup bucket; the WAL archive the stores, a
  # backup bucket and .PostgresArchive.Enabled.
  copies_on=false restoring=false archive_on=false
  # Substrate's test actors: on unless substrate-test-actors is left out. The
  # infrared Application never carries that name, and carries
  # substrate.testActors: true with the stores and a registry when it is absent.
  test_actors=true carried_disabled="$disabled"
  if jq -e 'index("substrate-test-actors") != null' <<<"$disabled" >/dev/null; then test_actors=false; fi
  carried_disabled="$(jq -c 'map(select(. != "substrate-test-actors"))' <<<"$disabled")"
  [ -n "$backup" ] && [ "$copies_recipients" != "[]" ] && copies_on=true
  [ -n "$backup" ] && [ -n "$restoring_point" ] && restoring=true
  [ -n "$backup" ] && [ "$pg_archive" = true ] && archive_on=true
  # The code index: on with the image registry and its pin among the images,
  # by flag or in the -data file; with a pull secret, copied through
  # infrared-platform.
  image_registry="$(sed -n -E 's/.*-image-registry ([^ ]+).*/\1/p' <<<"${extra:-}")"
  var_images="$(sed -n -E 's/.*-images ([^ ]+).*/\1/p' <<<"${extra:-}")"
  if [ -n "$data_file" ]; then
    image_registry="$(yq -p json -r '.ImageRegistry // ""' "$data_file")"
    var_images="$(yq -p json -o json -I0 '.Images // {}' "$data_file")"
  fi
  [ -n "$var_images" ] || var_images='{}'
  pin_tag="$(jq -r '(.["code-index"] // {}) | (.tag // .Tag // "")' <<<"$var_images")"
  pin_digest="$(jq -r '(.["code-index"] // {}) | (.digest // .Digest // "")' <<<"$var_images")"
  code_index=false ci_pull=false
  if [ -n "$image_registry" ] && { [ -n "$pin_tag" ] || [ -n "$pin_digest" ]; }; then code_index=true; fi
  [ "$code_index" = true ] && [ -n "$pull_secret" ] && ci_pull=true
  # The chart's repository, where Substrate's images come from, and the
  # registry token, by flag or in the -data file.
  chart_repo="$(sed -n -E 's/.*-chart-repo ([^ ]+).*/\1/p' <<<"${extra:-}")"
  sub_registry="$(sed -n -E 's/.*-substrate-registry ([^ ]+).*/\1/p' <<<"${extra:-}")"
  token_gsa="" token_host="" token_region="" token_role="" token_hostnet=""
  if [ -n "$data_file" ]; then
    chart_repo="$(jq -r '.infraredChartRepo // .InfraredChartRepo // ""' "$data_file")"
    sub_registry="$(jq -r '.SubstrateRegistry // ""' "$data_file")"
    token_gsa="$(jq -r '.RegistryToken.GCPServiceAccount // ""' "$data_file")"
    token_host="$(jq -r '.RegistryToken.Registry // ""' "$data_file")"
    token_region="$(jq -r '.RegistryToken.AWSRegion // ""' "$data_file")"
    token_role="$(jq -r '.RegistryToken.AWSRoleARN // ""' "$data_file")"
    token_hostnet="$(jq -r '.RegistryToken.AWSHostNetwork // false' "$data_file")"
  fi
  [ -n "$chart_repo" ] || chart_repo=us-central1-docker.pkg.dev/darkshift-preprod/infrared/charts
  sub_reg="${sub_registry:-ghcr.io/darkshiftio/substrate}"

  # Leftover template syntax, only in files that came from a .tmpl (vendored
  # upstream files are copied verbatim and are none of our business).
  while IFS= read -r t; do
    rel="${t#template/}"; rel="${rel%.tmpl}"
    rel="${rel//__cluster__/$cluster}"
    if grep -nE '\[\[|\]\]' "$out/$rel" >/dev/null; then bad "$variant: template syntax left in $rel"; fi
  done < <(find template -type f -name '*.tmpl')
  if find "$out" -name '*__cluster__*' | grep -q .; then bad "$variant: __cluster__ left in a path"; fi
  if find "$out" -name '*.tmpl' | grep -q .; then bad "$variant: a .tmpl suffix survived"; fi

  # Every file parses.
  while IFS= read -r f; do
    yq -e 'true' "$f" >/dev/null 2>&1 || yq '.' "$f" >/dev/null 2>&1 || bad "$variant: $f does not parse as YAML"
  done < <(find "$out" -type f \( -name '*.yaml' -o -name '*.yml' \))

  reg="$out/registry/clusters/$cluster"
  [ -f "$reg/registry.yaml" ] || bad "$variant: no registry.yaml"
  [ "$(yq -r '.metadata.name' "$reg/registry.yaml")" = "registry-$cluster" ] || bad "$variant: root Application is not registry-$cluster"

  # Application conventions.
  for f in "$reg/registry.yaml" "$reg"/components/*.yaml; do
    holds_objects "$f" || continue
    [ "$(yq -N -r '.metadata.labels["app.kubernetes.io/part-of"]' "$f")" = "infrared-gitops" ] \
      || bad "$variant: $(basename "$f") lacks app.kubernetes.io/part-of: infrared-gitops"
    [ "$(yq -N -r '.spec.syncPolicy.retry.limit' "$f")" = "5" ] || bad "$variant: $(basename "$f") retry.limit is not 5"
    if [ "$f" != "$reg/registry.yaml" ]; then
      [ "$(yq -N -r '.metadata.annotations["argocd.argoproj.io/sync-wave"] // ""' "$f")" != "" ] \
        || bad "$variant: $(basename "$f") has no sync wave"
      yq -N -e '.spec.syncPolicy.syncOptions[] | select(. == "SkipDryRunOnMissingResource=true")' "$f" >/dev/null \
        || bad "$variant: $(basename "$f") lacks SkipDryRunOnMissingResource=true"
    fi
  done

  # Layers: every Application names its layer with infrared.darkshift.io/layer,
  # one of the layers infrared-api knows, except the root and the ten
  # Applications on main, which keep their files byte for byte and take their
  # layer from their names (README, "Layers and wave bands").
  for f in "$reg/registry.yaml" "$reg"/components/*.yaml; do
    holds_objects "$f" || continue
    while IFS=$'\t' read -r name layer; do
      [ -n "$name" ] || continue
      if [ -z "$layer" ]; then
        # Whole names only: grep -w would take a hyphen for a word's end.
        if tr ' ' '\n' <<<"${unlabelled//\$cluster/$cluster}" | grep -qxF -- "$name"; then
          layers_by_name=$((layers_by_name + 1))
        else
          bad "$variant: Application $name has no infrared.darkshift.io/layer"
        fi
      elif tr ' ' '\n' <<<"$known_layers" | grep -qxF -- "$layer"; then
        layers_labelled=$((layers_labelled + 1))
      else
        bad "$variant: Application $name names layer $layer, which infrared-api does not know ($known_layers)"
      fi
    done < <(sel "$f" 'select(.kind == "Application") | [.metadata.name, (.metadata.labels["infrared.darkshift.io/layer"] // "")] | @tsv')
  done

  # Flavor-specific components.
  alb="$(yq -N -r '.kind // ""' "$reg/components/aws-load-balancer-controller.yaml" | grep -c Application || true)"
  if [ "$flavor" = eks ]; then
    [ "$alb" = 1 ] && ok "$variant: aws-load-balancer-controller present" || bad "$variant: aws-load-balancer-controller missing"
  else
    [ "$alb" = 0 ] && ok "$variant: aws-load-balancer-controller absent" || bad "$variant: aws-load-balancer-controller rendered"
  fi
  # Metrics: on k3s with the stores VMSingle's data is on an emptyDir of 10Gi,
  # named data, and its claim asks for no space, which the operator makes no
  # claim for (a null would not survive an apply of the Application); without
  # the stores, and on EKS, its 10Gi claim of the default class, as before.
  # Nothing else in the stack asks for a claim: Grafana's persistence,
  # Alertmanager's storage and vmagent's stateful mode stay off.
  vm="$reg/components/victoria-metrics-k8s-stack.yaml"
  if holds_objects "$vm"; then
    vmsingle="$(yq -o json -I0 '.spec.source.helm.valuesObject.vmsingle.spec | {"storage": .storage, "volumes": .volumes}' "$vm")"
    vm_empty=false
    [ "$flavor" = k3s ] && [ "$stores" = true ] && vm_empty=true
    if [ "$vm_empty" = true ]; then
      want_vm='{"storage":{"resources":{"requests":{"storage":"0"}}},"volumes":[{"name":"data","emptyDir":{"sizeLimit":"10Gi"}}]}'
    else
      want_vm='{"storage":{"resources":{"requests":{"storage":"10Gi"}}},"volumes":null}'
    fi
    [ "$vmsingle" = "$want_vm" ] \
      && [ "$(yq -r '.spec.source.helm.valuesObject | [(.grafana.persistence.enabled // false), (.alertmanager.spec.storage // "none"), (.vmagent.spec.statefulMode // false), (.vmagent.spec.statefulStorage // "none")] | join(" ")' "$vm")" = "false none false none" ] \
      && ok "$variant: VMSingle's data $([ "$vm_empty" = true ] && echo "on an emptyDir of 10Gi, no claim" || echo "on a 10Gi claim"), and nothing else in the stack asks for one" \
      || bad "$variant: VMSingle's storage is $vmsingle, want $want_vm, or another part of the stack asks for a claim"
  fi
  if [ -n "$token_host" ]; then
    # The chart derives its pull secret from registryToken: none named here.
    [ "$(yq -r '.spec.sources[0].helm.valuesObject.imagePullSecrets | length' "$reg/components/infrared.yaml")" = 0 ] \
      && ok "$variant: the infrared Application names no pull secret: the chart's registryToken is it" \
      || bad "$variant: imagePullSecrets should be empty with the registry token"
  elif [ -n "$pull_secret" ]; then
    [ "$(yq -r '.spec.sources[0].helm.valuesObject.imagePullSecrets[0].name' "$reg/components/infrared.yaml")" = "$pull_secret" ] \
      || bad "$variant: imagePullSecrets not rendered into the infrared Application"
  else
    [ "$(yq -r '.spec.sources[0].helm.valuesObject.imagePullSecrets | length' "$reg/components/infrared.yaml")" = 0 ] \
      || bad "$variant: imagePullSecrets should be empty"
  fi
  [ "$(yq -r '.spec.sources[0].helm.valuesObject.builds.registry' "$reg/components/infrared.yaml")" = "$registry" ] \
    || bad "$variant: infrared Application builds.registry is not \"$registry\""
  # The chart's repository, which Argo CD pulls the chart from, carried as the
  # chart's gitops.chartRepository so adoption keeps the operator's.
  [ "$(yq -r '.spec.sources[0] | .repoURL + " " + .helm.valuesObject.gitops.chartRepository' "$reg/components/infrared.yaml")" = "$chart_repo $chart_repo" ] \
    && ok "$variant: the infrared Application pulls the chart from $chart_repo and carries it" \
    || bad "$variant: the infrared Application's chart repository or gitops.chartRepository is not $chart_repo"
  # The install's settings that Argo CD's render of the chart has to keep once
  # it adopts the release, each carried only when it is set: exactly these
  # keys, with these values. The edge and its previews only in gateway mode.
  want=""
  if [ "$edge" = gateway ]; then
    want="installation: {edge: gateway"
    [ -n "$domain" ] && [ -n "$host" ] && want="$want, previews: {domain: \"$domain\", signInURL: \"https://$host\"}"
    want="$want}"$'\n'
  fi
  [ "$stores" = true ] && want="${want}stores: {enabled: true}"$'\n'
  # backup: the bucket with its endpoint, region and prefix as set, and the
  # backups' settings that are set.
  carried="$(jq -cn --arg b "$carried_backup" --arg e "$endpoint" --arg r "$region" --arg p "$prefix" --argjson s "$backup_app" '
    (if $b == "" then {} else {bucket: $b} + (if $e == "" then {} else {endpoint: $e} end)
      + (if $r == "" then {} else {region: $r} end) + (if $p == "" then {} else {prefix: $p} end) end) + $s')"
  [ "$carried" != "{}" ] && want="${want}backup: $carried"$'\n'
  [ "$carried_disabled" != "[]" ] && want="${want}components: {disabled: $carried_disabled}"$'\n'
  [ "$stores" = true ] && [ -n "$zot_addr" ] && [ "$test_actors" = true ] && want="${want}substrate: {testActors: true}"$'\n'
  [ "$code_index" = true ] && want="${want}codeIndex: {enabled: true, image: {tag: \"$pin_tag\", digest: \"$pin_digest\"}}"$'\n'"platformTokens: {existingSecret: infrared-platform-tokens}"$'\n'
  if [ "$forge" = gitea ]; then
    gitea_class=""
    [ "$cloud" = linode ] && gitea_class=", persistence: {storageClass: linode-block-storage-retain}"
    want="${want}gitea: {enabled: true$gitea_class}"$'\n'"giteaAdmin: {existingSecret: infrared-gitea-admin}"$'\n'
  fi
  [ -n "$token_gsa" ] && want="${want}registryToken: {gcpServiceAccount: \"$token_gsa\", registry: \"$token_host\"}"$'\n'
  if [ -n "$token_region" ]; then
    aws_token="region: \"$token_region\""
    [ -n "$token_role" ] && aws_token="$aws_token, roleArn: \"$token_role\""
    [ "$token_hostnet" = true ] && aws_token="$aws_token, hostNetwork: true"
    want="${want}registryToken: {aws: {$aws_token}, registry: \"$token_host\"}"$'\n'
  fi
  if [ -n "$zot_addr" ] || [ "$retention_app" != "{}" ]; then
    want="${want}registry: $(jq -cn --arg a "$zot_addr" --argjson r "$retention_app" '{} + (if $a != "" then {address: $a} else {} end) + (if $r != {} then {retention: $r} else {} end)')"$'\n'
  fi
  want="$(yq -o json -I0 'sort_keys(..)' <<<"${want:-"{}"}")"
  got="$(yq -o json -I0 '.spec.sources[0].helm.valuesObject
      | with_entries(select(.key | test("^(installation|stores|backup|components|gitea|giteaAdmin|registry|registryToken|copies|substrate|codeIndex|platformTokens)$"))) | sort_keys(..)' \
    "$reg/components/infrared.yaml")"
  [ "$got" = "$want" ] && ok "$variant: infrared Application carries the install's settings: $got" \
    || bad "$variant: infrared Application carries $got, want $want"

  # The infrared Application: the chart first, with the org's values file from
  # this repo ($values) under the template's own valuesObject.
  app="$reg/components/infrared.yaml"
  if [ "$(yq -r '.spec.sources | length' "$app")" = 2 ] && [ "$(yq -r '.spec.source' "$app")" = null ] \
    && [ "$(yq -r '.spec.sources[0].chart' "$app")" = infrared ] \
    && [ "$(yq -r '.spec.sources[0].helm.valueFiles | join(",")' "$app")" = "\$values/registry/clusters/$cluster/values/infrared.yaml" ] \
    && [ "$(yq -r '.spec.sources[0].helm.ignoreMissingValueFiles' "$app")" = true ] \
    && [ "$(yq -r '.spec.sources[1].ref' "$app")" = values ] \
    && [ "$(yq -r '.spec.sources[1].repoURL' "$app")" = "$(yq -r '.spec.source.repoURL' "$reg/registry.yaml")" ] \
    && [ "$(yq -r '.spec.sources[1].targetRevision' "$app")" = "$(yq -r '.spec.source.targetRevision' "$reg/registry.yaml")" ]; then
    ok "$variant: infrared Application reads the org's values/infrared.yaml"
  else
    bad "$variant: infrared Application lacks the chart source or the org's \$values file"
  fi
  # The operator keeps the higher chart pin across a template bump by reading
  # the first targetRevision that starts with a digit (keepHigherPin).
  pin="$(sed -n -E 's/^[[:space:]]*targetRevision:[[:space:]]*"?([0-9][^"[:space:]]*)"?[[:space:]]*$/\1/p' "$app" | head -n 1)"
  [ -n "$pin" ] && [ "$pin" = "$(yq -r '.spec.sources[0].targetRevision' "$app")" ] \
    && ok "$variant: the operator reads the chart pin ($pin)" || bad "$variant: the operator would read pin '$pin', not the chart's"
  # Hydration overlays the template and never deletes, so the org's values
  # file survives only while the template renders nothing beside it.
  [ ! -e "$reg/values" ] && ok "$variant: nothing rendered into the org's values/" || bad "$variant: the template renders into registry/clusters/$cluster/values/"
  [ "$(yq -N -r 'select(.metadata.name == "infrared") | .spec.sourceRepos[]' "$out/components/appprojects/appprojects.yaml" \
      | grep -cxF "$(yq -r '.spec.sources[1].repoURL' "$app")")" = 1 ] \
    && ok "$variant: AppProject infrared allows the \$values repo" || bad "$variant: AppProject infrared does not allow the \$values repo"

  # Kustomize builds (a component that renders to comments only is skipped).
  mkdir -p "$work/$variant-built"
  for k in "$out"/components/*/kustomization.yaml; do
    d="$(dirname "$k")"; name="$(basename "$d")"
    holds_objects "$k" || continue
    if kubectl kustomize "$d" > "$work/$variant-built/$name.yaml"; then :; else bad "$variant: kustomize build components/$name"; fi
  done

  # Order (the edge race of a first install). On a fresh cluster
  # every Application syncs at once, so a component that needs another one's
  # webhook or store waits for it in a PreSync hook, and an object such a
  # webhook admits has a sync wave of its own: a refused apply then fails the
  # sync, which Argo CD retries, instead of leaving it waiting for ever on the
  # health of what depended on that object.
  for b in "$work/$variant-built"/*.yaml; do
    name="$(basename "$b" .yaml)"
    shared="$(yq -N -r 'select(.metadata.annotations["argocd.argoproj.io/hook"] == null)
        | (.metadata.annotations["argocd.argoproj.io/sync-wave"] // "0") + " " + (.apiVersion | sub("/.*", "")) + "/" + .kind' "$b" \
      | sort -u | awk '
        $2 ~ /^(external-secrets\.io|cert-manager\.io|postgresql\.cnpg\.io)\// { admitted[$1] = admitted[$1] " " $2 }
        { kinds[$1]++ }
        END { for (w in admitted) if (kinds[w] > 1) print "wave " w ":" admitted[w] }')"
    [ -z "$shared" ] || bad "$variant: components/$name: an object a webhook admits shares its wave with other kinds ($shared)"
    waits="$(sel "$b" 'select(.kind == "Job" and .metadata.annotations["argocd.argoproj.io/hook"] == "PreSync") | .spec.template.spec.containers[].env[]? | select(.name | test("^WAIT_")) | .value' | tr '\n' ' ')"
    for store in $(sel "$b" 'select(.kind == "ExternalSecret") | .spec.secretStoreRef | select(.kind == "ClusterSecretStore") | .name' | sort -u); do
      # A store the component makes itself is applied by the same sync, which a
      # PreSync wait would never see: its ExternalSecrets come in a later wave.
      made="$(sel "$b" "select(.kind == \"ClusterSecretStore\" and .metadata.name == \"$store\") | .metadata.annotations[\"argocd.argoproj.io/sync-wave\"] // \"0\"")"
      if [ -n "$made" ]; then
        early="$(sel "$b" "select(.kind == \"ExternalSecret\" and .spec.secretStoreRef.name == \"$store\") | .metadata.annotations[\"argocd.argoproj.io/sync-wave\"] // \"0\"" \
          | awk -v w="$made" '$1 + 0 <= w + 0')"
        [ -z "$early" ] || bad "$variant: components/$name copies through $store, which it makes, in a wave not after the store's"
      else
        grep -qw -- "$store" <<<"$waits" || bad "$variant: components/$name copies through $store but does not wait for it"
      fi
    done
    if [ -n "$(sel "$b" 'select(.apiVersion | test("^cert-manager\\.io/")) | .kind')" ]; then
      grep -qw -- cert-manager/cert-manager-webhook <<<"$waits" || bad "$variant: components/$name asks cert-manager without waiting for its webhook"
    fi
    if [ -n "$(sel "$b" 'select(.kind == "ClusterSecretStore") | .kind')" ]; then
      grep -qw -- external-secrets/external-secrets-webhook <<<"$waits" || bad "$variant: components/$name makes a store without waiting for External Secrets' webhook"
    fi
    if [ -n "$(sel "$b" 'select(.apiVersion | test("^postgresql\\.cnpg\\.io/")) | .kind')" ]; then
      grep -qw -- cnpg-system/cnpg-webhook-service <<<"$waits" || bad "$variant: components/$name applies CloudNativePG objects without waiting for its webhook"
    fi
  done

  # builds: all of it with a build registry, none of it without.
  if [ -n "$registry" ]; then
    app="$reg/components/builds.yaml"
    [ "$(yq -N -r '.metadata.name' "$app")" = builds ] && [ "$(yq -N -r '.metadata.annotations["argocd.argoproj.io/sync-wave"]' "$app")" = 26 ] \
      && [ "$(yq -N -r '.spec.source.path' "$app")" = components/builds ] \
      && ok "$variant: builds Application (wave 26)" || bad "$variant: builds Application missing or wrong"
    b="$work/$variant-built/builds.yaml"
    if [ -s "$b" ]; then
      has() { [ -n "$(yq -N -r "select(.kind == \"$1\" and .metadata.name == \"$2\") | .metadata.name" "$b")" ]; }
      # ECR's login job only for ECR; the GitHub App's token job only for
      # GitHub. On Gitea kpack clones with builds/gitea-git, which the operator
      # writes, so nothing of GitHub's is rendered.
      wants="Namespace/builds ClusterStore/paketo ClusterStack/noble ClusterBuilder/infrared-builder"
      if [ -n "$zot_addr" ]; then
        # The registry inside the cluster: the builder is pushed as platform,
        # with kpack/infrared-builder, once Zot and the credential are there.
        wants="$wants ServiceAccount/infrared-builder Job/registry-wait"
      else
        wants="$wants ServiceAccount/builder"
        case "$registry" in *.dkr.ecr.*) wants="$wants Namespace/build-credentials CronJob/ecr-login Job/ecr-login-bootstrap" ;; esac
      fi
      source_secret=github-git
      if [ "$forge" = gitea ]; then
        source_secret=gitea-git
        [ -z "$(sel "$b" 'select(.metadata.name | test("github")) | .kind + "/" + .metadata.name')" ] \
          || bad "$variant: GitHub's token job or its scripts rendered for Gitea"
      else
        wants="$wants CronJob/github-token Job/github-token-bootstrap Role/builds-github-token"
        [ "$(yq -N -r 'select(.kind == "Role" and .metadata.name == "builds-github-token") | .metadata.namespace' "$b")" = ir-org-demo-org ] \
          || bad "$variant: github App Role is not in ir-org-demo-org"
      fi
      for want in $wants; do
        has "${want%%/*}" "${want#*/}" || bad "$variant: builds lacks $want"
      done
      if [ -n "$zot_addr" ]; then
        sa='select(.kind == "ServiceAccount" and .metadata.name == "infrared-builder")'
        rw='select(.kind == "Job" and .metadata.name == "registry-wait")'
        rw_env() { sel "$b" "$rw | .spec.template.spec.containers[0].env[] | select(.name == \"$1\") | .value"; }
        want_wait=""
        [ "$stores" = true ] && want_wait=registry/zot
        [ "$(sel "$b" "$sa | .metadata.namespace + \" \" + (.secrets | map(.name) | join(\",\")) + \" \" + (.imagePullSecrets | map(.name) | join(\",\"))")" \
            = "kpack registry-push registry-push" ] \
          && [ "$(sel "$b" 'select(.kind == "ClusterBuilder") | .spec.tag + " " + .spec.serviceAccountRef.namespace + "/" + .spec.serviceAccountRef.name')" \
            = "$zot_addr/platform/kpack-builder kpack/infrared-builder" ] \
          && [ -z "$(sel "$b" 'select((.kind == "ServiceAccount" and .metadata.name == "builder") or (.metadata.name | test("ecr-login|build-credentials"))) | .kind')" ] \
          && [ "$(sel "$b" "$rw | .metadata.annotations[\"argocd.argoproj.io/hook\"] + \" \" + .metadata.annotations[\"argocd.argoproj.io/sync-wave\"]")" = "Sync -1" ] \
          && [ "$(rw_env WAIT_SECRETS)" = kpack/registry-push ] && [ "$(rw_env WAIT_SERVICES)" = "$want_wait" ] \
          && [ "$(line "$b" 'select(.kind == "Role" and .metadata.name == "builds-registry-wait") | .metadata.namespace + " " + (.rules[0].resourceNames | join(","))')" = "kpack registry-push" ] \
          && ok "$variant: the builder is pushed to $zot_addr/platform/kpack-builder as platform (kpack/infrared-builder), after Zot${want_wait:+ answers} and kpack/registry-push" \
          || bad "$variant: builds to the registry inside the cluster are wrong"
      else
        [ "$(line "$b" 'select(.kind == "ServiceAccount" and .metadata.name == "builder") | .secrets[].name')" = "registry-push $source_secret" ] \
          || bad "$variant: ServiceAccount builder does not list registry-push and $source_secret"
        [ "$(yq -N -r 'select(.kind == "ClusterBuilder") | .spec.tag' "$b")" = "$registry/kpack-builder" ] \
          || bad "$variant: ClusterBuilder tag is not $registry/kpack-builder"
      fi
      [ "$(yq -N -r 'select(.kind == "Namespace" and .metadata.name == "builds") | .metadata.labels["pod-security.kubernetes.io/enforce"]' "$b")" = restricted ] \
        || bad "$variant: namespace builds is not restricted"
      if grep -nE '\| *kubectl apply' "$b" | grep -v -- '--server-side' | grep -q .; then bad "$variant: a client-side kubectl apply in builds"; fi
      ok "$variant: builds component complete, kpack clones with $source_secret"
    else
      bad "$variant: components/builds built nothing"
    fi
  else
    left="$(for f in "$reg/components/builds.yaml" $(find "$out/components/builds" -name '*.yaml'); do holds_objects "$f" && echo "$f"; done || true)"
    [ -z "$left" ] && ok "$variant: no build registry, no builds objects" || bad "$variant: builds objects rendered without a build registry: $left"
    [ ! -e "$work/$variant-built/builds.yaml" ] || bad "$variant: components/builds was built without a build registry"
  fi

  # The edge: all of it with Edge gateway, none of it without.
  edge_files="$(printf '%s\n' "$reg/components/envoy-gateway.yaml" "$reg/components/origin-ca-issuer.yaml" \
    "$reg/components/platform-tokens.yaml" "$reg/components/external-dns.yaml" "$reg/components/edge.yaml"
    find "$out/components/edge" "$out/components/external-dns" "$out/components/platform-tokens" -name '*.yaml')"
  if [ "$edge" = gateway ]; then
    for a in envoy-gateway:11 origin-ca-issuer:11 platform-tokens:11 external-dns:12 edge:13; do
      name="${a%%:*}" f="$reg/components/${a%%:*}.yaml"
      [ "$(sel "$f" '.metadata.name')" = "$name" ] && [ "$(sel "$f" '.metadata.annotations["argocd.argoproj.io/sync-wave"]')" = "${a#*:}" ] \
        && [ "$(sel "$f" '.spec.project')" = platform ] \
        && ok "$variant: $name Application (wave ${a#*:})" || bad "$variant: $name Application missing or wrong"
    done
    f="$reg/components/envoy-gateway.yaml"
    # The Gateway API CRDs: k3s on Linode brings them, so the chart leaves them out there; elsewhere (GKE) the chart installs them.
    if [ "$cloud" = linode ]; then gw_crds=false; else gw_crds=true; fi
    [ "$(sel "$f" '.spec.sources[] | select(.chart == "gateway-crds-helm") | .helm.valuesObject.crds.gatewayAPI.enabled')" = "$gw_crds" ] \
      && [ "$(sel "$f" '.spec.sources[] | select(.chart == "gateway-helm") | .helm.valuesObject.crds.enabled')" = false ] \
      && ok "$variant: Envoy Gateway's CRD chart installs the Gateway API CRDs: $gw_crds (cloud '$cloud'); gateway-helm's subchart off" \
      || bad "$variant: Envoy Gateway's Gateway API CRDs are not $gw_crds for cloud '$cloud', or gateway-helm's CRD subchart is on"
    e="$work/$variant-built/edge.yaml" t="$work/$variant-built/platform-tokens.yaml" x="$work/$variant-built/external-dns.yaml"
    dns="$reg/components/external-dns.yaml"
    # Envoy on each node's own ports, behind a NodePort Service.
    [ "$(sel "$e" 'select(.kind == "EnvoyProxy") | .spec.provider.kubernetes.envoyService.type')" = NodePort ] \
      && [ "$(sel "$e" 'select(.kind == "EnvoyProxy") | .spec.provider.kubernetes.envoyService.externalTrafficPolicy')" = Local ] \
      && [ "$(line "$e" 'select(.kind == "EnvoyProxy") | .spec.provider.kubernetes.envoyDaemonSet.patch.value.spec.template.spec.containers[] | select(.name == "envoy") | .ports[] | (.hostPort | tostring) + ":" + (.containerPort | tostring)')" = "80:10080 443:10443" ] \
      && [ "$(sel "$e" 'select(.kind == "GatewayClass") | .spec.parametersRef.name')" = "$(sel "$e" 'select(.kind == "EnvoyProxy") | .metadata.name')" ] \
      && ok "$variant: Envoy answers on each node's ports 80 and 443, no load balancer" || bad "$variant: the Envoy fleet is not on host ports behind a NodePort Service"
    # One Gateway: the platform domain's wildcard for zones, Infrared's own name apart.
    [ "$(line "$e" 'select(.kind == "Gateway") | .spec.listeners[] | .name + "=" + .hostname')" \
        = "http=*.$gw_domain https=*.$gw_domain infrared-http=$gw_host infrared-https=$gw_host" ] \
      && [ "$(sel "$e" 'select(.kind == "Gateway") | .spec.listeners[] | select(.name == "https") | .allowedRoutes.namespaces.selector.matchExpressions[0].key')" = infrared.darkshift.io/zone ] \
      && [ "$(sel "$e" 'select(.kind == "Gateway") | .spec.listeners[] | select(.name == "infrared-https") | .allowedRoutes.namespaces.selector.matchLabels["kubernetes.io/metadata.name"]')" = infrared ] \
      && ok "$variant: Gateway edge serves *.$gw_domain and $gw_host" || bad "$variant: Gateway edge listeners are wrong"
    [ "$(line "$e" 'select(.kind == "Certificate") | .spec.dnsNames[]')" = "*.$gw_domain" ] \
      && [ "$(sel "$e" 'select(.kind == "Certificate") | .spec.issuerRef.kind + "/" + .spec.issuerRef.name')" = "OriginIssuer/$(sel "$e" 'select(.kind == "OriginIssuer") | .metadata.name')" ] \
      && [ "$(line "$e" 'select(.kind == "Gateway") | .spec.listeners[] | .tls.certificateRefs[]?.name' | tr ' ' '\n' | sort -u)" = "$(sel "$e" 'select(.kind == "Certificate") | .spec.secretName')" ] \
      && ok "$variant: one origin certificate for *.$gw_domain on every HTTPS listener" || bad "$variant: the edge certificate is wrong"
    # The token's copy, the issuer and the certificate, each in a wave of its
    # own, before the Envoy fleet and the Gateway that need them.
    order="$(for k in ExternalSecret OriginIssuer Certificate EnvoyProxy GatewayClass Gateway; do
        sel "$e" "select(.kind == \"$k\") | .metadata.annotations[\"argocd.argoproj.io/sync-wave\"] // \"0\""; done | tr '\n' ' ')"
    awk '{ for (i = 2; i <= NF; i++) if ($i + 0 <= $(i - 1) + 0) exit 1; exit NF != 6 }' <<<"$order" \
      && ok "$variant: the edge applies its token, issuer and certificate before the Gateway (waves $order)" \
      || bad "$variant: the edge's waves are not token < issuer < certificate < EnvoyProxy < GatewayClass < Gateway: $order"
    [ "$(line "$e" 'select(.metadata.name == "https-redirect") | .spec.parentRefs[].sectionName')" = "http infrared-http" ] \
      && [ "$(sel "$e" 'select(.metadata.name == "https-redirect") | .spec.rules[0].filters[0].requestRedirect.scheme')" = https ] \
      && [ "$(line "$e" 'select(.kind == "HTTPRoute" and .metadata.name == "infrared") | .metadata.namespace + " " + .spec.hostnames[0] + " " + .spec.rules[0].backendRefs[0].name + ":" + (.spec.rules[0].backendRefs[0].port | tostring)')" = "infrared $gw_host infrared:80" ] \
      && ok "$variant: the redirect from port 80, and Infrared's route" || bad "$variant: the edge's routes are wrong"
    # external-dns publishes the edge's labelled route only, as this cluster's owner.
    label="$(sel "$dns" '.spec.sources[0].helm.valuesObject.labelFilter')"
    [ "$(sel "$e" "select(.metadata.name == \"https-redirect\") | .metadata.labels[\"${label%%=*}\"]")" = "${label#*=}" ] \
      && [ "$(sel "$dns" '.spec.sources[0].helm.valuesObject.txtOwnerId')" = "$cluster" ] \
      && [ "$(sel "$dns" '.spec.sources[0].helm.valuesObject.policy')" = sync ] \
      && [ "$(sel "$dns" '.spec.sources[0].helm.valuesObject.gatewayNamespace')" = "$(sel "$e" 'select(.kind == "Gateway") | .metadata.namespace')" ] \
      && [ "$(line "$dns" '.spec.sources[0].helm.valuesObject.extraArgs[]')" = "--gateway-name=$(sel "$e" 'select(.kind == "Gateway") | .metadata.name') --cloudflare-proxied --txt-wildcard-replacement=wildcard" ] \
      && [ "$(sel "$dns" '.spec.sources[0].helm.valuesObject.domainFilters // [] | length')" = 0 ] \
      && ok "$variant: external-dns publishes the edge's names, proxied, as owner $cluster" || bad "$variant: external-dns is not wired to the edge"
    # The platform's tokens: one store, one Secret, two namespaces; with
    # Substrate and a pull secret, that Secret too, for Substrate's namespaces.
    want_ns="external-dns envoy-gateway-system${backup:+ stores}"
    want_names="infrared-platform-tokens:get"
    if [ "$substrate" = true ] && [ -n "$pull_secret" ]; then
      want_ns="$want_ns podcertificate-controller-system ate-system ate-workers"
      [ "$test_actors" = true ] && want_ns="$want_ns registry"
      want_names="$want_names $pull_secret:get"
    fi
    # The code index's record and credential, and its pull secret, for the
    # namespace code-index.
    [ "$code_index" = true ] && want_ns="$want_ns code-index"
    if [ "$ci_pull" = true ]; then
      grep -qw -- "$pull_secret:get" <<<"$want_names" || want_names="$want_names $pull_secret:get"
    fi
    [ "$(line "$t" 'select(.kind == "ClusterSecretStore") | .spec.conditions[].namespaces[]')" = "$want_ns" ] \
      && [ "$(sel "$t" 'select(.kind == "ClusterSecretStore") | .spec.provider.kubernetes.remoteNamespace')" = infrared ] \
      && [ "$(line "$t" 'select(.kind == "Role") | .rules[] | .resourceNames[] + ":" + (.verbs | join(","))')" = "$want_names" ] \
      && ok "$variant: ClusterSecretStore infrared-platform reads only $want_names, for $want_ns" || bad "$variant: ClusterSecretStore infrared-platform is wrong"
    for es in "$x:external-dns" "$e:envoy-gateway-system"; do
      f="${es%%:*}" ns="${es#*:}"
      [ "$(line "$f" "select(.kind == \"ExternalSecret\" and .metadata.namespace == \"$ns\") | .spec.secretStoreRef.kind + \"/\" + .spec.secretStoreRef.name + \" \" + .spec.data[0].remoteRef.key + \"/\" + .spec.data[0].remoteRef.property")" \
          = "ClusterSecretStore/infrared-platform infrared-platform-tokens/cloudflare-api-token" ] \
        && ok "$variant: $ns gets the Cloudflare token from infrared-platform" || bad "$variant: no Cloudflare token for $ns"
    done
    [ "$(sel "$dns" '.spec.sources[0].helm.valuesObject.env[] | select(.name == "CF_API_TOKEN") | .valueFrom.secretKeyRef.name + "/" + .valueFrom.secretKeyRef.key')" \
        = "$(sel "$x" 'select(.kind == "ExternalSecret") | .spec.target.name + "/" + .spec.data[0].secretKey')" ] \
      && [ "$(sel "$e" 'select(.kind == "OriginIssuer") | .spec.auth.tokenRef.name + "/" + .spec.auth.tokenRef.key')" \
        = "$(sel "$e" 'select(.kind == "ExternalSecret") | .spec.target.name + "/" + .spec.data[0].secretKey')" ] \
      && ok "$variant: external-dns and the origin issuer read the Secrets the ExternalSecrets write" || bad "$variant: a token is read from a Secret nothing writes"
    # The infrared Application keeps the operator's images and a SHA as a string.
    app="$reg/components/infrared.yaml"
    want="$(yq -p json -r '.ImageRegistry' "$data_file")"
    for c in operator api ui mcp runner; do want="$want $(yq -p json -r ".Images.$c.tag + \"@\" + .Images.$c.digest" "$data_file")"; done
    got="$(sel "$app" '.spec.sources[0].helm.valuesObject.image.registry')"
    for c in operator api ui mcp runner; do got="$got $(sel "$app" ".spec.sources[0].helm.valuesObject.$c.image.tag + \"@\" + .spec.sources[0].helm.valuesObject.$c.image.digest")"; done
    [ "$got" = "$want" ] && ok "$variant: infrared Application pins every image of ghcr.io/demo-org by digest" || bad "$variant: infrared Application images: $got, want $want"
    [ "$(sel "$app" '.spec.sources[0].helm.valuesObject.gitops.templateVersion | tag')" = '!!str' ] \
      && [ "$(sel "$app" '.spec.sources[0].helm.valuesObject.gitops.templateVersion')" = "$(yq -p json -r '.templateVersion' "$data_file")" ] \
      && ok "$variant: a commit SHA renders as a string" || bad "$variant: the template version SHA is not a YAML string"
  else
    if [ -n "$backup" ] || { [ "$substrate" = true ] && [ -n "$pull_secret" ]; } || [ "$code_index" = true ]; then
      # The platform's tokens, for the backups alone, for Substrate's pull
      # secret, or for the code index's record, credential and pull secret.
      edge_files="$(grep -v platform-tokens <<<"$edge_files")"
      t="$work/$variant-built/platform-tokens.yaml"
      want_ns="${backup:+stores}"
      want_names="infrared-platform-tokens:get"
      if [ "$substrate" = true ] && [ -n "$pull_secret" ]; then
        want_ns="${want_ns:+$want_ns }podcertificate-controller-system ate-system ate-workers"
        [ "$test_actors" = true ] && want_ns="$want_ns registry"
        want_names="$want_names $pull_secret:get"
      fi
      [ "$code_index" = true ] && want_ns="${want_ns:+$want_ns }code-index"
      if [ "$ci_pull" = true ]; then
        grep -qw -- "$pull_secret:get" <<<"$want_names" || want_names="$want_names $pull_secret:get"
      fi
      [ "$(sel "$reg/components/platform-tokens.yaml" '.metadata.name')" = platform-tokens ] \
        && [ "$(line "$t" 'select(.kind == "ClusterSecretStore") | .spec.conditions[].namespaces[]')" = "$want_ns" ] \
        && [ "$(line "$t" 'select(.kind == "Role") | .rules[] | .resourceNames[] + ":" + (.verbs | join(","))')" = "$want_names" ] \
        && ok "$variant: ClusterSecretStore infrared-platform reads $want_names, for $want_ns alone" \
        || bad "$variant: the platform's tokens are not there for the backups, a pull secret or the code index"
    fi
    left="$(for f in $edge_files; do holds_objects "$f" && echo "$f"; done || true)"
    [ -z "$left" ] && ok "$variant: the edge is not a Gateway, no edge objects" || bad "$variant: edge objects rendered without Edge gateway: $left"
    if [ -z "$image_registry" ]; then
      [ -z "$(sel "$reg/components/infrared.yaml" '.spec.sources[0].helm.valuesObject | (.image, .operator, .api, .ui, .runner, .mcp.image) | select(. != null) | key')" ] \
        || bad "$variant: image values rendered without the operator's image registry"
    fi
  fi

  # The stores: all of them with Stores, none of them without.
  store_files="$(printf '%s\n' "$reg/components/cloudnative-pg.yaml" "$reg/components/postgres.yaml" "$reg/components/seaweedfs.yaml"
    find "$out/components/postgres" "$out/components/seaweedfs" -name '*.yaml')"
  if [ "$stores" = true ]; then
    for a in cloudnative-pg:16:cnpg-system postgres:17:stores seaweedfs:18:stores; do
      IFS=: read -r name wave ns <<<"$a"
      f="$reg/components/$name.yaml"
      [ "$(sel "$f" '.metadata.name')" = "$name" ] && [ "$(sel "$f" '.metadata.annotations["argocd.argoproj.io/sync-wave"]')" = "$wave" ] \
        && [ "$(sel "$f" '.spec.project')" = platform ] && [ "$(sel "$f" '.spec.destination.namespace')" = "$ns" ] \
        && [ -z "$(sel "$f" '.metadata.finalizers[]?')" ] \
        && ok "$variant: $name Application (wave $wave, no finalizer: removing it leaves the data)" || bad "$variant: $name Application missing or wrong"
    done
    [ "$(sel "$reg/components/cloudnative-pg.yaml" '.spec.sources[0].chart + " " + .spec.sources[0].targetRevision')" = "cloudnative-pg 0.29.1" ] \
      && sel "$reg/components/cloudnative-pg.yaml" '.spec.sources[0].helm.valuesObject.image.tag' | grep -qE '^1\.30\.1@sha256:[0-9a-f]{64}$' \
      && ok "$variant: CloudNativePG 1.30.1 (chart 0.29.1), by digest" || bad "$variant: CloudNativePG is not chart 0.29.1 with 1.30.1 by digest"
    p="$work/$variant-built/postgres.yaml"
    c='select(.kind == "Cluster" and .metadata.name == "postgres")'
    class="$(sel "$p" "$c | .spec.storage.storageClass // \"\"")"
    want_class=""
    [ "$cloud" = linode ] && want_class=linode-block-storage-retain
    [ "$(sel "$p" "$c | .spec.instances")" = 1 ] && [ "$(sel "$p" "$c | .spec.storage.size")" = 20Gi ] \
      && [ -z "$(sel "$p" "$c | .spec.walStorage // \"\"")" ] && [ "$class" = "$want_class" ] \
      && sel "$p" "$c | .spec.imageName" | grep -qE '@sha256:[0-9a-f]{64}$' \
      && ok "$variant: one Postgres instance on one 20Gi volume of class '${class:-the default}', image by digest" \
      || bad "$variant: the Postgres Cluster is not one instance on one 20Gi volume of class '${want_class:-the default}' (got '$class')"
    # A role and a database for each consumer, and only these consumers.
    [ "$(line "$p" 'select(.kind == "DatabaseRole") | .spec.name + ":" + (.spec.login | tostring) + ":" + .spec.passwordSecret.name')" \
        = "seaweedfs:true:postgres-seaweedfs substrate:true:postgres-substrate" ] \
      && [ "$(line "$p" 'select(.kind == "Database") | .spec.name + ":" + .spec.owner')" = "seaweedfs:seaweedfs substrate:substrate" ] \
      && [ "$(line "$p" 'select(.kind == "Role") | .rules[0].resourceNames[]')" = "postgres-seaweedfs postgres-substrate" ] \
      && ok "$variant: a role and a database each for seaweedfs and substrate, their Secrets made once" \
      || bad "$variant: the consumers' roles, databases or Secrets are wrong"
    # SeaweedFS across the nodes, every file on two of them, on the nodes' own
    # disks, its filer metadata in the platform's Postgres.
    f="$reg/components/seaweedfs.yaml"
    v='.spec.sources[] | select(.chart == "seaweedfs") | .helm.valuesObject'
    sw="$work/$variant-built/seaweedfs.yaml"
    [ "$(sel "$f" '.spec.sources[] | select(.chart == "seaweedfs") | .targetRevision')" = 4.48.0 ] \
      && sel "$f" "$v | .image.tag" | grep -qE '^4\.48@sha256:[0-9a-f]{64}$' \
      && [ "$(sel "$f" "$v | .global.seaweedfs.enableReplication")/$(sel "$f" "$v | .global.seaweedfs.replicationPlacement")" = true/001 ] \
      && [ "$(sel "$f" "$v | (.master.replicas, .volume.replicas, .filer.replicas, .s3.replicas) | tostring" | tr '\n' ' ')" = "3 3 2 2 " ] \
      && [ "$(sel "$f" "$v | (.master.data.type, .volume.dataDirs[].type, .filer.data.type) " | tr '\n' ' ')" = "hostPath hostPath emptyDir " ] \
      && grep -q 'volume.fix.replication -apply' <<<"$(sel "$f" "$v | .master.config")" \
      && [ "$(sel "$f" "$v | .s3.affinity" | yq -r '.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[0].topologyKey')" = kubernetes.io/hostname ] \
      && ok "$variant: SeaweedFS 4.48: 3 masters, 3 volume servers on the nodes' disks, 2 filers, 2 S3 gateways, every file on two servers" \
      || bad "$variant: SeaweedFS is not spread over the nodes with every file on two of them"
    [ "$(sel "$f" "$v | .filer.extraEnvironmentVars | .WEED_LEVELDB2_ENABLED + \" \" + .WEED_POSTGRES2_ENABLED + \" \" + .WEED_POSTGRES2_HOSTNAME + \" \" + .WEED_POSTGRES2_DATABASE")" \
        = "false true postgres-rw.stores.svc seaweedfs" ] \
      && [ "$(sel "$f" "$v | .filer.secretExtraEnvironmentVars[].secretKeyRef.name" | sort -u)" = postgres-seaweedfs ] \
      && [ -z "$(sel "$f" "$v | .filer.extraEnvironmentVars.WEED_POSTGRES2_CONNECTION_MAX_OPEN // \"\"")" ] \
      && ok "$variant: the filers keep their metadata in the platform's Postgres, as seaweedfs" \
      || bad "$variant: the filers' store is not the platform's Postgres"
    # The buckets, and an S3 identity for each that reaches it alone, with keys
    # the PreSync hook makes and the gateway reads from the environment.
    ids="$(sel "$sw" 'select(.kind == "Secret" and .metadata.name == "seaweedfs-s3-identities") | .stringData.seaweedfs_s3_config')"
    want_ids="ate-snapshots:ate-snapshots registry:registry ${backup:+backup:ate-snapshots,registry }"
    want_secrets="seaweedfs-s3-ate-snapshots ${backup:+seaweedfs-s3-backup }seaweedfs-s3-registry "
    # The same with backups on: they go straight outside, so no bucket or
    # identity of their own.
    want_buckets="ate-snapshots registry "
    if [ "$restoring" = true ]; then
      # A restore writes every bucket back as the identity restore.
      want_ids="${want_ids}restore:ate-snapshots,registry "
      want_secrets="$(printf '%s\n' $want_secrets seaweedfs-s3-restore | sort | tr '\n' ' ')"
    fi
    [ "$(sel "$f" "$v | .s3.createBuckets[].name" | tr '\n' ' ')" = "$want_buckets" ] \
      && [ "$(yq -p json -r '.identities[] | .name + ":" + (.actions | map(sub(".*:", "")) | unique | join(","))' <<<"$ids" | tr '\n' ' ')" = "$want_ids" ] \
      && [ -z "$(yq -p json -r '.identities[].actions[] | select(test(":") | not)' <<<"$ids")" ] \
      && [ "$(yq -p json -r '.identities[].credentials[] | .accessKey + " " + .secretKey' <<<"$ids" | grep -cvE '^\$\{[A-Z0-9_]+\} \$\{[A-Z0-9_]+\}$' || true)" = 0 ] \
      && [ "$(yq -p json -r '.identities[].credentials[] | .accessKey + " " + .secretKey' <<<"$ids" | tr -d '${}' | tr ' ' '\n' | sort | tr '\n' ' ')" \
          = "$(sel "$f" "$v | .s3.extraEnvironmentVars | keys | .[]" | sort | tr '\n' ' ')" ] \
      && [ "$(sel "$f" "$v | .s3.extraEnvironmentVars[].secretKeyRef.name" | sort -u | tr '\n' ' ')" = "$want_secrets" ] \
      && [ "$(sel "$sw" 'select(.kind == "Role" and .metadata.name == "seaweedfs-prepare") | .rules[0].resourceNames[]' | sort | tr '\n' ' ')" = "$want_secrets" ] \
      && ok "$variant: buckets ${want_buckets% }, each with an identity that reaches it alone, no key in the repo" \
      || bad "$variant: SeaweedFS's buckets or S3 identities are wrong"
    cn="$reg/components/cloudnative-pg.yaml"
    if [ -n "$backup" ] && [ "$archive_on" != true ]; then
      # No WAL archive (.PostgresArchive.Enabled false, the default): nothing of
      # the Barman Cloud plugin, its certificates, the ObjectStore, the
      # ScheduledBackup or Postgres's copy of the keys, and the Cluster has no
      # plugin; the dump in each backup is what a restore reads.
      [ -z "$(sel "$cn" '.spec.sources[] | select(.chart == "plugin-barman-cloud") | .chart')" ] \
        && ! holds_objects "$out/components/cloudnative-pg/certificates.yaml" && ! holds_objects "$out/components/cloudnative-pg/wait.yaml" \
        && [ -z "$(sel "$p" 'select(.kind == "ObjectStore" or .kind == "ScheduledBackup" or .kind == "ExternalSecret") | .kind')" ] \
        && [ -z "$(sel "$p" "$c | .spec.plugins // \"\"")" ] \
        && ! grep -q 'barman' "$out/components/postgres/prepare.yaml" \
        && ok "$variant: no WAL archive by default: no Barman plugin, certificates, ObjectStore, ScheduledBackup or key copy for Postgres" \
        || bad "$variant: the WAL archive renders without .PostgresArchive.Enabled"
    fi
    if [ -n "$backup" ]; then
      if [ "$archive_on" = true ]; then
      # Postgres: every WAL segment and a daily base backup to the outside
      # bucket, kept seven days, through CloudNativePG's Barman Cloud plugin.
      [ "$(sel "$cn" '.spec.sources[] | select(.chart == "plugin-barman-cloud") | .targetRevision')" = 0.8.1 ] \
        && [ "$(sel "$cn" '.spec.sources[] | select(.chart == "plugin-barman-cloud") | .helm.valuesObject | (.image.tag, .sidecarImage.tag)' | grep -cE '^v0\.15\.1@sha256:[0-9a-f]{64}$')" = 2 ] \
        && [ "$(sel "$cn" '.spec.sources[] | select(.chart == "plugin-barman-cloud") | .helm.valuesObject.certificate | .createIssuer or .createServerCertificate or .createClientCertificate')" = false ] \
        && [ "$(line "$work/$variant-built/cloudnative-pg.yaml" 'select(.kind == "Certificate") | .spec.secretName' | tr ' ' '\n' | sort | tr '\n' ' ')" = "barman-cloud-client-tls barman-cloud-server-tls " ] \
        && ok "$variant: the Barman Cloud plugin 0.15.1 (chart 0.8.1) by digest, its certificates in waves of their own" \
        || bad "$variant: the Barman Cloud plugin or its certificates are wrong"
      os='select(.kind == "ObjectStore" and .metadata.name == "backup")'
      sb='select(.kind == "ScheduledBackup")'
      [ "$(sel "$p" "$os | .spec.configuration.destinationPath")" = "s3://$backup/${prefix:-$cluster}/postgres" ] \
        && [ "$(sel "$p" "$os | .spec.configuration.endpointURL // \"\"")" = "$endpoint" ] \
        && [ "$(sel "$p" "$os | .spec.retentionPolicy")" = "${pg_retention:-7d}" ] \
        && [ -z "$(sel "$p" "$os | .spec.configuration.serverName // \"\"")" ] \
        && [ "$(sel "$p" "$os | .spec.configuration.s3Credentials | (.accessKeyId.name, .secretAccessKey.name)" | sort -u)" = postgres-backup ] \
        && [ "$(sel "$p" "$c | .spec.plugins[] | .name + \" \" + (.isWALArchiver | tostring) + \" \" + .parameters.barmanObjectName")" = "barman-cloud.cloudnative-pg.io true backup" ] \
        && [ "$(sel "$p" "$c | .spec.plugins[0].parameters.serverName // \"\"")" = "$pg_server" ] \
        && [ "$(sel "$p" "$sb | .spec.schedule + \" \" + (.spec.immediate | tostring) + \" \" + .spec.method + \" \" + .spec.pluginConfiguration.name")" = "${pg_schedule:-0 0 3 * * *} true plugin barman-cloud.cloudnative-pg.io" ] \
        && ok "$variant: Postgres's WAL continuously and a base backup (${pg_schedule:-0 0 3 * * *}) to s3://$backup/${prefix:-$cluster}/postgres/${pg_server:-postgres}, kept ${pg_retention:-7d}" \
        || bad "$variant: Postgres's backups are wrong"
      fi
      # The buckets: copied every hour, what a copy replaces kept seven days.
      cj='select(.kind == "CronJob" and .metadata.name == "seaweedfs-backup")'
      env() { sel "$sw" "$cj | .spec.jobTemplate.spec.template.spec.containers[0].env[] | select(.name == \"$1\") | (.value // .valueFrom.secretKeyRef.name)"; }
      script="$(sel "$sw" "$cj | .spec.jobTemplate.spec.template.spec.containers[0].command[2]")"
      backup_reads="Read:ate-snapshots List:ate-snapshots Read:registry List:registry"
      mirror_days="${mirror_retention:-7d}"
      pod='.spec.jobTemplate.spec.template.spec'
      if [ "$provider" = gcs ]; then
        # Google Cloud Storage: rclone's own backend as the ServiceAccount
        # seaweedfs-backup, rendered beside the CronJob, which the cluster
        # grants the bucket's role through Workload Identity; no key, no
        # endpoint, no provider or region of the S3 backend.
        dst_ok() {
          [ "$(env RCLONE_CONFIG_DST_TYPE)" = "google cloud storage" ] \
            && [ "$(env RCLONE_CONFIG_DST_ENV_AUTH) $(env RCLONE_CONFIG_DST_BUCKET_POLICY_ONLY) $(env RCLONE_CONFIG_DST_NO_CHECK_BUCKET)" = "true true true" ] \
            && [ -z "$(env RCLONE_CONFIG_DST_ACCESS_KEY_ID)$(env RCLONE_CONFIG_DST_SECRET_ACCESS_KEY)$(env RCLONE_CONFIG_DST_ENDPOINT)$(env RCLONE_CONFIG_DST_PROVIDER)$(env RCLONE_CONFIG_DST_REGION)" ] \
            && [ "$(sel "$sw" "$cj | $pod.serviceAccountName")" = seaweedfs-backup ] \
            && [ "$(sel "$sw" 'select(.kind == "ServiceAccount" and .metadata.name == "seaweedfs-backup") | .metadata.namespace + " " + .metadata.annotations["argocd.argoproj.io/sync-wave"]')" = "stores -2" ]
        }
        dst_words="written as the ServiceAccount seaweedfs-backup to Google Cloud Storage, no key"
      else
        dst_ok() {
          [ "$(env RCLONE_CONFIG_DST_TYPE) $(env RCLONE_CONFIG_DST_ACCESS_KEY_ID)" = "s3 seaweedfs-backup" ] && [ "$(env RCLONE_CONFIG_DST_ENDPOINT)" = "$endpoint" ] \
            && [ -z "$(sel "$sw" "$cj | $pod.serviceAccountName // \"\"")" ] \
            && [ -z "$(sel "$sw" 'select(.kind == "ServiceAccount" and .metadata.name == "seaweedfs-backup") | .kind')" ]
        }
        dst_words="written with the platform's backup keys"
      fi
      [ "$(sel "$sw" "$cj | .spec.schedule")" = "${mirror_schedule:-17 * * * *}" ] \
        && sel "$sw" "$cj | $pod.containers[0].image" | grep -qE '^docker\.io/rclone/rclone:1\.75\.1@sha256:[0-9a-f]{64}$' \
        && [ "$(env DESTINATION)" = "dst:$backup/${prefix:-$cluster}/seaweedfs" ] && [ "$(env BUCKETS)" = "${want_buckets% }" ] \
        && [ "$(env RCLONE_CONFIG_SRC_ACCESS_KEY_ID)" = seaweedfs-s3-backup ] && dst_ok \
        && grep -q -- '--backup-dir "$DESTINATION/archive/$run/$bucket"' <<<"$script" && grep -q "${mirror_days%d} \\* 24 \\* 3600" <<<"$script" \
        && [ "$(yq -p json -r '.identities[] | select(.name == "backup") | .actions | join(" ")' <<<"$ids")" = "$backup_reads" ] \
        && ok "$variant: ${want_buckets% } copied (${mirror_schedule:-17 * * * *}) to $backup/${prefix:-$cluster}/seaweedfs, replaced objects kept $mirror_days, read as the identity backup, $dst_words" \
        || bad "$variant: the buckets' hourly copy is wrong"
      # The run's mark: with backups on it names the newest complete backup
      # under <prefix>/backups/ (BACKUPS), found before any bucket is copied
      # (a run against a fake bucket, below, proves which one); without,
      # today's mark.
      # shellcheck disable=SC2016 # the script's own words, matched as they render
      if [ "$copies_on" = true ]; then
        found="$(grep -n 'backup="$stamp"' <<<"$script" | cut -d: -f1)" copied="$(grep -n 'for bucket in $BUCKETS' <<<"$script" | cut -d: -f1)"
        [ "$(env BACKUPS)" = "dst:$backup/${prefix:-$cluster}/backups" ] \
          && grep -qF "printf '{\"run\": \"%s\", \"finished\": \"%s\", \"buckets\": \"%s\", \"backup\": \"%s\"}\\n'" <<<"$script" \
          && [ -n "$found" ] && [ -n "$copied" ] && [ "$found" -lt "$copied" ] \
          && ok "$variant: each run's mark names the newest complete backup in $backup/${prefix:-$cluster}/backups, looked for before any bucket is copied" \
          || bad "$variant: the mirror's mark does not name the newest backup before the run copies"
      else
        [ -z "$(env BACKUPS)" ] && ! grep -q '"backup"' <<<"$script" \
          && grep -qF "printf '{\"run\": \"%s\", \"finished\": \"%s\", \"buckets\": \"%s\"}\\n'" <<<"$script" \
          && ok "$variant: no recipient, no backups: the mark is today's" \
          || bad "$variant: the mirror's mark names a backup without recipients"
      fi
      # During a restore, and only then, a run copies nothing until the
      # restore marks buckets for its point: the new, empty buckets would
      # otherwise empty the copy outside, which the restore reads.
      if [ "$restoring" = true ]; then
        grep -qF "if [ \"\$(cat /restore-stores/point 2>/dev/null)\" != \"$restoring_point\" ] || [ ! -s /restore-stores/buckets ]; then" <<<"$script" \
          && [ "$(grep -c 'exit 1' <<<"$script")" = 1 ] \
          && [ "$(sel "$sw" "$cj | .spec.jobTemplate.spec.template.spec.volumes[] | select(.name == \"restore-stores\") | .configMap.name + \" \" + (.configMap.optional | tostring)")" = "restore-stores true" ] \
          && [ "$(sel "$sw" "$cj | .spec.jobTemplate.spec.template.spec.containers[0].volumeMounts[] | select(.name == \"restore-stores\") | .mountPath + \" \" + (.readOnly | tostring)")" = "/restore-stores true" ] \
          && ok "$variant: during the restore from $restoring_point the mirror copies nothing until the buckets are back" \
          || bad "$variant: the mirror does not wait for the restore's buckets"
      else
        ! grep -q restore-stores <<<"$(sel "$sw" "$cj")" \
          && ok "$variant: no restore, so the mirror waits for nothing" || bad "$variant: the mirror reads the restore's markers without a restore"
      fi
      # The mirror, and with the archive Postgres, copy the platform's backup
      # keys, and nothing else, from the store.
      pg_keys=""
      [ "$archive_on" != true ] || pg_keys="backup-access-key-id backup-secret-access-key "
      if [ "$provider" = gcs ]; then
        [ -z "$pg_keys" ] && [ -z "$(sel "$work/$variant-built/postgres.yaml" 'select(.kind == "ExternalSecret") | .kind')" ] \
          && [ -z "$(sel "$sw" 'select(.kind == "ExternalSecret") | .kind')" ] \
          && ok "$variant: no backup key is copied anywhere: Google Cloud Storage is written by the cluster's own identities" \
          || bad "$variant: a backup key is copied for Google Cloud Storage"
      else
        [ "$(sel "$work/$variant-built/postgres.yaml" 'select(.kind == "ExternalSecret") | .spec.data[].remoteRef.property' | tr '\n' ' ')" = "$pg_keys" ] \
          && [ "$(sel "$sw" 'select(.kind == "ExternalSecret") | .spec.data[].remoteRef.property' | tr '\n' ' ')" = "backup-access-key-id backup-secret-access-key " ] \
          && ok "$variant: the backup keys come from infrared-platform-tokens${pg_keys:+, for the WAL archive too}" || bad "$variant: the backup keys are copied wrong"
      fi
    else
      [ -z "$(sel "$cn" '.spec.sources[] | select(.chart == "plugin-barman-cloud") | .chart')" ] \
        && [ -z "$(sel "$p" 'select(.kind == "ObjectStore" or .kind == "ScheduledBackup" or .kind == "ExternalSecret") | .kind')" ] \
        && [ -z "$(sel "$p" "$c | .spec.plugins // \"\"")" ] \
        && [ -z "$(sel "$sw" 'select(.kind == "CronJob" or .kind == "ExternalSecret") | .kind')" ] \
        && ok "$variant: no backups without a backup bucket" || bad "$variant: backup objects rendered without a backup bucket"
    fi
  else
    left="$(for f in $store_files; do holds_objects "$f" && echo "$f"; done || true)"
    [ -z "$left" ] && ok "$variant: no stores, no stores objects" || bad "$variant: stores objects rendered without Stores: $left"
  fi
  # The registry inside the cluster: all of it with Registry and Stores, none of
  # it without.
  zot_files="$(printf '%s\n' "$reg/components/zot.yaml" "$reg/components/stores-credentials.yaml"
    find "$out/components/zot" "$out/components/stores-credentials" -name '*.yaml')"
  # With the copies the store renders without the registry too (below).
  [ "$copies_on" = true ] && zot_files="$(printf '%s\n' "$reg/components/zot.yaml"; find "$out/components/zot" -name '*.yaml')"
  if [ "$stores" = true ] && [ -n "$zot_addr" ]; then
    for a in stores-credentials:19:stores zot:20:registry; do
      IFS=: read -r name wave ns <<<"$a"
      f="$reg/components/$name.yaml"
      [ "$(sel "$f" '.metadata.name')" = "$name" ] && [ "$(sel "$f" '.metadata.annotations["argocd.argoproj.io/sync-wave"]')" = "$wave" ] \
        && [ "$(sel "$f" '.spec.project')" = platform ] && [ "$(sel "$f" '.spec.destination.namespace')" = "$ns" ] \
        && ok "$variant: $name Application (wave $wave)" || bad "$variant: $name Application missing or wrong"
    done
    # The store over stores: the registry's S3 keys alone, for registry alone;
    # with Substrate, its S3 keys and its Postgres role too, for ate-system;
    # with backups, the Postgres role substrate, for the Infrared namespace.
    # The namespace stores is the stores' own Applications'.
    c="$work/$variant-built/stores-credentials.yaml"
    want_ns=registry want_names=seaweedfs-s3-registry
    if [ "$substrate" = true ]; then
      want_ns="registry ate-system" want_names="seaweedfs-s3-registry,seaweedfs-s3-ate-snapshots,postgres-substrate"
    fi
    if [ "$copies_on" = true ]; then
      want_ns="$want_ns infrared"
      [ "$substrate" = true ] || want_names="$want_names,postgres-substrate"
    fi
    [ -z "$(sel "$reg/components/stores-credentials.yaml" '.spec.syncPolicy.syncOptions[] | select(. == "CreateNamespace=true")')" ] \
      && [ "$(line "$c" 'select(.kind == "ClusterSecretStore" and .metadata.name == "infrared-stores") | .spec.conditions[].namespaces[]')" = "$want_ns" ] \
      && [ "$(sel "$c" 'select(.kind == "ClusterSecretStore") | .spec.provider.kubernetes.remoteNamespace')" = stores ] \
      && [ "$(line "$c" 'select(.kind == "Role") | .metadata.namespace + " " + (.rules[] | (.resourceNames | join(",")) + ":" + (.verbs | join(",")))')" = "stores $want_names:get" ] \
      && ok "$variant: ClusterSecretStore infrared-stores reads only stores/{$want_names}, for $want_ns" \
      || bad "$variant: ClusterSecretStore infrared-stores is wrong"
    # Zot: chart and image by digest, one replica replaced and never rolled,
    # its Service a ClusterIP at the registry's address.
    f="$reg/components/zot.yaml"
    zv='.spec.sources[] | select(.chart == "zot") | .helm.valuesObject'
    [ "$(sel "$f" '.spec.sources[] | select(.chart == "zot") | .repoURL + " " + .targetRevision + " " + (.helm.skipTests | tostring)')" \
        = "https://zotregistry.dev/helm-charts 0.1.125 true" ] \
      && [ "$(sel "$f" '.spec.sources[0].path')" = components/zot ] \
      && [ "$(sel "$f" "$zv | .image.repository")" = ghcr.io/project-zot/zot ] \
      && sel "$f" "$zv | .image.tag" | grep -qE '^v2\.1\.21@sha256:[0-9a-f]{64}$' \
      && [ "$(sel "$f" "$zv | (.replicaCount | tostring) + \" \" + .strategy.type")" = "1 Recreate" ] \
      && [ "$(sel "$f" "$zv | .service | .type + \" \" + .clusterIP + \":\" + (.port | tostring)")" = "ClusterIP $zot_addr" ] \
      && [ "$(sel "$f" '.spec.syncPolicy.managedNamespaceMetadata.labels["pod-security.kubernetes.io/enforce"]')" = restricted ] \
      && ok "$variant: Zot v2.1.21 (chart 0.1.125) by digest, one replica replaced, its Service a ClusterIP at $zot_addr" \
      || bad "$variant: Zot's chart, image, replicas or Service are wrong"
    # Its config and users are the operator's Secrets, mounted and never
    # rendered; its S3 keys come from the store; it runs as nobody's root.
    leaked="$(find "$out" "$work/$variant-built" -name '*.yaml' -exec yq -N -r \
      'select(.kind == "Secret" and (.metadata.name == "zot-config" or .metadata.name == "zot-auth")) | .metadata.name' {} + 2>/dev/null || true)"
    [ "$(sel "$f" "$zv | (.mountConfig | tostring) + \" \" + (.mountSecret | tostring)")" = "false false" ] \
      && [ "$(line "$f" "$zv | .externalSecrets[] | .secretName + \":\" + .mountPath")" = "zot-config:/etc/zot zot-auth:/etc/zot-auth" ] \
      && [ "$(line "$f" "$zv | .env[] | .name + \":\" + .valueFrom.secretKeyRef.name + \"/\" + .valueFrom.secretKeyRef.key")" \
          = "AWS_ACCESS_KEY_ID:zot-s3/AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY:zot-s3/AWS_SECRET_ACCESS_KEY" ] \
      && [ "$(sel "$f" "$zv | (.podSecurityContext.runAsNonRoot | tostring) + \" \" + (.securityContext.readOnlyRootFilesystem | tostring) + \" \" + (.securityContext.allowPrivilegeEscalation | tostring)")" = "true true false" ] \
      && [ -z "$leaked" ] \
      && ok "$variant: Zot mounts the operator's zot-config and zot-auth, which nothing here renders, reads zot-s3, not as root" \
      || bad "$variant: Zot's config, users, keys or security context are wrong${leaked:+ (renders the Secrets $leaked)}"
    # zot-base: the config the operator completes, Zot v2.1.21's keys, no key in it.
    z="$work/$variant-built/zot.yaml"
    base="$(sel "$z" 'select(.kind == "ConfigMap" and .metadata.name == "zot-base") | .data["config.json"]')"
    # yq reads a key in ["..."], and a string after ==, as a glob: the rules are
    # matched by an anchored regular expression instead.
    zb() { yq -p json -o json -I0 "$1" <<<"$base" 2>/dev/null || true; }
    [ -n "$base" ] && yq -p json -e 'true' <<<"$base" >/dev/null 2>&1 \
      && [ "$(zb '.http.compat')" = '["docker2s2"]' ] \
      && [ "$(zb '[.http.address, .http.port, .http.auth.htpasswd.path, .http.auth.apikey]')" = '["0.0.0.0","5000","/etc/zot-auth/htpasswd",true]' ] \
      && [ "$(zb '.storage | [.dedupe, .gc, .storageDriver.name, .storageDriver.bucket, .storageDriver.regionendpoint, .storageDriver.forcepathstyle]')" \
          = '[false,true,"s3","registry","http://seaweedfs-s3.stores.svc:8333",true]' ] \
      && [ "$(zb '[.. | select(tag == "!!map") | keys[] | select(test("(?i)accesskey|secretkey|password|token"))] | length')" = 0 ] \
      && [ "$(zb '.http.accessControl.repositories | keys')" = '["**","platform/**"]' ] \
      && [ "$(zb '.http.accessControl.repositories | to_entries | .[] | select(.key | test("^[*]{2}$")) | .value')" \
          = '{"anonymousPolicy":["read"],"defaultPolicy":["read"]}' ] \
      && [ "$(zb '.http.accessControl.repositories | to_entries | .[] | select(.key | test("^platform/[*]{2}$")) | .value')" \
          = '{"anonymousPolicy":["read"],"defaultPolicy":["read"],"policies":[{"users":["platform"],"actions":["read","create","update","delete"]}]}' ] \
      && [ "$(zb '.http.accessControl.adminPolicy')" = '{"users":["infrared"],"actions":["read","delete"]}' ] \
      && ok "$variant: zot-base: S3 in the bucket registry with no key in it, docker2s2, htpasswd and API keys, anyone reads, platform writes platform/, infrared deletes" \
      || bad "$variant: zot-base's config.json is wrong"
    # Order: zot-base, then the S3 keys, then the wait for the operator's
    # Secrets (a Sync hook: they come from zot-base), then Zot; before all of
    # it, a PreSync wait for the store and SeaweedFS's S3 gateway.
    w() { sel "$z" "select(.kind == \"$1\" and .metadata.name == \"$2\") | .metadata.annotations[\"argocd.argoproj.io/sync-wave\"]"; }
    j_env() { sel "$z" "select(.kind == \"Job\" and .metadata.name == \"$1\") | .spec.template.spec.containers[0].env[] | select(.name == \"$2\") | .value"; }
    [ "$(w ConfigMap zot-base) $(w ExternalSecret zot-s3) $(w Job zot-config-wait)" = "-3 -2 -1" ] \
      && [ "$(sel "$z" 'select(.kind == "Job" and .metadata.name == "zot-config-wait") | .metadata.annotations["argocd.argoproj.io/hook"]')" = Sync ] \
      && [ "$(j_env zot-config-wait WAIT_SECRETS)" = "registry/zot-config registry/zot-auth registry/zot-s3" ] \
      && [ "$(sel "$z" 'select(.kind == "Job" and .metadata.name == "zot-wait") | .metadata.annotations["argocd.argoproj.io/hook"]')" = PreSync ] \
      && [ "$(j_env zot-wait WAIT_STORES) $(j_env zot-wait WAIT_SERVICES)" = "infrared-stores stores/seaweedfs-s3" ] \
      && [ "$(line "$z" 'select(.kind == "ExternalSecret") | .spec.secretStoreRef.name + " " + .spec.target.name + " " + (.spec.data | map(.remoteRef.key + "/" + .remoteRef.property) | join(","))')" \
          = "infrared-stores zot-s3 seaweedfs-s3-registry/AWS_ACCESS_KEY_ID,seaweedfs-s3-registry/AWS_SECRET_ACCESS_KEY" ] \
      && ok "$variant: Zot starts after zot-base (-3), its S3 keys (-2) and the operator's zot-config and zot-auth (Sync hook, -1)" \
      || bad "$variant: the order before Zot is wrong"
  else
    left="$(for f in $zot_files; do holds_objects "$f" && echo "$f"; done || true)"
    [ -z "$left" ] && ok "$variant: no registry inside the cluster, no objects of it" || bad "$variant: registry objects rendered without Registry and Stores: $left"
  fi

  # The backups' Postgres role: with backups on, the store infrared-stores
  # admits the Infrared namespace for postgres-substrate, and one
  # ExternalSecret copies it there under its own name, after the store, for
  # the operator's backup Job to dump Substrate's records as the role
  # substrate; without, nothing of it. The staging copies' keys are gone.
  [ ! -e "$out/components/stores-credentials/copies.yaml" ] && ! grep -rqE 'objects-copy|gitea-dump|infrared-objects' "$out" \
    && ok "$variant: no staging bucket, identity or key of the copies" \
    || bad "$variant: the staging copies' buckets, identities or keys are still rendered"
  if [ "$copies_on" = true ]; then
    c="$work/$variant-built/stores-credentials.yaml"
    sc="$reg/components/stores-credentials.yaml"
    xs() { line "$c" "select(.kind == \"ExternalSecret\" and .metadata.name == \"$1\") | .metadata.namespace + \" \" + .metadata.annotations[\"argocd.argoproj.io/sync-wave\"] + \" \" + .spec.secretStoreRef.name + \" \" + .spec.target.name + \" \" + (.spec.data | map(.secretKey + \"=\" + .remoteRef.key + \"/\" + .remoteRef.property) | join(\",\"))"; }
    [ "$(sel "$sc" '.metadata.name + " " + .metadata.annotations["argocd.argoproj.io/sync-wave"] + " " + .metadata.labels["infrared.darkshift.io/layer"]')" = "stores-credentials 19 secrets" ] \
      && [ "$(sel "$c" 'select(.kind == "ClusterSecretStore") | .metadata.annotations["argocd.argoproj.io/sync-wave"]')" = 1 ] \
      && grep -qw infrared <<<"$(line "$c" 'select(.kind == "ClusterSecretStore") | .spec.conditions[].namespaces[]')" \
      && grep -qw postgres-substrate <<<"$(line "$c" 'select(.kind == "Role") | .rules[].resourceNames[]')" \
      && [ "$(line "$c" 'select(.kind == "ExternalSecret" and .metadata.namespace == "infrared") | .metadata.name')" = postgres-substrate ] \
      && [ "$(xs postgres-substrate | grep '^infrared ')" = "infrared 2 infrared-stores postgres-substrate username=postgres-substrate/username,password=postgres-substrate/password" ] \
      && ok "$variant: the Postgres role substrate reaches infrared (postgres-substrate) through infrared-stores, after the store, for the backup's dump" \
      || bad "$variant: the backup's Postgres role is not copied into infrared as it should be"
    if [ -z "$zot_addr" ]; then
      # Without the registry the store admits infrared alone, for that role alone.
      [ "$(line "$c" 'select(.kind == "ClusterSecretStore") | .spec.conditions[].namespaces[]')" = infrared ] \
        && [ "$(line "$c" 'select(.kind == "Role") | .rules[].resourceNames[]')" = "postgres-substrate" ] \
        && ok "$variant: without the registry the store hands out the backup's Postgres role alone, to infrared alone" \
        || bad "$variant: without the registry the store hands out more than the backup's Postgres role"
    fi
  else
    ! holds_objects "$out/components/stores-credentials/backup.yaml" \
      && ok "$variant: no recipient (or no stores or backup bucket), no backups' Postgres role" \
      || bad "$variant: the backups' Postgres role is copied without backups"
  fi

  # A restore: with the stores, a backup bucket and a restore point, and only
  # then. Postgres starts empty, as on any install (the Infrared chart's
  # restore Job brings the backup's dumps back and marks postgres); the
  # stores-restore Application's one Job waits for that mark, then copies the
  # buckets back without overwriting and marks buckets; SeaweedFS waits for
  # postgres, Zot and Substrate for the buckets.
  restore_files="$(printf '%s\n' "$reg/components/stores-restore.yaml" "$out/components/seaweedfs/restore-wait.yaml" \
      "$out/components/zot/restore-wait.yaml" "$out/components/substrate/restore-wait.yaml"
    find "$out/components/stores-restore" -name '*.yaml')"
  if [ "$restoring" = true ]; then
    p="$work/$variant-built/postgres.yaml"
    c='select(.kind == "Cluster" and .metadata.name == "postgres")'
    [ "$(sel "$p" "$c | .spec.bootstrap | keys | join(\",\")")" = initdb ] && [ "$(sel "$p" "$c | .spec.bootstrap.initdb.database")" = seaweedfs ] \
      && [ -z "$(sel "$p" "$c | .spec.externalClusters // \"\"")" ] \
      && ok "$variant: a restore starts Postgres empty, with initdb, and recovers no archive" || bad "$variant: a restore's Postgres does not start empty"
    a="$reg/components/stores-restore.yaml"
    [ "$(sel "$a" '.metadata.name + " " + .metadata.annotations["argocd.argoproj.io/sync-wave"] + " " + .metadata.labels["infrared.darkshift.io/layer"] + " " + .spec.project + " " + .spec.destination.namespace + " " + .spec.source.path')" \
        = "stores-restore 18 backups platform stores components/stores-restore" ] \
      && [ -z "$(sel "$a" '.metadata.finalizers[]?')" ] && [ -z "$(sel "$a" '.spec.syncPolicy.syncOptions[] | select(. == "CreateNamespace=true")')" ] \
      && ok "$variant: stores-restore Application (wave 18, layer backups, no finalizer, never makes stores)" \
      || bad "$variant: stores-restore Application missing or wrong"
    r="$work/$variant-built/stores-restore.yaml"
    job() { sel "$r" "select(.kind == \"Job\" and .metadata.name == \"$1\") | $2"; }
    jenv() { job "$1" ".spec.template.spec.$2[] | .env[] | select(.name == \"$3\") | (.value // .valueFrom.secretKeyRef.name)"; }
    wait_sh="$(job stores-restore '.spec.template.spec.initContainers[0].command[2]')"
    copy_sh="$(job stores-restore '.spec.template.spec.initContainers[1].command[2]')"
    # The copy outside: the S3 backend with the platform's backup key, or on
    # Google Cloud Storage rclone's own backend as the Job's ServiceAccount.
    if [ "$provider" = gcs ]; then
      outside_ok() {
        [ "$(jenv stores-restore initContainers RCLONE_CONFIG_OUTSIDE_TYPE)" = "google cloud storage" ] \
          && [ "$(jenv stores-restore initContainers RCLONE_CONFIG_OUTSIDE_ENV_AUTH) $(jenv stores-restore initContainers RCLONE_CONFIG_OUTSIDE_BUCKET_POLICY_ONLY) $(jenv stores-restore initContainers RCLONE_CONFIG_OUTSIDE_NO_CHECK_BUCKET)" = "true true true" ] \
          && [ -z "$(jenv stores-restore initContainers RCLONE_CONFIG_OUTSIDE_ACCESS_KEY_ID)$(jenv stores-restore initContainers RCLONE_CONFIG_OUTSIDE_SECRET_ACCESS_KEY)$(jenv stores-restore initContainers RCLONE_CONFIG_OUTSIDE_ENDPOINT)$(jenv stores-restore initContainers RCLONE_CONFIG_OUTSIDE_PROVIDER)" ]
      }
      outside_words="from Google Cloud Storage as the ServiceAccount stores-restore"
    else
      outside_ok() { [ "$(jenv stores-restore initContainers RCLONE_CONFIG_OUTSIDE_TYPE) $(jenv stores-restore initContainers RCLONE_CONFIG_OUTSIDE_ACCESS_KEY_ID)" = "s3 seaweedfs-backup" ]; }
      outside_words="with the platform's backup key"
    fi
    # shellcheck disable=SC2016 # the wait's own words, matched as they render
    [ "$(sel "$r" 'select(.kind == "Job" and .metadata.annotations["argocd.argoproj.io/hook"] == null) | .metadata.name' | tr '\n' ' ')" = "stores-restore " ] \
      && [ "$(job stores-restore '.metadata.annotations["argocd.argoproj.io/sync-wave"]')" = 0 ] \
      && [ -z "$(sel "$r" 'select(.kind == "Job" and .metadata.annotations["argocd.argoproj.io/hook"] == null) | .spec.ttlSecondsAfterFinished // ""')" ] \
      && [ "$(job stores-restore '.spec.template.spec.initContainers[].name' | tr '\n' ' ')" = "wait copy " ] \
      && [ "$(jenv stores-restore initContainers POINT) $(jenv stores-restore initContainers MARKER)" = "$restoring_point postgres" ] \
      && grep -qF 'jsonpath='"'"'{.data.point}'"'"' 2>/dev/null)" = "$POINT" ]' <<<"$wait_sh" \
      && grep -qF 'jsonpath="{.data.$MARKER}" 2>/dev/null)" ]' <<<"$wait_sh" && grep -q '^ *until marked; do$' <<<"$wait_sh" \
      && ! grep -q 'psql\|DROP OWNED' <<<"$wait_sh" \
      && grep -q -- '--ignore-existing' <<<"$copy_sh" && ! grep -qE 'rclone (sync|move|delete|purge)' <<<"$copy_sh" \
      && grep -qF 'if ! listed="$(rclone lsf --max-depth 1 "$SOURCE/$bucket")"; then' <<<"$copy_sh" && ! grep -q '2>/dev/null' <<<"$copy_sh" \
      && [ "$(jenv stores-restore initContainers BUCKETS)" = "${want_buckets% }" ] \
      && [ "$(jenv stores-restore initContainers SOURCE)" = "outside:$backup/${prefix:-$cluster}/seaweedfs/current" ] \
      && outside_ok && [ "$(jenv stores-restore initContainers RCLONE_CONFIG_SEAWEEDFS_ACCESS_KEY_ID)" = seaweedfs-s3-restore ] \
      && [ "$(jenv stores-restore containers POINT) $(jenv stores-restore containers MARKER)" = "$restoring_point buckets" ] \
      && [ "$(line "$r" 'select(.kind == "Role" and .metadata.name == "stores-restore") | .rules[] | (.resourceNames // [] | join(",")) + ":" + (.verbs | join(","))')" = ":create restore-stores:get,patch" ] \
      && [ "$(sel "$r" 'select(.kind == "Job" and .metadata.name == "stores-restore-wait") | .metadata.annotations["argocd.argoproj.io/hook"] + " " + (.spec.template.spec.containers[0].env[] | select(.name == "WAIT_SERVICES") | .value)')" = "PreSync stores/postgres-rw" ] \
      && ok "$variant: one Job, no index reset: it waits for the mark postgres, then copies every bucket back $outside_words without overwriting, a failed listing failing it, and marks buckets in stores/restore-stores for $restoring_point" \
      || bad "$variant: the stores' restore Job is wrong"
    # The waits: SeaweedFS for Postgres's records (the mark postgres), Zot and
    # Substrate for the buckets, each a PreSync hook reading that one ConfigMap
    # through a Role in stores.
    waits_want="seaweedfs:postgres" waits_got=""
    [ -n "$zot_addr" ] && waits_want="$waits_want zot:buckets"
    [ "$substrate" = true ] && waits_want="$waits_want substrate:buckets"
    for comp in seaweedfs zot substrate; do
      b="$work/$variant-built/$comp.yaml"
      [ -f "$b" ] || continue
      j='select(.kind == "Job" and .metadata.name == "'"$comp"'-restore-wait")'
      [ -n "$(sel "$b" "$j | .metadata.name")" ] || continue
      if [ "$(sel "$b" "$j | .metadata.annotations[\"argocd.argoproj.io/hook\"] + \" \" + .metadata.annotations[\"argocd.argoproj.io/sync-wave\"]")" = "PreSync -9" ] \
          && [ "$(sel "$b" "$j | .spec.template.spec.containers[0].env[] | select(.name == \"POINT\") | .value")" = "$restoring_point" ] \
          && [ "$(line "$b" "select(.kind == \"Role\" and .metadata.name == \"restore-wait-$comp\") | .metadata.namespace + \" \" + (.rules[] | (.resourceNames | join(\",\")) + \":\" + (.verbs | join(\",\")))")" = "stores restore-stores:get" ]; then
        waits_got="$waits_got $comp:$(sel "$b" "$j | .spec.template.spec.containers[0].env[] | select(.name == \"MARKER\") | .value")"
      fi
    done
    [ "${waits_got# }" = "$waits_want" ] \
      && ok "$variant: SeaweedFS waits for Postgres's records, and Zot and Substrate, where they run, for the buckets (${waits_got# })" \
      || bad "$variant: the restore's waits are '${waits_got# }', want '$waits_want'"
  else
    left="$(for f in $restore_files; do [ -f "$f" ] && holds_objects "$f" && echo "$f"; done || true)"
    [ -z "$left" ] && ok "$variant: no restore, no object of one" || bad "$variant: restore objects rendered without a restore: $left"
  fi

  # Agent Substrate: all of it with Stores, Registry and SubstrateCapable, none
  # of it without.
  sub_files="$(for a in substrate-crds substrate-podcert substrate substrate-actors; do
      echo "$reg/components/$a.yaml"; find "$out/components/$a" -name '*.yaml'; done)"
  if [ "$substrate" = true ]; then
    sb="$work/$variant-built"
    sp="$sb/substrate-podcert.yaml" s="$sb/substrate.yaml" sa="$sb/substrate-actors.yaml"
    # Four Applications, waves 20 to 23, each labelled for the agent runtime
    # layer; the CRDs' carries no finalizer, so removing it leaves them.
    for a in substrate-crds:20:ate-system:- substrate-podcert:21:podcertificate-controller-system:baseline \
        substrate:22:ate-system:privileged substrate-actors:23:ate-workers:privileged; do
      IFS=: read -r name wave ns pss <<<"$a"
      f="$reg/components/$name.yaml"
      fin="$(sel "$f" '.metadata.finalizers[]?')"
      created="$(sel "$f" '.spec.syncPolicy.syncOptions[] | select(. == "CreateNamespace=true")')"
      [ "$(sel "$f" '.metadata.name')" = "$name" ] && [ "$(sel "$f" '.metadata.annotations["argocd.argoproj.io/sync-wave"]')" = "$wave" ] \
        && [ "$(sel "$f" '.metadata.labels["infrared.darkshift.io/layer"]')" = agent-runtime ] \
        && [ "$(sel "$f" '.spec.project')" = platform ] && [ "$(sel "$f" '.spec.destination.namespace')" = "$ns" ] \
        && [ "$(sel "$f" '.spec.source.path')" = "components/$name" ] \
        && if [ "$pss" = - ]; then [ -z "$fin$created" ]; else [ "$fin" = resources-finalizer.argocd.argoproj.io ] && [ -n "$created" ] \
          && [ "$(sel "$f" '.spec.syncPolicy.managedNamespaceMetadata.labels["pod-security.kubernetes.io/enforce"]')" = "$pss" ]; fi \
        && ok "$variant: $name Application (wave $wave, layer agent-runtime, namespace $ns$([ "$pss" = - ] || echo ", Pod Security $pss"))" \
        || bad "$variant: $name Application missing or wrong"
    done
    layered="$(for f in "$reg"/components/*.yaml; do sel "$f" 'select(.metadata.labels["infrared.darkshift.io/layer"] == "agent-runtime") | .metadata.name'; done | sort | tr '\n' ' ')"
    [ "$layered" = "substrate substrate-actors substrate-crds substrate-podcert " ] \
      && ok "$variant: only Substrate's four Applications carry infrared.darkshift.io/layer: agent-runtime" \
      || bad "$variant: infrared.darkshift.io/layer: agent-runtime is on $layered"
    [ "$(line "$sb/substrate-crds.yaml" '.kind + "/" + .metadata.name' | tr ' ' '\n' | sort | tr '\n' ' ')" \
        = "CustomResourceDefinition/csidriverconfigs.ate.dev CustomResourceDefinition/sandboxconfigs.ate.dev CustomResourceDefinition/workerpools.ate.dev ValidatingAdmissionPolicy/sandboxconfig-assets ValidatingAdmissionPolicyBinding/sandboxconfig-assets " ] \
      && ok "$variant: substrate-crds holds the three CRDs and the SandboxConfig admission policy" || bad "$variant: substrate-crds holds the wrong objects"
    # Every image by digest; Substrate's own are the pins, the router's Envoy
    # and the hooks' tools are upstream's. Nothing is left to ko.
    pins="$(jq -r '.images[].ref' "$substrate_pins" | sed "s#^ghcr.io/darkshiftio/substrate/#$sub_reg/#" | sort -u)"
    images="$(for b in "$sp" "$s" "$sa"; do
        sel "$b" '(.spec.template.spec // .spec.jobTemplate.spec.template.spec // {}) | ((.initContainers // []) + (.containers // []))[] | .image'
      done | sort -u)"
    unpinned="$(grep -vE '@sha256:[0-9a-f]{64}$' <<<"$images" || true)"
    strays="$(grep -E '^(ghcr.io/darkshiftio/substrate|'"$sub_reg"')/' <<<"$images" | grep -vxF "$pins" || true)"
    worker="$(sel "$sa" 'select(.kind == "WorkerPool") | .spec.workerImage')"
    [ -z "$unpinned" ] && [ -z "$strays" ] && grep -qxF -- "$worker" <<<"$pins" \
      && [ -z "$(grep -rl 'ko://' "$out"/components/substrate* || true)" ] \
      && ok "$variant: every Substrate image by digest, its own ($(grep -cF "$sub_reg/" <<<"$images") and the workers') from scripts/substrate-images.json, on $sub_reg" \
      || bad "$variant: Substrate's images: unpinned '$unpinned', not the pins '$strays', workers '$worker'"
    # From another registry, none of Substrate's images is left on ghcr.
    if [ -n "$sub_registry" ]; then
      [ -z "$(grep -lF 'ghcr.io/darkshiftio/substrate/' "$sp" "$s" "$sa" || true)" ] \
        && ok "$variant: no Substrate image left on ghcr: all on $sub_registry" \
        || bad "$variant: a Substrate image is still pulled from ghcr, not $sub_registry"
    fi
    # Upstream's base less its GKE-only PodMonitoring.
    [ -z "$(grep -rlE '^kind: PodMonitoring|^apiVersion: monitoring.googleapis.com' "$out" "$sb" 2>/dev/null || true)" ] \
      && ok "$variant: no PodMonitoring (GKE Managed Prometheus)" || bad "$variant: a PodMonitoring is rendered"
    # Snapshots in SeaweedFS for the API and atelet; atelet pulls localhost
    # images from the registry inside the cluster, without GCP credentials.
    ds='select(.kind == "DaemonSet" and .metadata.labels.app == "atelet")'
    api='select(.kind == "Deployment" and .metadata.name == "ate-api-server")'
    s3env() { sel "$s" "$1 | .spec.template.spec.containers[0].env[] | select(.name | test(\"^(ATE_STORAGE_BACKEND|AWS_)\")) | .name + \"=\" + (.value // (.valueFrom.secretKeyRef.name + \"/\" + .valueFrom.secretKeyRef.key))" | sort | tr '\n' ' '; }
    want_env="$(printf '%s\n' ATE_STORAGE_BACKEND=s3 AWS_REGION=us-east-1 AWS_ENDPOINT_URL=http://seaweedfs-s3.stores.svc:8333 AWS_S3_USE_PATH_STYLE=true \
      AWS_ACCESS_KEY_ID=ate-s3-credentials/AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY=ate-s3-credentials/AWS_SECRET_ACCESS_KEY | sort | tr '\n' ' ')"
    args="$(line "$s" "$ds | .spec.template.spec.containers[0].args[]")"
    [ "$(s3env "$ds")" = "$want_env" ] && [ "$(s3env "$api")" = "$want_env" ] \
      && grep -qwF -- --gcp-auth-for-image-pulls=false <<<"$args" && ! grep -qF -- --gcp-auth-for-image-pulls=true <<<"$args" \
      && grep -qwF -- "--localhost-registry-replacement=$zot_addr" <<<"$args" \
      && ok "$variant: the API and atelet keep snapshots in ate-snapshots; atelet pulls localhost images from $zot_addr, without GCP credentials" \
      || bad "$variant: the API's or atelet's snapshot or image settings are wrong (atelet: $args)"
    # One version everywhere: atelet's nodes, the workers', the labels the hooks write.
    version="$(jq -r .version "$substrate_pins")"
    jenv() { sel "$1" "select(.kind == \"$2\" and .metadata.name == \"$3\") | (.spec.template.spec // .spec.jobTemplate.spec.template.spec).containers[0].env[] | select(.name == \"$4\") | .value"; }
    [ "$(sel "$s" "$ds | .spec.template.spec.nodeSelector[\"ate.dev/substrate-version\"]")" = "$version" ] \
      && [ "$(sel "$sa" 'select(.kind == "WorkerPool") | .spec.template.nodeSelector["ate.dev/substrate-version"]')" = "$version" ] \
      && [ "$(jenv "$s" Job substrate-prepare SUBSTRATE_VERSION)" = "$version" ] \
      && [ "$(jenv "$s" CronJob substrate-node-labels SUBSTRATE_VERSION)" = "$version" ] \
      && ok "$variant: atelet, the workers and the node labels all say Substrate $version" \
      || bad "$variant: Substrate's version differs between atelet, the workers and the node labels"
    # Records on the platform's Postgres, snapshots as the S3 identity
    # ate-snapshots, both copied through infrared-stores.
    es() { sel "$s" "select(.kind == \"ExternalSecret\" and .metadata.name == \"$1\") | .spec.secretStoreRef.name + \" \" + ([.spec.data[]? | .remoteRef.key + \"/\" + .remoteRef.property] | join(\",\"))"; }
    dsn='select(.kind == "ExternalSecret" and .metadata.name == "ate-api-server-secret-envvars") | .spec.target.template.data'
    [ "$(es ate-s3-credentials)" = "infrared-stores seaweedfs-s3-ate-snapshots/AWS_ACCESS_KEY_ID,seaweedfs-s3-ate-snapshots/AWS_SECRET_ACCESS_KEY" ] \
      && [ "$(es ate-api-server-secret-envvars)" = "infrared-stores postgres-substrate/password" ] \
      && [ "$(sel "$s" "$dsn | .ATE_API_POSTGRES_CONNECTION_STRING")" = 'postgresql://substrate:{{ .password }}@postgres-rw.stores.svc:5432/substrate?sslmode=require' ] \
      && [ "$(sel "$s" "$dsn | .ATE_API_POSTGRES_SCHEMA")" = public ] \
      && ok "$variant: Substrate's records in the database substrate on the platform's Postgres, its snapshots as ate-snapshots, through infrared-stores" \
      || bad "$variant: Substrate's Postgres or S3 credentials are wrong"
    # The pull secret: copied to each namespace that pulls, and on every pod.
    if [ -n "$pull_secret" ]; then
      copies="$(for b in "$sp" "$s" "$sa"; do sel "$b" "select(.kind == \"ExternalSecret\" and .metadata.name == \"$pull_secret\") | .metadata.namespace + \":\" + .spec.secretStoreRef.name + \":\" + .spec.dataFrom[0].extract.key + \":\" + .spec.target.template.type"; done | sort | tr '\n' ' ')"
      want_ns="ate-system ate-workers podcertificate-controller-system"
      [ "$test_actors" = true ] && want_ns="$want_ns registry"
      want_copies="$(for n in $want_ns; do echo "$n:infrared-platform:$pull_secret:kubernetes.io/dockerconfigjson"; done | tr '\n' ' ')"
      nopull="$(for b in "$sp" "$s"; do sel "$b" "select(.kind == \"Deployment\" or .kind == \"DaemonSet\") | select((.spec.template.spec.imagePullSecrets // []) | map(.name) | contains([\"$pull_secret\"]) | not) | .metadata.name"; done)"
      [ "$copies" = "$want_copies" ] && [ -z "$nopull" ] \
        && [ "$(sel "$sa" 'select(.kind == "ServiceAccount" and .metadata.name == "default") | .imagePullSecrets[].name')" = "$pull_secret" ] \
        && ok "$variant: $pull_secret copied to Substrate's namespaces ($want_ns) through infrared-platform, and every Substrate pod pulls with it" \
        || bad "$variant: Substrate's pull secret is not everywhere it pulls (copies: $copies; without it: $nopull)"
    else
      [ -z "$(for b in "$sp" "$s" "$sa"; do sel "$b" 'select(.kind == "ExternalSecret" and .spec.secretStoreRef.name == "infrared-platform") | .metadata.name'; done)" ] \
        && [ -z "$(for b in "$sp" "$s" "$sa"; do sel "$b" '(.spec.template.spec // {}).imagePullSecrets[]?.name, .imagePullSecrets[]?.name'; done)" ] \
        && ok "$variant: the install names no pull secret: none copied, none used" || bad "$variant: a pull secret is used though the install names none"
    fi
    # The fence: only Infrared's operator, Substrate itself and the platform's
    # jobs reach the API; only the operator and the jobs reach the router.
    op='{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "infrared"}}, "podSelector": {"matchLabels": {"app.kubernetes.io/name": "infrared", "app.kubernetes.io/component": "operator"}}}'
    client='{"podSelector": {"matchLabels": {"infrared.darkshift.io/substrate-client": "true"}}}'
    metrics='{"from": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "monitoring"}}}], "ports": [{"protocol": "TCP", "port": 9090}]}'
    want_api="{\"podSelector\": {\"matchLabels\": {\"app\": \"ate-api-server\"}}, \"policyTypes\": [\"Ingress\"], \"ingress\": [{\"from\": [$op, {\"podSelector\": {\"matchExpressions\": [{\"key\": \"app\", \"operator\": \"In\", \"values\": [\"atelet\", \"atenet-router\", \"atenet-egress\", \"ate-controller\"]}]}}, $client], \"ports\": [{\"protocol\": \"TCP\", \"port\": 443}]}, $metrics]}"
    want_router="{\"podSelector\": {\"matchLabels\": {\"app\": \"atenet-router\"}}, \"policyTypes\": [\"Ingress\"], \"ingress\": [{\"from\": [$op, $client], \"ports\": [$(for p in 8080 8443 8081 8444 4040; do printf '{"protocol": "TCP", "port": %s},' "$p"; done | sed 's/,$//')]}, $metrics]}"
    np() { sel "$s" "select(.kind == \"NetworkPolicy\" and .metadata.name == \"$1\") | .spec" | yq -p yaml -o json -I0 'sort_keys(..)'; }
    [ "$(np ate-api-server)" = "$(yq -p json -o json -I0 'sort_keys(..)' <<<"$want_api")" ] \
      && [ "$(np atenet-router)" = "$(yq -p json -o json -I0 'sort_keys(..)' <<<"$want_router")" ] \
      && [ "$(line "$s" 'select(.kind == "NetworkPolicy") | .metadata.annotations["argocd.argoproj.io/sync-wave"]')" = "-3 -3" ] \
      && ok "$variant: NetworkPolicies admit only Infrared's operator, Substrate and the platform's jobs to the API, and only the operator and the jobs to the router" \
      || bad "$variant: Substrate's NetworkPolicies are wrong"
    # What Substrate's installer does by hand, in hooks, each safe to run again:
    # the CAs and pools made once, the waits, the copy, the templates.
    hook() { sel "$1" "select(.kind == \"Job\" and .metadata.name == \"$2\") | .metadata.annotations[\"argocd.argoproj.io/hook\"] + \" \" + .metadata.annotations[\"argocd.argoproj.io/sync-wave\"]"; }
    openssl="$(for b in "$sp" "$s"; do sel "$b" 'select(.kind == "Job") | .spec.template.spec.initContainers[]? | select(.name == "generate") | .image'; done | sort -u)"
    # The copy and the templates are the test actors'.
    want_hooks=":" then_hooks="no copy and no templates, the test actors being off"
    [ "$test_actors" = true ] && want_hooks="Sync 1:Sync 2" then_hooks="then the copy (Sync 1) and the templates (Sync 2)"
    [ "$(hook "$sp" substrate-podcert-prepare)" = "PreSync -9" ] && [ "$(hook "$s" substrate-prepare)" = "PreSync -9" ] \
      && [ "$(hook "$sa" substrate-actors-wait)" = "PreSync -9" ] \
      && [ "$(hook "$sa" substrate-images):$(hook "$sa" substrate-templates)" = "$want_hooks" ] \
      && grep -qE '^docker\.io/alpine/openssl:[0-9.]+@sha256:[0-9a-f]{64}$' <<<"$openssl" \
      && [ "$(line "$sp" 'select(.kind == "Role" and .metadata.name == "substrate-podcert-prepare") | .rules[0].resourceNames[]')" = "service-dns-ca-pool pod-identity-ca-pool" ] \
      && [ "$(line "$s" 'select(.kind == "Role" and .metadata.name == "substrate-prepare") | .rules[0].resourceNames[]')" = "actor-id-jwt-pool actor-id-ca-pool actor-id-ca-certs" ] \
      && [ "$(jenv "$s" Job substrate-prepare WAIT_SERVICES)" = "stores/postgres-rw stores/seaweedfs-s3" ] \
      && [ "$(jenv "$s" Job substrate-prepare WAIT_BUNDLES)" = "servicedns.podcert.ate.dev:identity:primary-bundle podidentity.podcert.ate.dev:identity:primary-bundle" ] \
      && [ "$(jenv "$sa" Job substrate-actors-wait WAIT_SERVICES)" = "ate-system/api ate-system/atenet-router registry/zot" ] \
      && ok "$variant: the CAs and pools made once before their consumers (PreSync), $then_hooks, each after its waits" \
      || bad "$variant: Substrate's hooks are wrong"
    # The ActorTemplates: a version in each name, the atespace platform, the
    # pool's label, a gVisor SandboxConfig that exists, snapshots under their
    # own name in ate-snapshots, and a localhost image the copy puts in the
    # registry by the same digest. With the test actors off, none of them, no
    # copy, nothing in registry, and the WorkerPool alone.
    tcm='select(.kind == "ConfigMap" and .metadata.name == "substrate-actor-templates")'
    if [ "$test_actors" = true ]; then
      copies="$(sel "$sa" 'select(.kind == "Job" and .metadata.name == "substrate-images") | .spec.template.spec.initContainers[] | select(.args[0] == "copy") | .args[1] + " " + .args[2]')"
      pool="$(sel "$sa" 'select(.kind == "WorkerPool") | .metadata.labels | to_entries[] | .key + "=" + .value')"
      tfail=""
      for key in $(sel "$sa" "$tcm | .data | keys | .[]"); do
        j="$(sel "$sa" "$tcm | .data[\"$key\"]")"
        name="$(jq -r .actorTemplate.metadata.name <<<"$j")"
        image="$(jq -r '.actorTemplate.containers[0].image' <<<"$j")"
        rest="${image#localhost/platform/substrate/}" # <image>:<tag>@sha256:<digest>
        [ "$key" = "$name.json" ] && [[ "$name" =~ -v[0-9]+$ ]] && [ "$(jq -r .actorTemplate.metadata.atespace <<<"$j")" = platform ] \
          && [ "$(jq -r .actorTemplate.snapshotConfig.storageLocation <<<"$j")" = "s3://ate-snapshots/platform/$name/" ] \
          && [ "$(jq -r '.actorTemplate.workerSelector.matchLabels | to_entries[] | .key + "=" + .value' <<<"$j")" = "$pool" ] \
          && [ "$(jq -r '.actorTemplate.sandboxConfig | .sandboxClass + " " + .configName' <<<"$j")" \
              = "SANDBOX_CLASS_GVISOR $(sel "$s" 'select(.kind == "SandboxConfig" and .spec.sandboxClass == "gvisor") | .metadata.name')" ] \
          && [[ "$image" == localhost/platform/substrate/*:*@sha256:* ]] \
          && grep -qxF -- "$sub_reg/$rest" <<<"$pins" \
          && grep -qxF -- "$sub_reg/$rest $zot_addr/platform/substrate/${rest%@*}" <<<"$copies" \
          || tfail="$tfail $name"
      done
      [ -z "$tfail" ] && [ -n "$copies" ] && [ "$(sel "$sa" 'select(.kind == "WorkerPool") | .metadata.name + " " + .spec.sandboxClass')" = "platform gvisor" ] \
        && [ "$(sel "$sa" 'select(.kind == "Job" and .metadata.name == "substrate-templates") | .spec.template.metadata.labels["infrared.darkshift.io/substrate-client"]')" = true ] \
        && [ "$(sel "$sa" 'select(.kind == "Job" and .metadata.name == "substrate-templates") | .spec.template.spec.volumes[] | select(.name == "ate-token") | .projected.sources[0].serviceAccountToken.audience')" = api.ate-system.svc ] \
        && ok "$variant: ActorTemplates $(sel "$sa" "$tcm | .data | keys | .[]" | sed 's/\.json$//' | tr '\n' ' ')in the atespace platform, their images copied to $zot_addr/platform/substrate by digest" \
        || bad "$variant: Substrate's ActorTemplates or the copy of their images are wrong:$tfail"
    else
      [ -z "$(sel "$sa" "$tcm | .metadata.name")" ] \
        && [ -z "$(sel "$sa" 'select(.kind == "Job" and (.metadata.name == "substrate-images" or .metadata.name == "substrate-templates")) | .metadata.name')" ] \
        && [ -z "$(sel "$sa" 'select(.metadata.namespace == "registry") | .kind')" ] \
        && ! holds_objects "$out/components/substrate-actors/images.yaml" && ! holds_objects "$out/components/substrate-actors/templates.yaml" \
        && [ "$(sel "$sa" 'select(.kind == "WorkerPool") | .metadata.name + " " + .spec.sandboxClass')" = "platform gvisor" ] \
        && ok "$variant: the test actors are off: no ActorTemplate, no copy of their images, nothing in registry; the WorkerPool platform stays" \
        || bad "$variant: the test actors are off, but something of them renders, or the WorkerPool is gone"
    fi
  else
    left="$(for f in $sub_files; do holds_objects "$f" && echo "$f"; done || true)"
    [ -z "$left" ] && ok "$variant: Substrate is off, no objects of it" || bad "$variant: Substrate objects rendered without Stores, Registry and SubstrateCapable: $left"
  fi

  # Infrared's code index: all of it with the image registry and its pin, none
  # of it without.
  ci_files="$(printf '%s\n' "$reg/components/code-index.yaml"; find "$out/components/code-index" -name '*.yaml')"
  if [ "$code_index" = true ]; then
    a="$reg/components/code-index.yaml" b="$work/$variant-built/code-index.yaml"
    d='select(.kind == "Deployment" and .metadata.name == "code-index")'
    want_image="$image_registry/infrared-codeindex${pin_tag:+:$pin_tag}${pin_digest:+@$pin_digest}"
    [ "$(sel "$a" '[.metadata.name, .metadata.annotations["argocd.argoproj.io/sync-wave"], .metadata.labels["infrared.darkshift.io/layer"],
          .spec.project, .spec.source.path, .spec.destination.namespace,
          .spec.syncPolicy.managedNamespaceMetadata.labels["pod-security.kubernetes.io/enforce"]] | join(" ")')" \
        = "code-index 41 infrared platform components/code-index code-index restricted" ] \
      && yq -N -e '.spec.syncPolicy.syncOptions[] | select(. == "CreateNamespace=true")' "$a" >/dev/null \
      && ok "$variant: code-index Application (wave 41, layer infrared, namespace code-index, Pod Security restricted)" \
      || bad "$variant: the code-index Application is wrong"
    [ "$(line "$b" "$d | (.spec.replicas, .spec.strategy.type, (.spec.template.spec.containers[].name))")" = "1 Recreate code zoekt" ] \
      && [ "$(sel "$b" "$d | .spec.template.spec.containers[].image" | grep -v '^$' | sort -u)" = "$want_image" ] \
      && [ "$(line "$b" "$d | .spec.template.spec | (.securityContext.runAsNonRoot, .securityContext.seccompProfile.type, .automountServiceAccountToken)")" = "true RuntimeDefault false" ] \
      && [ "$(sel "$b" "$d | .spec.template.spec.containers[] | [.securityContext.readOnlyRootFilesystem, .securityContext.allowPrivilegeEscalation, .securityContext.capabilities.drop[0], (.resources.limits.memory != null)] | join(\" \")" | grep -v '^$' | sort -u)" = "true false ALL true" ] \
      && [ "$(line "$b" "$d | .spec.template.spec.volumes[] | select(.name == \"cache\") | .emptyDir.sizeLimit")" = 40Gi ] \
      && [ "$(line "$b" "$d | .spec.template.spec.volumes[] | select(.name == \"settings\" or .name == \"credentials\") | (.configMap.name // .secret.secretName) + \":\" + ((.configMap.optional // .secret.optional) | tostring)")" = "code-index-settings:true code-index-credentials:true" ] \
      && [ "$(sel "$b" "$d | .spec.template.spec.containers[] | select(.name == \"code\") | .readinessProbe.httpGet.path + \" \" + (.ports[0].containerPort | tostring)")" = "/readyz 8080" ] \
      && [ "$(line "$b" "$d | .spec.template.spec.containers[] | select(.name == \"zoekt\") | .args[]")" = "zoekt-webserver -index /cache/index -listen 127.0.0.1:6070" ] \
      && ok "$variant: the code index runs one replica, not root, read-only, from $want_image, its cache on an emptyDir, Zoekt on the pod's loopback" \
      || bad "$variant: the code index's Deployment is wrong"
    [ "$(line "$b" 'select(.kind == "Service" and .metadata.name == "code-index") | (.spec.type, (.spec.ports[] | (.port | tostring) + ">" + .targetPort), .spec.selector["app.kubernetes.io/name"])')" = "ClusterIP 8080>http code-index" ] \
      && [ "$(line "$b" 'select(.kind == "NetworkPolicy" and .metadata.name == "code-index") | (.spec.policyTypes[], (.spec.ingress | length | tostring),
          (.spec.ingress[0].from[] | (.namespaceSelector.matchLabels["kubernetes.io/metadata.name"]) + " " + (.podSelector.matchLabels | to_entries | map(.key + "=" + .value) | join(","))),
          (.spec.ingress[0].ports[] | .port | tostring))')" \
        = "Ingress 1 infrared app.kubernetes.io/component=api,app.kubernetes.io/name=infrared 8080" ] \
      && ok "$variant: Service code-index on 8080, which only infrared-api's pods reach" \
      || bad "$variant: the code index's Service or NetworkPolicy is wrong"
    # Its record and its GitHub App: copied from the install's
    # infrared-platform-tokens, key for key, into the two Secrets the pod
    # mounts, in wave -1 after a wait for the store.
    es() { line "$b" "select(.kind == \"ExternalSecret\" and .metadata.name == \"$1\") | (.metadata.namespace, .metadata.annotations[\"argocd.argoproj.io/sync-wave\"],
        .spec.secretStoreRef.kind + \"/\" + .spec.secretStoreRef.name, .spec.target.name, .spec.target.creationPolicy,
        (.spec.data[] | .secretKey + \"<\" + .remoteRef.key + \"/\" + .remoteRef.property))"; }
    [ "$(es code-index-settings)" = "code-index -1 ClusterSecretStore/infrared-platform code-index-settings Owner knowledge-url<infrared-platform-tokens/code-index-knowledge-url knowledge-ref<infrared-platform-tokens/code-index-knowledge-ref" ] \
      && [ "$(es code-index-credentials)" = "code-index -1 ClusterSecretStore/infrared-platform code-index-credentials Owner github-app-id<infrared-platform-tokens/code-index-github-app-id github-app-installation-id<infrared-platform-tokens/code-index-github-app-installation-id github-app-private-key<infrared-platform-tokens/code-index-github-app-private-key" ] \
      && [ "$(line "$b" "$d | .spec.template.spec.containers[] | select(.name == \"code\") | [(.env[] | select(.name == \"CODEINDEX_SETTINGS\" or .name == \"CODEINDEX_CREDENTIALS\") | .value), (.volumeMounts[] | select(.name == \"settings\" or .name == \"credentials\") | .mountPath)] | join(\" \")")" \
        = "/etc/code-index/settings /etc/code-index/credentials /etc/code-index/settings /etc/code-index/credentials" ] \
      && [ "$(sel "$b" 'select(.kind == "Job" and .metadata.name == "code-index-wait") | .metadata.annotations["argocd.argoproj.io/hook"] + " " + (.spec.template.spec.containers[0].env[] | select(.name == "WAIT_STORES") | .value)')" = "PreSync infrared-platform" ] \
      && ok "$variant: the code index's record and GitHub App copied from infrared-platform-tokens into code-index-settings and code-index-credentials, after a wait for the store" \
      || bad "$variant: the code index's record or credential is not copied from the install's Secret, or not mounted where it reads them"
    if [ "$ci_pull" = true ]; then
      [ "$(sel "$b" "select(.kind == \"ExternalSecret\" and .metadata.name == \"$pull_secret\") | .metadata.namespace + \" \" + .metadata.annotations[\"argocd.argoproj.io/sync-wave\"] + \" \" + .spec.secretStoreRef.name + \" \" + .spec.dataFrom[0].extract.key + \" \" + .spec.target.template.type")" \
          = "code-index -1 infrared-platform $pull_secret kubernetes.io/dockerconfigjson" ] \
        && [ "$(sel "$b" "$d | .spec.template.spec.imagePullSecrets[].name")" = "$pull_secret" ] \
        && ok "$variant: the code index pulls with $pull_secret, copied through infrared-platform" \
        || bad "$variant: the code index's pull secret is not copied, or not used"
    else
      [ "$(sel "$b" 'select(.kind == "ExternalSecret") | .metadata.name' | grep -v '^$' | sort | tr '\n' ' ' | sed 's/ $//')" = "code-index-credentials code-index-settings" ] \
        && [ -z "$(sel "$b" "$d | .spec.template.spec.imagePullSecrets // \"\"")" ] \
        && ok "$variant: no pull secret named, so none copied" || bad "$variant: a pull secret copied or used without a pull secret named"
    fi
  else
    left="$(for f in $ci_files; do holds_objects "$f" && echo "$f"; done || true)"
    [ -z "$left" ] && ok "$variant: the code index is off, no objects of it" || bad "$variant: code-index objects rendered without its image and registry: $left"
  fi

  # Each Linode volume is a service on a limited Linode account: only the
  # Postgres Cluster and, with Forge gitea, Gitea's volume (through the infrared
  # Application's values) name Linode's volume class, so each makes one volume.
  # The Cluster is counted twice, rendered and built.
  linode_refs="$(grep -rhE '^[^#]*linode-block-storage' "$out" "$work/$variant-built" | sed 's/^ *//' | sort | uniq -c | sed 's/^ *//' || true)"
  linode_files="$(grep -rlE '^[^#]*linode-block-storage' "$out" | sed "s#^$out/##" | sort | tr '\n' ' ' | sed 's/ $//' || true)"
  want_files=() want_refs=0
  if [ "$cloud" = linode ]; then
    [ "$stores" = true ] && want_files+=(components/postgres/cluster.yaml) && want_refs=$((want_refs + 2))
    [ "$forge" = gitea ] && want_files+=("registry/clusters/$cluster/components/infrared.yaml") && want_refs=$((want_refs + 1))
  fi
  if [ "$want_refs" -gt 0 ]; then
    [ "$linode_refs" = "$want_refs storageClass: linode-block-storage-retain" ] && [ "$linode_files" = "${want_files[*]}" ] \
      && ok "$variant: only ${want_files[*]} name a Linode volume class" || bad "$variant: a Linode volume class is named elsewhere: $linode_files ($linode_refs)"
  else
    [ -z "$linode_refs" ] && ok "$variant: no Linode volume class named" || bad "$variant: a Linode volume class is named: $linode_refs"
  fi

  # Every repository a platform Application pulls from is a source of the
  # AppProject platform, and every OCI helm repository is registered with Argo CD.
  projects="$out/components/appprojects/appprojects.yaml"
  allowed="$(sel "$projects" 'select(.kind == "AppProject" and .metadata.name == "platform") | .spec.sourceRepos[]')"
  registered="$(yq -N -r 'select(.kind == "Secret" and .metadata.labels["argocd.argoproj.io/secret-type"] == "repository"
    and .stringData.enableOCI == "true") | .stringData.url' "$projects")"
  # The operator alone registers the infrared chart's repository
  # (argocd/infrared-oci-charts), with the pull secret's credential: a second
  # entry for the same URL without one could be the one Argo CD reads.
  [ -z "$(kubectl kustomize "$out/components/argocd" | yq -N -r 'select(.kind == "Secret" and .metadata.labels["argocd.argoproj.io/secret-type"] != null) | .metadata.name')" ] \
    && [ -z "$(grep -rlF -- "url: $chart_repo" "$out" || true)" ] \
    && ok "$variant: the template registers no repository of the infrared chart; the operator does" \
    || bad "$variant: the template registers the infrared chart's repository, beside the operator's"
  repos="$(for f in "$reg"/components/*.yaml; do
      holds_objects "$f" || continue
      [ "$(sel "$f" '.spec.project')" = platform ] || continue
      sel "$f" '((.spec.source // {}), (.spec.sources // [])[]) | .repoURL | select(. != null)'
    done | sort -u)"
  for r in $repos; do
    grep -qxF "$r" <<<"$allowed" || bad "$variant: AppProject platform does not allow $r"
    case "$r" in
      *://* | git@*) ;;
      *) grep -qxF "$r" <<<"$registered" || bad "$variant: OCI repository $r is not registered with Argo CD" ;;
    esac
  done
  ok "$variant: AppProject platform allows every repository its Applications use ($(wc -w <<<"$repos" | tr -d ' '))"

  # The pull secret's copies follow it every hour, or every 5 minutes when it
  # is a registry token, which the chart rewrites every 30 minutes and which
  # is good for an hour.
  if [ -n "$pull_secret" ]; then
    want_refresh=1h0m0s
    [ -n "$token_host" ] && want_refresh=5m0s
    refreshes="$(for b in "$work/$variant-built"/*.yaml; do
        sel "$b" 'select(.kind == "ExternalSecret" and .spec.target.name == "'"$pull_secret"'") | .metadata.namespace + "=" + .spec.refreshInterval'
      done | { grep -v '^$' || true; } | sort | tr '\n' ' ')"
    if [ -z "$refreshes" ]; then
      ok "$variant: no copy of the pull secret"
    elif [ -z "$(tr ' ' '\n' <<<"$refreshes" | grep -v '^$' | grep -v "=$want_refresh\$" || true)" ]; then
      ok "$variant: the pull secret's copies refresh every $want_refresh: $refreshes"
    else
      bad "$variant: the pull secret's copies refresh at $refreshes, want $want_refresh"
    fi
  fi

  # No LoadBalancer: on Linode one is a NodeBalancer, billed monthly. An
  # EnvoyProxy without a Service type gets one by default.
  lb="$(find "$out" "$work/$variant-built" -name '*.yaml' -exec yq -N -r \
    '(select(.kind == "Service" and .spec.type == "LoadBalancer") | .metadata.name),
     (select(.kind == "EnvoyProxy" and (.spec.provider.kubernetes.envoyService.type // "LoadBalancer") == "LoadBalancer") | .metadata.name)' {} + 2>/dev/null || true)"
  [ -z "$lb" ] && ok "$variant: no LoadBalancer Service" || bad "$variant: a LoadBalancer Service would be made: $lb"

  # The org's own paths: hydration overwrites whatever the template renders.
  owned="$(find "$out" \( -path '*/products/*' -o -name 'product-*' -o -name 'products-project.yaml' \) -print)"
  [ -z "$owned" ] && ok "$variant: nothing rendered into the org's own paths" || bad "$variant: renders an org-owned path: $owned"

  # Schemas.
  if kubeconform -strict -ignore-missing-schemas -summary \
      -schema-location default \
      -schema-location "$work/schemas/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
      -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
      "$reg" "$work/$variant-built"; then
    ok "$variant: kubeconform"
  else
    bad "$variant: kubeconform"
  fi
  ok "$variant: rendered and checked ($(find "$out" -type f | wc -l | tr -d ' ') files)"
done
[ "$layers_labelled" -gt 0 ] && ok "layers: $layers_labelled Applications across the variants name a layer infrared-api knows; $layers_by_name, the root and main's ten, take theirs from their names"

# --- Traefik renders what it rendered before ----------------------------------------
# An Installation on Traefik may carry previews settings by hand (infrared-mgmt
# does) and sit on any cloud. With Edge "" or traefik, a platform domain,
# Infrared's host, a cloud and the preflight's result must change nothing, so
# such a cluster's gitops repo hydrates to the same files when this lands. A
# backup bucket without the stores, and Gitea as the forge without a build
# registry, change only the infrared Application, which carries them (checked
# above for the gitea variant), and Gitea the builds component's README, which
# describes the org's forge and holds no objects. A registry address without
# the stores runs no registry, and changes only the infrared Application too.
# Changes are comma-separated.
infrared_app=registry/clusters/demo/components/infrared.yaml
for v in "traefik - -edge traefik" \
    "traefik-facts - -platform-domain preprod.example.com -infrared-host infrared.example.com -cloud aws -substrate-capable" \
    "traefik-linode - -edge traefik -platform-domain $gw_domain -infrared-host $gw_host -cloud linode" \
    "backup-alone $infrared_app -backup {\"bucket\":\"$backup_bucket\",\"endpoint\":\"$backup_endpoint\"}" \
    "gitea-alone components/builds/README.md,$infrared_app -forge gitea -forge-url $gitea_url -cloud linode" \
    "registry-alone $infrared_app -registry $zot_registry" \
    "substrate-registry-alone $infrared_app -registry $zot_registry -substrate-capable" \
    "copies-alone $infrared_app -copies {\"recipients\":[\"$age_recipient\"],\"mirror\":{\"retention\":\"10d\"}}" \
    "archive-alone $infrared_app -postgres-archive {\"enabled\":true,\"retention\":\"14d\"}" \
    "retention-alone $infrared_app -registry-retention {\"keepNewest\":20,\"gcDelay\":\"30m\"}" \
    "server-name-alone - -postgres-server-name $server_name" \
    "code-index-alone - -images $ci_images"; do
  read -r variant changes extra <<<"$v"
  [ "$changes" = - ] && changes=""
  changes="${changes//,/ }"
  # shellcheck disable=SC2086
  "$work/render" -out "$work/$variant" -cluster demo -flavor k3s -build-registry "" $extra >/dev/null
  changed="$({ diff -rq "$work/k3s" "$work/$variant" || true; } | sed -E "s#^Files $work/k3s/(.*) and .* differ\$#\\1#" | sort | tr '\n' ' ' | sed 's/ $//')"
  if [ "$changed" = "$changes" ]; then
    ok "$variant: renders exactly what the plain k3s render does${changes:+, but $changes}"
  else
    bad "$variant: differs from the plain k3s render in '$changed', want '$changes'"
  fi
done
[ "$(yq -r '.spec.sources[0].helm.valuesObject.backup | .bucket + " " + .endpoint' "$work/backup-alone/$infrared_app")" \
    = "$backup_bucket $backup_endpoint" ] \
  && ok "backup-alone: the infrared Application carries the bucket without the stores" \
  || bad "backup-alone: the infrared Application does not carry the backup bucket"
[ "$(yq -o json -I0 '.spec.sources[0].helm.valuesObject | [.gitea, .giteaAdmin]' "$work/gitea-alone/$infrared_app")" \
    = '[{"enabled":true,"persistence":{"storageClass":"linode-block-storage-retain"}},{"existingSecret":"infrared-gitea-admin"}]' ] \
  && ok "gitea-alone: the infrared Application turns Gitea on, on a Linode volume, with the install's admin Secret" \
  || bad "gitea-alone: the infrared Application's gitea values are wrong"

[ "$(yq -o json -I0 '.spec.sources[0].helm.valuesObject.registry' "$work/registry-alone/$infrared_app")" = "{\"address\":\"$zot_registry\"}" ] \
  && ok "registry-alone: the infrared Application carries the registry's address without the stores" \
  || bad "registry-alone: the infrared Application does not carry the registry's address"
# The backups' settings ride in the chart's backup values: the mirror's
# retention as backup.retention, the archive as backup.postgres.archive; never
# copies, which the chart no longer has.
[ "$(yq -o json -I0 '.spec.sources[0].helm.valuesObject.backup' "$work/copies-alone/$infrared_app")" \
    = "{\"recipients\":[\"$age_recipient\"],\"retention\":\"10d\"}" ] \
  && [ "$(yq -o json -I0 '.spec.sources[0].helm.valuesObject.backup' "$work/archive-alone/$infrared_app")" = '{"postgres":{"archive":true}}' ] \
  && [ "$(yq -r '.spec.sources[0].helm.valuesObject | has("copies")' "$work/copies-alone/$infrared_app")" = false ] \
  && [ "$(yq -o json -I0 '.spec.sources[0].helm.valuesObject.registry' "$work/retention-alone/$infrared_app")" = '{"retention":{"keepNewest":20,"gcDelay":"30m"}}' ] \
  && ok "copies-alone, archive-alone, retention-alone: the infrared Application carries the backups' settings under backup, and Zot's retention, without the stores" \
  || bad "copies-alone, archive-alone, retention-alone: the infrared Application does not carry them as set"
# A restore needs the stores and a backup bucket, a point, and that point's
# artifact and a mirror run after it; the archive's recovery is gone. The
# backup key day one reads is infrared-platform-tokens' access key alone.
# Each case: the refusal's words, then the flags.
for c in "needs the stores and a backup bucket|-restore {\"point\":\"$restore_point\"}" \
    "need a Restore.Point|-stores -backup {\"bucket\":\"$backup_bucket\"} -restore {\"artifact\":\"$restore_point.irbackup\"}" \
    "must be the point's object|-stores -backup {\"bucket\":\"$backup_bucket\"} -restore {\"point\":\"$restore_point\",\"artifact\":\"20261006T000500Z.irbackup\"}" \
    "at or after the point|-stores -backup {\"bucket\":\"$backup_bucket\"} -restore {\"point\":\"$restore_point\",\"mirrorRun\":\"20261006T001700Z\"}" \
    "unknown field|-stores -backup {\"bucket\":\"$backup_bucket\"} -restore {\"point\":\"$restore_point\",\"postgres\":{\"source\":\"postgres\"}}" \
    "the one Secret the store infrared-platform reads|-stores -backup {\"bucket\":\"$backup_bucket\",\"credentials\":{\"secret\":\"acme-backup-key\"}}" \
    "the one kind of credential day one reads|-stores -backup {\"bucket\":\"$backup_bucket\",\"credentials\":{\"kind\":\"role\"}}" \
    "Backup.Prefix must be|-stores -backup {\"bucket\":\"$backup_bucket\",\"prefix\":\"Acme/Mgmt\"}"; do
  words="${c%%|*}" args="${c#*|}"
  # shellcheck disable=SC2086 # the flags split on spaces; the JSON holds none
  if "$work/render" -out "$work/refused" -cluster demo -flavor k3s $args >/dev/null 2>"$work/refused.err"; then
    bad "hack/render rendered what it should refuse: $args"
  elif grep -qF -- "$words" "$work/refused.err"; then
    ok "hack/render refuses it (\"$words\"): $args"
  else
    bad "hack/render refuses $args, but not with \"$words\": $(head -n 1 "$work/refused.err")"
  fi
done

# --- The mirror's mark names the newest complete backup -----------------------------
# The copies variant's mirror script, run with a fake rclone and date over a
# fake bucket: before any bucket is copied, it names the newest backup whose
# artifact and manifest are both there and whose manifest's own "size" (not a
# part's) is the artifact's; a newer one without its manifest, or of another
# size, is passed over; with no backup, or no backups/ at all, the mark names
# none.
mirror_script="$(yq -N -r 'select(.kind == "CronJob" and .metadata.name == "seaweedfs-backup")
  | .spec.jobTemplate.spec.template.spec.containers[0].command[2]' "$work/copies-built/seaweedfs.yaml")"
fake="$work/fake-mirror"
mkdir -p "$fake/bin"
# rclone: lsf of backups/ prints the listing fixture (none: directory not
# found, as rclone says it), cat prints a manifest, rcat keeps the mark; every
# call is logged.
cat >"$fake/bin/rclone" <<'EOF'
#!/bin/sh
echo "$*" >>"$FAKE_LOG"
case "$1" in
  lsf)
    case "$*" in
      *"$BACKUPS/"*) [ -f "$FAKE_BUCKET/listing" ] || exit 3; cat "$FAKE_BUCKET/listing" ;;
    esac ;;
  cat) cat "$FAKE_BUCKET/${2##*/}" ;;
  rcat) cat >"$FAKE_BUCKET/mark" ;;
esac
EOF
# date: 2026-10-06T02:17:00Z, in each form the script asks for.
cat >"$fake/bin/date" <<'EOF'
#!/bin/sh
case "$*" in
  *-d*) echo 20260929021700 ;;
  *+%s*) echo 1791253020 ;;
  *T%H%M%SZ*) echo 20261006T021700Z ;;
  *) echo 2026-10-06T02:17:00Z ;;
esac
EOF
chmod +x "$fake/bin/rclone" "$fake/bin/date"
# mirror_mark <case>: runs the script over the fixture in $fake/<case>, prints the mark's backup.
mirror_mark() {
  (
    export FAKE_BUCKET="$fake/$1" FAKE_LOG="$fake/$1/log" PATH="$fake/bin:$PATH"
    export BUCKETS="ate-snapshots registry" DESTINATION="dst:$backup_bucket/$backup_prefix/seaweedfs" BACKUPS="dst:$backup_bucket/$backup_prefix/backups"
    sh -ec "$mirror_script" >"$fake/$1/out" 2>&1
  ) || { echo "  the mirror script failed on $1: $(tail -n 3 "$fake/$1/out")"; return 1; }
  jq -r '.backup' "$fake/$1/mark"
}
mkdir -p "$fake/newest" "$fake/older" "$fake/none" "$fake/absent"
# newest: 0205 has no manifest yet, 0105 is complete (its manifest pretty-printed).
printf '%s\n' '20261006T000500Z.irbackup 1000' '20261006T000500Z.json 300' '20261006T010500Z.irbackup 2000' \
  '20261006T010500Z.json 310' '20261006T020500Z.irbackup 3000' >"$fake/newest/listing"
jq -n '{format: 2, kind: "backup", stamp: "20261006T010500Z", object: "20261006T010500Z.irbackup",
  parts: {gitea: {size: 1999}, postgres: {size: 3000}}, size: 2000, sha256: "0"}' >"$fake/newest/20261006T010500Z.json"
# older: 0105's manifest says another size (a part says the artifact's), so 0005.
cp "$fake/newest/listing" "$fake/older/listing"
jq -c '.size = 1999 | .parts.gitea.size = 2000' "$fake/newest/20261006T010500Z.json" >"$fake/older/20261006T010500Z.json"
jq -c '.stamp = "20261006T000500Z" | .object = "20261006T000500Z.irbackup" | .size = 1000' "$fake/newest/20261006T010500Z.json" \
  >"$fake/older/20261006T000500Z.json"
# none: artifacts without manifests; absent: no backups/ at all.
printf '%s\n' '20261006T010500Z.irbackup 2000' >"$fake/none/listing"
got="$(for c in newest older none absent; do printf '%s=%s ' "$c" "$(mirror_mark "$c")"; done)"
first_sync="$(grep -n '^sync ' "$fake/newest/log" | head -n 1 | cut -d: -f1)"
listed="$(grep -n "^lsf .*$backup_prefix/backups/\$" "$fake/newest/log" | cut -d: -f1)"
[ "$got" = "newest=20261006T010500Z older=20261006T000500Z none= absent= " ] \
  && [ -n "$listed" ] && [ -n "$first_sync" ] && [ "$listed" -lt "$first_sync" ] \
  && [ "$(jq -c 'keys' "$fake/newest/mark")" = '["backup","buckets","finished","run"]' ] \
  && [ "$(jq -r '.run + " " + .buckets' "$fake/newest/mark")" = "20261006T021700Z ate-snapshots registry" ] \
  && ok "the mirror's mark names the newest complete backup before it copies ($got)" \
  || bad "the mirror's mark names the wrong backup: $got (listed at line $listed, first copy at $first_sync)"

# --- The backup key's defaults, spelled out, render what none renders ----------------
# The operator sends day one's credential explicitly: infrared-platform-tokens,
# backup-access-key-id, backup-secret-access-key, accessKey.
yq -p json -o json '.Backup.Credentials = {"Secret": "infrared-platform-tokens", "AccessKeyIDKey": "backup-access-key-id",
    "SecretKeyKey": "backup-secret-access-key", "Kind": "accessKey"}' "$work/substrate.json" >"$work/credentials.json"
"$work/render" -out "$work/cmp-no-credentials" -cluster demo-x -flavor k3s -build-registry "$zot_registry" -data "$work/substrate.json" >/dev/null
"$work/render" -out "$work/cmp-credentials" -cluster demo-x -flavor k3s -build-registry "$zot_registry" -data "$work/credentials.json" >/dev/null
changed="$({ diff -rq "$work/cmp-no-credentials" "$work/cmp-credentials" || true; } | tr '\n' ' ')"
[ -z "$changed" ] && ok "credentials: the operator's explicit defaults render exactly what none renders" \
  || bad "credentials: the explicit defaults change files: $changed"

# --- A restore changes only the restore's files ---------------------------------------
# The copies variant and the restore variant, rendered for one cluster: the
# restore adds its Application, component and waits, guards the mirror and adds
# the identity restore, and changes nothing else: Postgres starts as on any
# install. The infrared Application, which never carries it, stays the same.
"$work/render" -out "$work/cmp-copies" -cluster demo-x -flavor k3s -build-registry "$zot_registry" -data "$work/copies.json" >/dev/null
"$work/render" -out "$work/cmp-restore" -cluster demo-x -flavor k3s -build-registry "$zot_registry" -data "$work/restore.json" >/dev/null
changed="$({ diff -rq "$work/cmp-copies" "$work/cmp-restore" || true; } \
  | sed -E "s#^Files $work/cmp-copies/(.*) and .* differ\$#\\1#" | sort | tr '\n' ' ' | sed 's/ $//')"
want="$(printf '%s\n' README.md components/seaweedfs/backup.yaml components/seaweedfs/identities.yaml \
    components/seaweedfs/kustomization.yaml components/seaweedfs/prepare.yaml components/seaweedfs/restore-wait.yaml \
    components/stores-restore/kustomization.yaml components/stores-restore/restore.yaml components/stores-restore/wait.yaml \
    components/substrate/kustomization.yaml components/substrate/restore-wait.yaml components/zot/kustomization.yaml \
    components/zot/restore-wait.yaml registry/clusters/demo-x/components/seaweedfs.yaml registry/clusters/demo-x/components/stores-restore.yaml \
  | sort | tr '\n' ' ' | sed 's/ $//')"
[ "$changed" = "$want" ] && ok "restore: changes only the restore's $(wc -w <<<"$want" | tr -d ' ') files, never the infrared Application" \
  || bad "restore: changed '$changed', want '$want'"

# --- Agent Substrate needs the stores, the registry and the preflight's yes ---------
# The preflight's yes with the stores but no registry renders exactly what the
# stores alone render; with the registry and the stores but no yes, exactly what
# they render (the registry-plain variant above); on Traefik with no stores, the
# plain render (traefik-facts and substrate-registry-alone above). So a cluster
# without the stores whose preflight says yes one day changes no file.
"$work/render" -out "$work/substrate-no-registry" -cluster demo-sp -flavor k3s -build-registry "" -stores -substrate-capable >/dev/null
changed="$({ diff -rq "$work/stores-plain" "$work/substrate-no-registry" || true; } | tr '\n' ' ')"
[ -z "$changed" ] && ok "substrate-no-registry: the preflight's yes with the stores alone renders exactly what the stores do" \
  || bad "substrate-no-registry: the preflight's yes changes files without a registry: $changed"
"$work/render" -out "$work/substrate-not-capable" -cluster demo-ss -flavor k3s -build-registry "" -stores -registry "$zot_registry" >/dev/null
"$work/render" -out "$work/substrate-capable" -cluster demo-ss -flavor k3s -build-registry "" -stores -registry "$zot_registry" -substrate-capable >/dev/null
changed="$({ diff -rq "$work/substrate-not-capable" "$work/substrate-capable" || true; } \
  | sed -E "s#^Files $work/substrate-not-capable/(.*) and .* differ\$#\\1#" | sort)"
others="$(grep -vE '^(README\.md|components/stores-credentials/store\.yaml|components/substrate(-crds|-podcert|-actors)?/.*|registry/clusters/demo-ss/components/substrate(-crds|-podcert|-actors)?\.yaml)$' <<<"$changed" || true)"
[ -z "$others" ] && grep -qx README.md <<<"$changed" && grep -qx components/stores-credentials/store.yaml <<<"$changed" \
  && [ "$(grep -c '^registry/clusters/demo-ss/components/substrate' <<<"$changed")" = 4 ] \
  && ok "substrate-plain: the preflight's yes changes only the README, the store infrared-stores and Substrate's own files ($(wc -l <<<"$changed" | tr -d ' '))" \
  || bad "substrate-plain: the preflight's yes changes more than Substrate's files: $others"

# --- Substrate's pins ---------------------------------------------------------------
# Every vendored file is from the commit and the images in
# scripts/substrate-images.json, and the test scripts use the hooks' tools.
ref="$(jq -r .substrate.ref "$substrate_pins")" tag="$(jq -r .tag "$substrate_pins")"
stale="$(grep -l 'GENERATED by scripts/vendor-substrate.sh' -r template/components/substrate* \
  | while read -r f; do grep -qF "Agent Substrate ${ref:0:7}, manifests/ate-install, images $tag " "$f" || echo "$f"; done)"
vendored="$(grep -l 'GENERATED by scripts/vendor-substrate.sh' -r template/components/substrate* | wc -l | tr -d ' ')"
[ -z "$stale" ] && [ "$vendored" = 10 ] && ok "Substrate's $vendored vendored files are from ${ref:0:7} with images $tag" \
  || bad "Substrate's vendored files are not all from ${ref:0:7} and $tag ($vendored files; stale: $stale)"
for pin in SUBSTRATE_K8S_IMAGE SUBSTRATE_GRPCURL_IMAGE; do
  image="$(sed -n -E "s/^$pin=//p" scripts/substrate-lib.sh)"
  grep -qF -- "image: $image" template/components/substrate-actors/templates.yaml.tmpl \
    && ok "scripts/substrate-lib.sh's $pin is the hooks' ($image)" || bad "scripts/substrate-lib.sh's $pin ($image) is not the hooks' pin"
done

# --- Disabled leaves a component out, and changes nothing else ----------------------
# Each optional component, named in Disabled on a variant that renders it: its
# Application holds no objects, and only it, the repo's README.md and the
# infrared Application, which carries the list, change.
# appprojects, argocd and infrared cannot be disabled (hack/render refuses them).
# render_again <variant> <out> [flags]: renders a variant of the list above again.
render_again() {
  local name="$1" dir="$2" v variant cluster flavor registry extra
  shift 2
  for v in "${variants[@]}"; do
    read -r variant cluster flavor registry extra <<<"$v"
    [ "$variant" = "$name" ] || continue
    [ "$registry" = - ] && registry=""
    # shellcheck disable=SC2086
    "$work/render" -out "$dir" -cluster "$cluster" -flavor "$flavor" -build-registry "$registry" $extra "$@" >/dev/null
    echo "$cluster"
    return 0
  done
  return 1
}
for v in "k3s cert-manager external-secrets infisical kpack victoria-metrics-k8s-stack" \
    "eks aws-load-balancer-controller" \
    "k3s-builds builds" \
    "gateway platform-tokens envoy-gateway origin-ca-issuer external-dns edge" \
    "stores-plain cloudnative-pg postgres seaweedfs" \
    "stores-backup platform-tokens" \
    "registry-plain stores-credentials zot" \
    "substrate-plain substrate-crds substrate-podcert substrate substrate-actors" \
    "code-index-pull code-index"; do
  read -r base names <<<"$v"
  for name in $names; do
    out="$work/disabled-$base-$name"
    cluster="$(render_again "$base" "$out" -disabled "[\"$name\"]")" || { bad "disabled $name: no variant $base"; continue; }
    app="registry/clusters/$cluster/components/$name.yaml"
    infrared="registry/clusters/$cluster/components/infrared.yaml"
    changed="$({ diff -rq "$work/$base" "$out" || true; } | sed -E "s#^Files $work/$base/(.*) and .* differ\$#\\1#" | sort | tr '\n' ' ' | sed 's/ $//')"
    want="$(printf '%s\n' README.md "$app" "$infrared" | sort | tr '\n' ' ' | sed 's/ $//')"
    if holds_objects "$work/$base/$app" && ! holds_objects "$out/$app" && [ "$changed" = "$want" ] \
        && [ "$(yq -o json -I0 '.spec.sources[0].helm.valuesObject.components.disabled' "$out/$infrared")" = "[\"$name\"]" ]; then
      ok "disabled $name: its Application is left out, the infrared Application carries it, nothing else changes"
    else
      bad "disabled $name: changed '$changed'; want $want, an empty $app and components.disabled [\"$name\"]"
    fi
  done
done

# --- Substrate's test actors are a setting ----------------------------------------
# substrate-test-actors in Disabled, on the one install's shape: only the files
# that name the test actors change. Their own two hold no objects, the
# kustomization and the comments say so, registry loses the pull secret, the
# store infrared-platform stops admitting registry, and the infrared Application
# drops substrate.testActors and still carries only infisical.
cluster="$(render_again substrate "$work/substrate-test-actors-off" -disabled '["infisical","substrate-test-actors"]')"
changed="$({ diff -rq "$work/substrate" "$work/substrate-test-actors-off" || true; } \
  | sed -E "s#^Files $work/substrate/(.*) and .* differ\$#\\1#" | sort | tr '\n' ' ' | sed 's/ $//')"
want="$(printf '%s\n' README.md components/platform-tokens/store.yaml \
    components/substrate-actors/images.yaml components/substrate-actors/kustomization.yaml \
    components/substrate-actors/pull-secrets.yaml components/substrate-actors/templates.yaml \
    components/substrate-actors/wait.yaml "registry/clusters/$cluster/components/infrared.yaml" \
    "registry/clusters/$cluster/components/substrate-actors.yaml" \
  | sort | tr '\n' ' ' | sed 's/ $//')"
off_app="$work/substrate-test-actors-off/registry/clusters/$cluster/components/infrared.yaml"
[ "$changed" = "$want" ] \
  && [ "$(yq -o json -I0 '.spec.sources[0].helm.valuesObject | [.components, .substrate]' "$off_app")" = '[{"disabled":["infisical"]},null]' ] \
  && [ "$(yq -o json -I0 '.spec.sources[0].helm.valuesObject.substrate' "$work/substrate/registry/clusters/$cluster/components/infrared.yaml")" = '{"testActors":true}' ] \
  && ! grep -q 'substrate-test-actors' <(sed -n '/^Left out on purpose/,/^$/p' "$work/substrate-test-actors-off/README.md") \
  && ok "substrate-test-actors: leaves out only the test actors ($(wc -w <<<"$want" | tr -d ' ') files change), and the infrared Application never carries the name" \
  || bad "substrate-test-actors: changed '$changed', want '$want', or the infrared Application or README carry it wrong"

# --- a build registry that is not ECR ---------------------------------------------
# No ECR login job and no privileged namespace; builds/registry-push is the org's.
"$work/render" -out "$work/ghcr" -cluster demo-g -flavor k3s -build-registry ghcr.io/demo-org >/dev/null
if kubectl kustomize "$work/ghcr/components/builds" > "$work/ghcr-builds.yaml"; then
  if grep -qE 'ecr-login|build-credentials' "$work/ghcr-builds.yaml"; then
    bad "ghcr: ECR login rendered for a non-ECR registry"
  else
    [ "$(yq -N -r 'select(.kind == "ClusterBuilder") | .spec.tag' "$work/ghcr-builds.yaml")" = ghcr.io/demo-org/kpack-builder ] \
      && ok "ghcr: builds without ECR login" || bad "ghcr: ClusterBuilder tag wrong"
  fi
else
  bad "ghcr: kustomize build components/builds"
fi

if [ "$fail" -ne 0 ]; then echo "verify: FAILED" >&2; exit 1; fi
echo "verify: all checks passed"
