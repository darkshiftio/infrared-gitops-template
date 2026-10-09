CLUSTER ?= demo
FLAVOR  ?= k3s
REGION  ?= us-east-1
OUT     ?= out
# BUILD_REGISTRY: the registry prefix product images are built into (defaults to
# $INFRARED_BUILD_REGISTRY); empty leaves the builds component out. E.g.
# make render BUILD_REGISTRY=123456789012.dkr.ecr.us-east-1.amazonaws.com/acme
BUILD_REGISTRY ?= $(INFRARED_BUILD_REGISTRY)
# EDGE: "" or traefik (as before), or gateway; PLATFORM_DOMAIN and INFRARED_HOST
# are the names a gateway edge serves. E.g.
# make render EDGE=gateway PLATFORM_DOMAIN=preprod.example.com INFRARED_HOST=infrared.preprod.example.com
EDGE            ?=
PLATFORM_DOMAIN ?=
INFRARED_HOST   ?=
# STORES: true renders CloudNativePG, one Postgres Cluster and SeaweedFS; BACKUP
# (JSON, as INFRARED_BACKUP) copies them to a bucket outside the cluster;
# DISABLED (a JSON array, as INFRARED_DISABLED_COMPONENTS) leaves components out.
# CLOUD is "", aws or linode. E.g.
# make render STORES=true CLOUD=linode DISABLED='["infisical"]' \
#   BACKUP='{"bucket": "acme-backups", "endpoint": "https://us-east-1.linodeobjects.com", "region": "us-east-1"}'
STORES   ?= false
BACKUP   ?=
DISABLED ?=
CLOUD    ?=
# FORGE: "" (GitHub, as before) or gitea, with FORGE_URL, the forge's root as the
# cluster reaches it. E.g.
# make render FORGE=gitea FORGE_URL=http://gitea-http.infrared.svc.cluster.local:3000
FORGE     ?=
FORGE_URL ?=
# REGISTRY: the address of the registry inside the cluster, <IPv4>:<port> (as
# INFRARED_REGISTRY); with STORES=true the template runs Zot there, and builds
# push their builder to it. E.g.
# make render STORES=true REGISTRY=10.43.0.50:5000 BUILD_REGISTRY=10.43.0.50:5000
REGISTRY ?=
# SUBSTRATE_CAPABLE: the operator's preflight; true, with STORES=true and a
# REGISTRY, runs Agent Substrate. E.g.
# make render STORES=true REGISTRY=10.43.0.50:5000 SUBSTRATE_CAPABLE=true PULL_SECRET=ghcr-pull
SUBSTRATE_CAPABLE ?= false
# PULL_SECRET: the install's image pull Secret in the infrared namespace, which
# Substrate's namespaces copy; empty for none.
PULL_SECRET ?=
# SUBSTRATE_REGISTRY: where Substrate's images come from (empty: ghcr); and
# REGISTRY_TOKEN (JSON, as INFRARED_REGISTRY_TOKEN): the pull secret is a Google
# access token the chart rewrites every 30 minutes. E.g.
# make render STORES=true REGISTRY=10.43.0.50:5000 SUBSTRATE_CAPABLE=true PULL_SECRET=registry-token \
#   SUBSTRATE_REGISTRY=us-central1-docker.pkg.dev/darkshift-preprod/infrared/substrate \
#   REGISTRY_TOKEN='{"gcpServiceAccount": "registry-reader@darkshift-preprod.iam.gserviceaccount.com", "registry": "us-central1-docker.pkg.dev"}'
SUBSTRATE_REGISTRY ?=
REGISTRY_TOKEN     ?=

.PHONY: render verify test vendor-argocd vendor-kpack clean

## render: render template/ into $(OUT)/ (make render CLUSTER=demo FLAVOR=k3s)
render:
	rm -rf $(OUT)
	go run ./hack/render -template template -out $(OUT) -cluster $(CLUSTER) -flavor $(FLAVOR) -region $(REGION) -build-registry "$(BUILD_REGISTRY)" \
		-edge "$(EDGE)" -platform-domain "$(PLATFORM_DOMAIN)" -infrared-host "$(INFRARED_HOST)" \
		-stores=$(STORES) -backup '$(BACKUP)' -disabled '$(DISABLED)' -cloud "$(CLOUD)" \
		-forge "$(FORGE)" -forge-url "$(FORGE_URL)" -registry "$(REGISTRY)" \
		-substrate-capable=$(SUBSTRATE_CAPABLE) -pull-secret "$(PULL_SECRET)" \
		-substrate-registry "$(SUBSTRATE_REGISTRY)" -registry-token '$(REGISTRY_TOKEN)'

## verify: the gate CI runs
verify:
	scripts/verify.sh

test:
	go test ./...

vendor-argocd:
	scripts/vendor-argocd.sh

vendor-kpack:
	scripts/vendor-kpack.sh

clean:
	rm -rf $(OUT)
