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
#   - the infrared Application carries the operator's image registry and pins
#   - every chart or repo a platform Application pulls from is a source of the
#     AppProject platform, and nothing renders a LoadBalancer Service
#   - nothing renders where the org's own files live (products/, product-*,
#     products-project.yaml, values/)
#   - with Edge "" or traefik, a platform domain, Infrared's host, a cloud and
#     the preflight's result change nothing: the render equals the plain one
#   - a component named in Disabled renders its Application to comments only,
#     and nothing else changes but the repo's README.md
#   - kubeconform accepts all of it (-strict; CRD kinds are checked against the
#     public CRDs-catalog schemas, and kinds it lacks are skipped)
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

# <variant> <cluster> <flavor> <build registry> [extra render flags]
ecr_registry=123456789012.dkr.ecr.us-east-1.amazonaws.com/acme
variants=(
  "k3s demo k3s -"
  "eks demo-eks eks - -region us-west-2 -repo-url git@github.com:demo-org/gitops.git -pull-secret infrared-pull"
  "k3s-builds demo-b k3s $ecr_registry"
  "eks-builds demo-eks-b eks $ecr_registry -region us-west-2 -pull-secret infrared-pull"
  "gateway demo-gw k3s - -data $work/gateway.json"
)
for v in "${variants[@]}"; do
  read -r variant cluster flavor registry extra <<<"$v"
  [ "$registry" = - ] && registry=""
  # shellcheck disable=SC2086
  "$work/render" -out "$work/$variant" -cluster "$cluster" -flavor "$flavor" -build-registry "$registry" $extra
