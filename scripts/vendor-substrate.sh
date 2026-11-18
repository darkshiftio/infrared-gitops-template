#!/usr/bin/env bash
# =============================================================================
# Vendor Agent Substrate's install manifests into the template.
# =============================================================================
# Substrate's own installer (cmd/ate-setup) applies manifests/ate-install with
# client-go, after it has made the CA Secrets, the API's settings and the
# Postgres roles. Here the same manifests arrive through Argo CD instead, so
# they are committed, pinned to the release in scripts/substrate-images.json:
# upstream's tag, the commit it names, and each image upstream published for it
# (ghcr.io/agent-substrate/substrate/<image>:<tag>, linux/amd64 and
# linux/arm64), by digest. Darkshift builds none of them.
#
#   - each `ko://go.ate.dev/substrate/<package>` image becomes that package's
#     published image, tag and digest, and ${ENVOY_DATAPLANE_IMAGE} the
#     envoy-dataplane image's, as ate-setup's prebuilt install maps them
#     (cmd/ate-setup/internal/images);
#   - the markers ate-setup splices are rendered as ate-setup renders them for
#     this install: #ATE_EGRESS_INJECT_FLAGS is removed, which is what its
#     --credential-provider '{"enabled":false}' does, so the egress gateway has
#     no credential provider and denies any rule that would inject a
#     credential; #ATE_MITM_EXTPROC_FILTER and #ATE_MITM_EXTPROC_CLUSTER stay
#     the inert comments they are without an additional egress ext_proc. Any
#     other marker, a ${...} placeholder or a ko:// reference left fails the
#     run, so a new one upstream adds is decided here, not shipped by accident;
#   - each file is wrapped in the template's guard, so it renders to a comment
#     unless Substrate is on (Stores, SubstrateCapable and Registry).
#
# Left out on purpose: base/kustomization.yaml (components/substrate composes
# its own), atenet-router-monitoring.yaml (GKE Managed Prometheus only),
# ate-otel-config.yaml (it names GKE's collector; components/substrate has its
# own), ate-system-namespace.yaml (Argo CD makes the namespaces),
# ate-system-networkpolicies.yaml (components/substrate has its own, narrower
# ones), postgres/ (the platform's one Postgres instead),
# sandboxconfig-microvm.yaml.tmpl (gVisor only), egress-credential-injection/
# (no credential provider) and the kind, agentgateway and cloudsql overlays.
# Everything this install changes in the vendored files is a patch in the
# component's kustomization.yaml, never an edit here.
#
# TO BUMP SUBSTRATE (upstream supports no move between incompatible releases,
# and none between minor releases it skips: read its upgrade guide first):
#   1. set .substrate.tag and .substrate.ref (the commit the tag names) in
#      scripts/substrate-images.json, and .tag to the same tag
#   2. run `scripts/vendor-substrate.sh --pin`: it checks the tag names that
#      commit, takes each image's digest at the tag from the registry,
#      anonymously, checks each is an index for linux/amd64 and linux/arm64,
#      writes the digests to the pins, then vendors the manifests
#   3. `make verify`, and read the diff of every vendored file
#   4. an install whose SubstrateRegistry is set pulls Substrate's images from
#      there: copy each pinned image there by digest before its pin moves
# Without --pin it vendors from the pins as they are.
# Needs: curl, jq, shasum; with --pin also git and crane.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

