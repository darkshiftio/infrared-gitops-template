#!/usr/bin/env bash
# =============================================================================
# The gate for infrared-gitops-template. Runs locally (`make verify`) and in CI.
# =============================================================================
# It renders the template for both cluster flavors with hack/render (the same
# contract the operator implements) and asserts, on the rendered trees:
#   - the render tool builds, is gofmt-clean, vets and passes its tests
#   - no template syntax or __cluster__ segment survives rendering
#   - aws-load-balancer-controller exists on eks and not on k3s
#   - every file parses as YAML
#   - every Application under registry/ is labelled
#     app.kubernetes.io/part-of=infrared-gitops, and every component carries a
#     sync wave, a retry block and SkipDryRunOnMissingResource
#   - every kustomization under components/ builds
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

# --- render both flavors -------------------------------------------------------
"$work/render" -out "$work/k3s" -cluster demo -flavor k3s
"$work/render" -out "$work/eks" -cluster demo-eks -flavor eks -region us-west-2 \
  -repo-url git@github.com:demo-org/gitops.git -pull-secret infrared-pull

for flavor in k3s eks; do
  out="$work/$flavor"

  # Leftover template syntax, only in files that came from a .tmpl (vendored
  # upstream files are copied verbatim and are none of our business).
  while IFS= read -r t; do
    rel="${t#template/}"; rel="${rel%.tmpl}"
    rel="${rel//__cluster__/$( [ "$flavor" = k3s ] && echo demo || echo demo-eks )}"
    if grep -nE '\[\[|\]\]' "$out/$rel" >/dev/null; then bad "$flavor: template syntax left in $rel"; fi
  done < <(find template -type f -name '*.tmpl')
  if find "$out" -name '*__cluster__*' | grep -q .; then bad "$flavor: __cluster__ left in a path"; fi
  if find "$out" -name '*.tmpl' | grep -q .; then bad "$flavor: a .tmpl suffix survived"; fi

  # Every file parses.
  while IFS= read -r f; do
    yq -e 'true' "$f" >/dev/null 2>&1 || yq '.' "$f" >/dev/null 2>&1 || bad "$flavor: $f does not parse as YAML"
  done < <(find "$out" -type f \( -name '*.yaml' -o -name '*.yml' \))

  cluster="$( [ "$flavor" = k3s ] && echo demo || echo demo-eks )"
  reg="$out/registry/clusters/$cluster"
  [ -f "$reg/registry.yaml" ] || bad "$flavor: no registry.yaml"
  [ "$(yq -r '.metadata.name' "$reg/registry.yaml")" = "registry-$cluster" ] || bad "$flavor: root Application is not registry-$cluster"

  # Application conventions.
  for f in "$reg/registry.yaml" "$reg"/components/*.yaml; do
    kinds="$(yq -N -r '.kind // ""' "$f" | grep -v '^$' || true)"
    [ -z "$kinds" ] && continue
    [ "$(yq -N -r '.metadata.labels["app.kubernetes.io/part-of"]' "$f")" = "infrared-gitops" ] \
      || bad "$flavor: $(basename "$f") lacks app.kubernetes.io/part-of: infrared-gitops"
    [ "$(yq -N -r '.spec.syncPolicy.retry.limit' "$f")" = "5" ] || bad "$flavor: $(basename "$f") retry.limit is not 5"
    if [ "$f" != "$reg/registry.yaml" ]; then
      [ "$(yq -N -r '.metadata.annotations["argocd.argoproj.io/sync-wave"] // ""' "$f")" != "" ] \
        || bad "$flavor: $(basename "$f") has no sync wave"
      yq -N -e '.spec.syncPolicy.syncOptions[] | select(. == "SkipDryRunOnMissingResource=true")' "$f" >/dev/null \
        || bad "$flavor: $(basename "$f") lacks SkipDryRunOnMissingResource=true"
    fi
  done

  # Flavor-specific components.
  alb="$(yq -N -r '.kind // ""' "$reg/components/aws-load-balancer-controller.yaml" | grep -c Application || true)"
  if [ "$flavor" = eks ]; then
    [ "$alb" = 1 ] && ok "eks: aws-load-balancer-controller present" || bad "eks: aws-load-balancer-controller missing"
    [ "$(yq -r '.spec.source.helm.valuesObject.imagePullSecrets[0].name' "$reg/components/infrared.yaml")" = infrared-pull ] \
      || bad "eks: imagePullSecrets not rendered into the infrared Application"
  else
    [ "$alb" = 0 ] && ok "k3s: aws-load-balancer-controller absent" || bad "k3s: aws-load-balancer-controller rendered"
    [ "$(yq -r '.spec.source.helm.valuesObject.imagePullSecrets | length' "$reg/components/infrared.yaml")" = 0 ] \
      || bad "k3s: imagePullSecrets should be empty"
  fi

  # Kustomize builds.
  mkdir -p "$work/$flavor-built"
  for k in "$out"/components/*/kustomization.yaml; do
    d="$(dirname "$k")"; name="$(basename "$d")"
    if kubectl kustomize "$d" > "$work/$flavor-built/$name.yaml"; then :; else bad "$flavor: kustomize build components/$name"; fi
  done

  # Schemas.
  if kubeconform -strict -ignore-missing-schemas -summary \
      -schema-location default \
      -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
      "$reg" "$work/$flavor-built"; then
    ok "$flavor: kubeconform"
  else
    bad "$flavor: kubeconform"
  fi
  ok "$flavor: rendered and checked ($(find "$out" -type f | wc -l | tr -d ' ') files)"
done

if [ "$fail" -ne 0 ]; then echo "verify: FAILED" >&2; exit 1; fi
echo "verify: all checks passed"
