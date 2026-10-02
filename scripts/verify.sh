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
#   - kubeconform accepts all of it (-strict; Argo CD kinds are checked
#     against the public CRDs-catalog schemas; other CRD kinds are skipped)
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
# <variant> <cluster> <flavor> <build registry> [extra render flags]
ecr_registry=123456789012.dkr.ecr.us-east-1.amazonaws.com/acme
variants=(
  "k3s demo k3s -"
  "eks demo-eks eks - -region us-west-2 -repo-url git@github.com:demo-org/gitops.git -pull-secret infrared-pull"
  "k3s-builds demo-b k3s $ecr_registry"
  "eks-builds demo-eks-b eks $ecr_registry -region us-west-2 -pull-secret infrared-pull"
)
for v in "${variants[@]}"; do
  read -r variant cluster flavor registry extra <<<"$v"
  [ "$registry" = - ] && registry=""
  # shellcheck disable=SC2086
  "$work/render" -out "$work/$variant" -cluster "$cluster" -flavor "$flavor" -build-registry "$registry" $extra
done

# holds_objects <file>: true when the YAML file has at least one object.
holds_objects() { [ -n "$(yq -N -r '.kind // ""' "$1" 2>/dev/null | grep -v '^$' || true)" ]; }

for v in "${variants[@]}"; do
  read -r variant cluster flavor registry _ <<<"$v"
  [ "$registry" = - ] && registry=""
  out="$work/$variant"

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
    [ "$(yq -r '.spec.sources[0].helm.valuesObject.imagePullSecrets[0].name' "$reg/components/infrared.yaml")" = infrared-pull ] \
      || bad "$variant: imagePullSecrets not rendered into the infrared Application"
  else
    [ "$alb" = 0 ] && ok "$variant: aws-load-balancer-controller absent" || bad "$variant: aws-load-balancer-controller rendered"
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