done

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

  # Flavor-specific components.
  alb="$(yq -N -r '.kind // ""' "$reg/components/aws-load-balancer-controller.yaml" | grep -c Application || true)"
  if [ "$flavor" = eks ]; then
    [ "$alb" = 1 ] && ok "$variant: aws-load-balancer-controller present" || bad "$variant: aws-load-balancer-controller missing"
  else
    [ "$alb" = 0 ] && ok "$variant: aws-load-balancer-controller absent" || bad "$variant: aws-load-balancer-controller rendered"
  fi
  if [ -n "$pull_secret" ]; then
    [ "$(yq -r '.spec.sources[0].helm.valuesObject.imagePullSecrets[0].name' "$reg/components/infrared.yaml")" = "$pull_secret" ] \
      || bad "$variant: imagePullSecrets not rendered into the infrared Application"
  else
    [ "$(yq -r '.spec.sources[0].helm.valuesObject.imagePullSecrets | length' "$reg/components/infrared.yaml")" = 0 ] \
      || bad "$variant: imagePullSecrets should be empty"
  fi
  [ "$(yq -r '.spec.sources[0].helm.valuesObject.builds.registry' "$reg/components/infrared.yaml")" = "$registry" ] \
    || bad "$variant: infrared Application builds.registry is not \"$registry\""

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

  # builds: all of it with a build registry, none of it without.
  if [ -n "$registry" ]; then
    app="$reg/components/builds.yaml"
    [ "$(yq -N -r '.metadata.name' "$app")" = builds ] && [ "$(yq -N -r '.metadata.annotations["argocd.argoproj.io/sync-wave"]' "$app")" = 26 ] \
      && [ "$(yq -N -r '.spec.source.path' "$app")" = components/builds ] \
      && ok "$variant: builds Application (wave 26)" || bad "$variant: builds Application missing or wrong"
    b="$work/$variant-built/builds.yaml"
    if [ -s "$b" ]; then
      has() { [ -n "$(yq -N -r "select(.kind == \"$1\" and .metadata.name == \"$2\") | .metadata.name" "$b")" ]; }
      for want in Namespace/builds Namespace/build-credentials ClusterStore/paketo ClusterStack/noble \
          ClusterBuilder/infrared-builder ServiceAccount/builder CronJob/github-token Job/github-token-bootstrap \
          CronJob/ecr-login Job/ecr-login-bootstrap Role/builds-github-token; do
        has "${want%%/*}" "${want#*/}" || bad "$variant: builds lacks $want"
      done
      [ "$(yq -N -r 'select(.kind == "ClusterBuilder") | .spec.tag' "$b")" = "$registry/kpack-builder" ] \
        || bad "$variant: ClusterBuilder tag is not $registry/kpack-builder"
      [ "$(yq -N -r 'select(.kind == "Role" and .metadata.name == "builds-github-token") | .metadata.namespace' "$b")" = ir-org-demo-org ] \
        || bad "$variant: github App Role is not in ir-org-demo-org"
      [ "$(yq -N -r 'select(.kind == "Namespace" and .metadata.name == "builds") | .metadata.labels["pod-security.kubernetes.io/enforce"]' "$b")" = restricted ] \
        || bad "$variant: namespace builds is not restricted"
      if grep -nE '\| *kubectl apply' "$b" | grep -v -- '--server-side' | grep -q .; then bad "$variant: a client-side kubectl apply in builds"; fi
      ok "$variant: builds component complete"
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
  if [ "$variant" = gateway ]; then
    for a in envoy-gateway:11 origin-ca-issuer:11 platform-tokens:11 external-dns:12 edge:13; do
      name="${a%%:*}" f="$reg/components/${a%%:*}.yaml"
      [ "$(sel "$f" '.metadata.name')" = "$name" ] && [ "$(sel "$f" '.metadata.annotations["argocd.argoproj.io/sync-wave"]')" = "${a#*:}" ] \
        && [ "$(sel "$f" '.spec.project')" = platform ] \
        && ok "$variant: $name Application (wave ${a#*:})" || bad "$variant: $name Application missing or wrong"
    done
    f="$reg/components/envoy-gateway.yaml"
    [ "$(sel "$f" '.spec.sources[] | select(.chart == "gateway-crds-helm") | .helm.valuesObject.crds.gatewayAPI.enabled')" = false ] \
      && [ "$(sel "$f" '.spec.sources[] | select(.chart == "gateway-helm") | .helm.valuesObject.crds.enabled')" = false ] \
      && ok "$variant: Envoy Gateway installs no Gateway API CRDs" || bad "$variant: Envoy Gateway would install the Gateway API CRDs"
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
    # The platform's tokens: one store, one Secret, two namespaces.
    [ "$(line "$t" 'select(.kind == "ClusterSecretStore") | .spec.conditions[].namespaces[]')" = "external-dns envoy-gateway-system" ] \
      && [ "$(sel "$t" 'select(.kind == "ClusterSecretStore") | .spec.provider.kubernetes.remoteNamespace')" = infrared ] \
      && [ "$(line "$t" 'select(.kind == "Role") | .rules[] | .resourceNames[] + ":" + (.verbs | join(","))')" = "infrared-platform-tokens:get" ] \
      && ok "$variant: ClusterSecretStore infrared-platform reads only infrared-platform-tokens, for two namespaces" || bad "$variant: ClusterSecretStore infrared-platform is wrong"
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
    left="$(for f in $edge_files; do holds_objects "$f" && echo "$f"; done || true)"
    [ -z "$left" ] && ok "$variant: the edge is not a Gateway, no edge objects" || bad "$variant: edge objects rendered without Edge gateway: $left"
    [ -z "$(sel "$reg/components/infrared.yaml" '.spec.sources[0].helm.valuesObject | (.image, .operator, .api, .ui, .runner, .mcp.image) | select(. != null) | key')" ] \
      || bad "$variant: image values rendered without the operator's image registry"
  fi

  # Every repository a platform Application pulls from is a source of the
  # AppProject platform, and every OCI helm repository is registered with Argo CD.
  projects="$out/components/appprojects/appprojects.yaml"
  allowed="$(sel "$projects" 'select(.kind == "AppProject" and .metadata.name == "platform") | .spec.sourceRepos[]')"
  registered="$(yq -N -r 'select(.kind == "Secret" and .metadata.labels["argocd.argoproj.io/secret-type"] == "repository"
    and .stringData.enableOCI == "true") | .stringData.url' "$out/components/argocd/infrared-charts-repo.yaml" "$projects")"
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
      -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
      "$reg" "$work/$variant-built"; then
    ok "$variant: kubeconform"
  else
    bad "$variant: kubeconform"
  fi
  ok "$variant: rendered and checked ($(find "$out" -type f | wc -l | tr -d ' ') files)"
done

# --- Traefik renders what it rendered before ----------------------------------------
# An Installation on Traefik may carry previews settings by hand (infrared-mgmt
# does) and sit on any cloud. With Edge "" or traefik, a platform domain,
# Infrared's host, a cloud and the preflight's result must change nothing, so
# such a cluster's gitops repo hydrates to the same files when this lands.
for v in "traefik -edge traefik" \
    "traefik-facts -platform-domain preprod.example.com -infrared-host infrared.example.com -cloud aws -substrate-capable" \
    "traefik-linode -edge traefik -platform-domain $gw_domain -infrared-host $gw_host -cloud linode"; do
  read -r variant extra <<<"$v"
  # shellcheck disable=SC2086
  "$work/render" -out "$work/$variant" -cluster demo -flavor k3s -build-registry "" $extra >/dev/null
  if diff -r "$work/k3s" "$work/$variant" >/dev/null; then
    ok "$variant: renders exactly what the plain k3s render does"
  else
    bad "$variant: differs from the plain k3s render: $(diff -rq "$work/k3s" "$work/$variant" | head -n 5 | tr '\n' ' ')"
  fi
done

# --- Disabled leaves a component out, and changes nothing else ----------------------
# Each optional component, named in Disabled on a variant that renders it: its
# Application holds no objects, and only it and the repo's README.md change.
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
    "gateway platform-tokens envoy-gateway origin-ca-issuer external-dns edge"; do
  read -r base names <<<"$v"
  for name in $names; do
    out="$work/disabled-$name"
    cluster="$(render_again "$base" "$out" -disabled "[\"$name\"]")" || { bad "disabled $name: no variant $base"; continue; }
    app="registry/clusters/$cluster/components/$name.yaml"
    changed="$({ diff -rq "$work/$base" "$out" || true; } | sed -E "s#^Files $work/$base/(.*) and .* differ\$#\\1#" | sort | tr '\n' ' ' | sed 's/ $//')"
    if holds_objects "$work/$base/$app" && ! holds_objects "$out/$app" && [ "$changed" = "README.md $app" ]; then
      ok "disabled $name: its Application is left out, nothing else changes"
    else
      bad "disabled $name: changed '$changed'; want README.md and an empty $app"
    fi
  done
done

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
