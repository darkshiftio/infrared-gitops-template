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
# DOMAIN_TOKEN_KEY: with EDGE=gateway and a PLATFORM_DOMAIN in another
# Cloudflare zone than INFRARED_HOST, the key of infrared-platform-tokens that
# holds that zone's own token (infrared-docs-internal ADR 0063). E.g.
# make render EDGE=gateway PLATFORM_DOMAIN=darkshift.cloud INFRARED_HOST=saas1.darkshift.io \
#   DOMAIN_TOKEN_KEY=cloudflare-domain-api-token
DOMAIN_TOKEN_KEY ?=
# TUNNEL_ID: with EDGE=gateway, the UUID of the Cloudflare Tunnel the edge is
# reached through (infrared-docs-internal ADR 0064): cloudflared in the
# cluster, no host ports, no external-dns or origin issuer; and
# TUNNEL_CREDENTIALS_KEY, the key of infrared-platform-tokens that holds its
# credentials file. E.g.
# make render EDGE=gateway PLATFORM_DOMAIN=darkshift.cloud INFRARED_HOST=saas2.darkshift.io \
#   TUNNEL_ID=6ff42ae2-765d-4adf-8112-31c55c1551ef
TUNNEL_ID              ?=
TUNNEL_CREDENTIALS_KEY ?= cloudflare-tunnel-credentials
# STORES: true renders CloudNativePG, one Postgres Cluster and SeaweedFS; BACKUP
# (JSON, as INFRARED_BACKUP) copies them to a bucket outside the cluster;
# DISABLED (a JSON array, as INFRARED_DISABLED_COMPONENTS) leaves components out.
# CLOUD is "", aws or linode. E.g.
# make render STORES=true CLOUD=linode DISABLED='["infisical"]' \
#   BACKUP='{"bucket": "acme-backups", "endpoint": "https://us-east-1.linodeobjects.com", "region": "us-east-1"}'
STORES   ?= false
# STORES_SINGLE_NODE: true, with STORES=true, runs SeaweedFS on the cluster's
# one node, every file written once (as INFRARED_STORES_SINGLE_NODE). E.g.
# make render STORES=true STORES_SINGLE_NODE=true
STORES_SINGLE_NODE ?= false
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
# OIDC: true, with GRAFANA_URL (Grafana's address in a browser) and INFRARED_HOST,
# signs people in to Grafana through Infrared (as INFRARED_OIDC and
# INFRARED_OIDC_GRAFANA_URL; infrared-docs-internal ADR 0053). E.g.
# make render OIDC=true GRAFANA_URL=https://grafana.example.com INFRARED_HOST=infrared.example.com
OIDC        ?= false
GRAFANA_URL ?=
# NETWORK_POLICIES: true renders the network fence (as INFRARED_NETWORK_POLICIES;
# infrared-docs-internal ADR 0066 D1), every platform namespace's ingress policy.
NETWORK_POLICIES ?= false
# REGISTRY_PULLS: true renders the registry reading for no one without a login
# (as INFRARED_REGISTRY_PULLS); STORES_SECURITY: true renders SeaweedFS under its
# own security (as INFRARED_STORES_SECURITY). infrared-docs-internal ADR 0066 D3.
REGISTRY_PULLS  ?= false
STORES_SECURITY ?= false

.PHONY: render verify test vendor-argocd vendor-kpack clean

## render: render template/ into $(OUT)/ (make render CLUSTER=demo FLAVOR=k3s)
render:
	rm -rf $(OUT)
	go run ./hack/render -template template -out $(OUT) -cluster $(CLUSTER) -flavor $(FLAVOR) -region $(REGION) -build-registry "$(BUILD_REGISTRY)" \
		-edge "$(EDGE)" -platform-domain "$(PLATFORM_DOMAIN)" -infrared-host "$(INFRARED_HOST)" -domain-token-key "$(DOMAIN_TOKEN_KEY)" \
		-tunnel-id "$(TUNNEL_ID)" -tunnel-credentials-key "$(TUNNEL_CREDENTIALS_KEY)" \
		-stores=$(STORES) -stores-single-node=$(STORES_SINGLE_NODE) -backup '$(BACKUP)' -disabled '$(DISABLED)' -cloud "$(CLOUD)" \
		-forge "$(FORGE)" -forge-url "$(FORGE_URL)" -registry "$(REGISTRY)" \
		-substrate-capable=$(SUBSTRATE_CAPABLE) -pull-secret "$(PULL_SECRET)" \
		-substrate-registry "$(SUBSTRATE_REGISTRY)" -registry-token '$(REGISTRY_TOKEN)' \
		-oidc=$(OIDC) -grafana-url "$(GRAFANA_URL)" -network-policies=$(NETWORK_POLICIES) \
		-registry-pulls=$(REGISTRY_PULLS) -stores-security=$(STORES_SECURITY)

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