pins=scripts/substrate-images.json
repo="$(jq -r .substrate.repo "$pins")"
ref="$(jq -r .substrate.ref "$pins")"
tag="$(jq -r .substrate.tag "$pins")"
registry="$(jq -r .registry "$pins")"
[[ "$repo" == https://github.com/agent-substrate/substrate ]] || { echo "unexpected repo $repo" >&2; exit 1; }
[[ "$registry" == ghcr.io/agent-substrate/substrate ]] || { echo "unexpected registry $registry" >&2; exit 1; }
[[ "$ref" =~ ^[0-9a-f]{40}$ ]] || { echo "the ref must be a full commit, got $ref" >&2; exit 1; }
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "the tag must be a release, vX.Y.Z, got $tag" >&2; exit 1; }
[[ "$(jq -r .tag "$pins")" == "$tag" ]] || { echo ".tag and .substrate.tag differ" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [ "${1:-}" = --pin ]; then
  # The tag must name the commit the manifests come from: the images were built
  # from it.
  peeled="$(git ls-remote "$repo" "refs/tags/$tag^{}" | awk '{print $1}')"
  [ "$peeled" = "$ref" ] || { echo "upstream's $tag names ${peeled:-nothing}, not $ref" >&2; exit 1; }
  # Anonymous reads: a public registry, and no credential of this machine's.
  mkdir "$work/docker"
  export DOCKER_CONFIG="$work/docker"
  cp "$pins" "$work/pins.json"
  for name in $(jq -r '.images | keys[]' "$pins"); do
    image="$registry/$name:$tag"
    index="$(crane manifest "$image")"
    platforms="$(jq -r '[.manifests[]?.platform | select(.os != "unknown") | .os + "/" + .architecture] | sort | join(",")' <<<"$index")"
    [ "$(jq -r .mediaType <<<"$index")" = application/vnd.oci.image.index.v1+json ] && [ "$platforms" = linux/amd64,linux/arm64 ] \
      || { echo "$image is not an index for linux/amd64 and linux/arm64 (got $platforms)" >&2; exit 1; }
    digest="$(crane digest "$image")"
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "$image: no digest" >&2; exit 1; }
    jq --arg n "$name" --arg r "$image@$digest" '.images[$n].ref = $r' "$work/pins.json" >"$work/pins.next"
    mv "$work/pins.next" "$work/pins.json"
    echo "pinned $image@$digest"
  done
  cp "$work/pins.json" "$pins"
fi

# Every image the manifests can name is pinned, at the tag, by digest.
bad_pins="$(jq -r --arg reg "$registry" --arg tag "$tag" '.images | to_entries[] | .key as $k
  | select((.value.ref | startswith($reg + "/" + $k + ":" + $tag + "@sha256:") and test("@sha256:[0-9a-f]{64}$")) | not) | $k' "$pins")"
[ -z "$bad_pins" ] || { echo "not pinned at $tag by digest: $bad_pins (run with --pin)" >&2; exit 1; }

raw="https://raw.githubusercontent.com/agent-substrate/substrate/$ref/manifests/ate-install"

guard_on='[[- if and .Stores .SubstrateCapable .Registry -]]'
guard_off='[[- else -]]
# Agent Substrate runs only where the operator'"'"'s preflight found the cluster able
# to host it (SubstrateCapable), with the platform'"'"'s own stores (INFRARED_STORES)
# and the registry inside the cluster (INFRARED_REGISTRY), so this file holds no
# objects.
[[- end ]]'

# markers <file>: the lines ate-setup splices at, by marker, one a line.
markers() { sed -n -E 's/^[[:space:]]*(#ATE_[A-Z_]+).*/\1/p' "$1"; }

# vendor <output, under template/components> <upstream file>...: fetch, pin,
# render the markers, wrap, write.
vendor() {
  local out="template/components/$1" f sums="" body="$work/body" known
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
  # The markers. No credential provider: the injection marker goes, once.
  if markers "$body" | grep -qx '#ATE_EGRESS_INJECT_FLAGS'; then
    [ "$(markers "$body" | grep -cx '#ATE_EGRESS_INJECT_FLAGS')" = 1 ] || { echo "$out: #ATE_EGRESS_INJECT_FLAGS more than once" >&2; exit 1; }
    sed -i.bak -E '/^[[:space:]]*#ATE_EGRESS_INJECT_FLAGS/d' "$body"
  fi
  known='^#ATE_MITM_EXTPROC_(FILTER|CLUSTER)$'
  if markers "$body" | grep -vE "$known"; then
    echo "$out: a marker this script does not render (above)" >&2
    exit 1
  fi
  if grep -nE 'ko://|\$\{[A-Za-z_]+\}' "$body"; then
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
    printf '# Agent Substrate %s (%s), manifests/ate-install, images %s:%s by digest.\n' "$tag" "${ref:0:7}" "$registry" "$tag"
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
for f in ate-api-server ate-idp-server ate-controller atelet atenet-router atenet-egress sandboxconfig-gvisor; do
  vendor "substrate/$f.yaml.tmpl" "$f.yaml"
done
echo "Substrate $tag (${ref:0:7}), images $registry:$tag"
