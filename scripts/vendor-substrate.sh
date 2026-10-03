#!/usr/bin/env bash
# =============================================================================
# Vendor Agent Substrate's install manifests into the template.
# =============================================================================
# Substrate's own installer (cmd/ate-setup) applies manifests/ate-install with
# client-go, builds every image with ko, makes the CA Secrets and labels the
# nodes. Here the same manifests arrive through Argo CD instead, so they are
# committed, pinned, from the commit and the images in
# scripts/substrate-images.json:
#
#   - each `ko://github.com/agent-substrate/substrate/<package>` image becomes
#     that package's published image, tag and digest, and ${ENVOY_DATAPLANE_IMAGE}
#     the envoy-dataplane image's;
#   - ${SUBSTRATE_VERSION} becomes the images' version and
#     ${SUBSTRATE_VERSION_SUFFIX} its object-name suffix, as ate-setup's
#     SubstituteVersion does (cmd/ate-setup/internal/steps/version.go);
#   - each file is wrapped in the template's guard, so it renders to a comment
#     unless Substrate is on (Stores, SubstrateCapable and Registry).
#
# Left out on purpose: base/kustomization.yaml (components/substrate composes
# its own), atenet-router-monitoring.yaml (GKE Managed Prometheus only),
# ate-otel-config.yaml (it names GKE's collector; components/substrate has its
# own), ate-system-namespace.yaml (Argo CD makes the namespaces), postgres/ (the
# platform's one Postgres instead) and the kind and agentgateway overlays.
# Everything this install changes in the vendored files is a patch in the
# component's kustomization.yaml, never an edit here.
#
# TO BUMP SUBSTRATE:
#   1. publish the images from the new commit, with the patch the old ones
#      carried, and copy the map of their digests (substrate-images.json) over
#      scripts/substrate-images.json
#   2. run this script, then `make verify`
#   3. bump each ActorTemplate's version in its name
#      (components/substrate-actors/templates.yaml): templates are immutable
# Needs: curl, jq, shasum.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

pins=scripts/substrate-images.json
repo="$(jq -r .substrate.repo "$pins")"
ref="$(jq -r .substrate.ref "$pins")"
version="$(jq -r .version "$pins")"
[[ "$repo" == https://github.com/agent-substrate/substrate ]] || { echo "unexpected repo $repo" >&2; exit 1; }
[[ "$ref" =~ ^[0-9a-f]{40}$ ]] || { echo "the ref must be a full commit, got $ref" >&2; exit 1; }
# A label value: the nodes carry it, and the atelet DaemonSet selects on it.
[[ ${#version} -le 63 && "$version" =~ ^[A-Za-z0-9]([-A-Za-z0-9_.]*[A-Za-z0-9])?$ ]] \
  || { echo "version $version is not a label value" >&2; exit 1; }
# versionlabel.NameSuffix: lower case, every other character a dash, no dash at
# either end, at most 30 characters (else v and 10 hex of its sha256).
suffix="$(tr '[:upper:]' '[:lower:]' <<<"$version" | sed -E 's/[^a-z0-9]/-/g; s/^-+//; s/-+$//')"
if [ -z "$suffix" ] || [ "${#suffix}" -gt 30 ]; then
  suffix="v$(printf '%s' "$version" | shasum -a 256 | cut -c1-10)"
fi

raw="https://raw.githubusercontent.com/agent-substrate/substrate/$ref/manifests/ate-install"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

guard_on='[[- if and .Stores .SubstrateCapable .Registry -]]'
guard_off='[[- else -]]
# Agent Substrate runs only where the operator'"'"'s preflight found the cluster able
# to host it (SubstrateCapable), with the platform'"'"'s own stores (INFRARED_STORES)
# and the registry inside the cluster (INFRARED_REGISTRY), so this file holds no
# objects.
[[- end ]]'

# vendor <output, under template/components> <upstream file>...: fetch, pin,
# wrap, write.
vendor() {
  local out="template/components/$1" f sums="" body="$work/body"
  shift
  : >"$body"
  for f in "$@"; do
    curl -fsSL "$raw/$f" -o "$work/upstream"
    sums="$sums#   $f  $(shasum -a 256 "$work/upstream" | awk '{print $1}')"$'\n'
    [ -s "$body" ] && printf '\n---\n' >>"$body"
    cat "$work/upstream" >>"$body"
  done
  # ko references: each image's package path, from the pins. sed -i.bak is
  # read the same by GNU and BSD sed; the copies stay in $work.
  while IFS=$'\t' read -r ko image; do
    sed -i.bak "s#${ko}\$#${image}#" "$body"
  done < <(jq -r '.images[] | select(.ko != null) | [.ko, .ref] | @tsv' "$pins")
  sed -i.bak "s#\${ENVOY_DATAPLANE_IMAGE}#$(jq -r '.images["envoy-dataplane"].ref' "$pins")#" "$body"
  # An unquoted ${SUBSTRATE_VERSION} scalar is quoted first, so a version of
  # digits stays a string.
  # shellcheck disable=SC2016 # the placeholder is literal text
  sed -E -i.bak 's|^([[:space:]]*[^:[:space:]][^:]*): \$\{SUBSTRATE_VERSION\}$|\1: "${SUBSTRATE_VERSION}"|' "$body"
  sed -i.bak -e "s#\${SUBSTRATE_VERSION_SUFFIX}#$suffix#g" -e "s#\${SUBSTRATE_VERSION}#$version#g" "$body"
  if grep -nE 'ko://|\$\{(SUBSTRATE|ENVOY)_' "$body"; then
    echo "$out: a placeholder is left (above)" >&2
    exit 1
  fi
  if grep -nE '\[\[|\]\]' "$body"; then
    echo "$out: upstream text holds the template's delimiters (above)" >&2
    exit 1
  fi
  {
    printf '%s\n' "$guard_on"
    printf '# GENERATED by scripts/vendor-substrate.sh from scripts/substrate-images.json: do not edit.\n'
    printf '# Agent Substrate %s, manifests/ate-install, images %s (version %s).\n' "${ref:0:7}" "$(jq -r .tag "$pins")" "$version"
    printf '# source: %s\n# sha256 of each upstream file:\n%s' "$raw" "$sums"
    cat "$body"
    printf '\n%s\n' "$guard_off"
  } >"$out"
  echo "wrote $out ($(grep -c '^kind:' "$out") objects)"
}

vendor substrate-crds/crds.yaml.tmpl \
  generated/ate.dev_workerpools.yaml generated/ate.dev_sandboxconfigs.yaml generated/ate.dev_csidriverconfigs.yaml
vendor substrate-crds/sandboxconfig-validation.yaml.tmpl sandboxconfig-validation.yaml
vendor substrate-podcert/pod-certificate-controller.yaml.tmpl pod-certificate-controller.yaml
vendor substrate/role.yaml.tmpl generated/role.yaml
for f in ate-api-server ate-controller atelet atenet-router atenet-egress sandboxconfig-gvisor; do
  vendor "substrate/$f.yaml.tmpl" "$f.yaml"
done
echo "Substrate ${ref:0:7}, version $version (object suffix $suffix)"
