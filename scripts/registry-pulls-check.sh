#!/usr/bin/env bash
# =============================================================================
# registry-pulls-check.sh <kube context> <org> <another org>: pulls by identity
# hold on a running install (infrared-docs-internal ADR 0066 D3; README "The
# registry").
# =============================================================================
# With the registry by identity on (the Infrared chart's
# tenancy.registryPulls.enabled), this passes when:
#
#   1. Zot's config (registry/zot-config, which the operator writes) reads for
#      no one under "**", lets every signed-in user read platform/**, and gives
#      each org's path to its own users alone: its user, and its pull user,
#      <org>_pull, which reads there and does nothing else; no rule lets a
#      user that only reads (<org>_pull, platform_reader) do more (workspace
#      TODO 789);
#   2. through a port-forward, an anonymous read of <org>'s image is refused
#      (401), <another org>'s user reading it is refused (403), and <org>'s
#      own user reads it;
#   3. every zone of <org> on this cluster holds the Secret zot-pull, of <org>,
#      signing in as <org>_pull and listed on its default ServiceAccount, and no
#      zone of <another org> holds <org>'s;
#   4. a pod in <org>'s zone runs <org>'s image with imagePullPolicy Always,
#      and a pod in <another org>'s zone naming it cannot pull it; nor, on the
#      node that holds it already, with IfNotPresent (the kubelet asks the
#      registry with the pod's own credential before it runs an image another
#      credential pulled: KubeletEnsureSecretPulledImages);
#   5. no pod in any zone is stuck pulling the registry's image without
#      zot-pull, as a pod made before its zone's account listed it would be;
#   6. the logins that only read push nowhere (workspace TODO 789): a push as
#      zot-pull's user, under <org>'s image's repository, and as
#      kpack/registry-pull's (platform_reader), under the builder's, is refused
#      (403), and each reads its image (200). The push is the operator's probe:
#      a manifest PUT of a media type Zot refuses with 415 once it has let the
#      push through, so nothing is stored either way.
#
# <org>'s image is the one a running pod of its zones runs, and the builder the
# ClusterBuilder infrared-builder's latest. The orgs' passwords go from
# builds/registry-push-<org>, and the logins that only read from zot-pull and
# kpack/registry-pull, to curl on stdin, through the port-forward, and are
# never printed. Its pods are removed unless KEEP=1.
# Runs against a cluster, never from CI: the hosted plane after the install,
# before a tenant, with the owner's go-ahead.
# Needs: kubectl, jq, curl. Reads the ClusterBuilder infrared-builder. Applies
# pods in the two orgs' zones only, on the tenants' placement (nodeSelector,
# tolerations, runtimeClassName) where the install's admission policy
# infrared-tenancy-pods demands it (ADR 0066 D5), read from the operator's
# INFRARED_TENANT_PODS; none on an install without.
# =============================================================================
set -euo pipefail
CTX="${1:?usage: scripts/registry-pulls-check.sh <kube context> <org> <another org>}"
ORG="${2:?usage: scripts/registry-pulls-check.sh <kube context> <org> <another org>}"
OTHER="${3:?usage: scripts/registry-pulls-check.sh <kube context> <org> <another org>}"
ACCEPT='application/vnd.oci.image.manifest.v1+json,application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.docker.distribution.manifest.list.v2+json'

k() { kubectl --context "$CTX" "$@"; }

# The tenants' placement (tenancy.tenantPods.placement, read from the operator's INFRARED_TENANT_PODS): where the
# admission policy infrared-tenancy-pods demands it (ADR 0066 D5), a probe pod carries it, as a zone's pod does.
# Empty on an install without one (kind).
placement_yaml() {
  k -n "${INFRARED_NS:-infrared}" get deployment infrared-operator -o json 2>/dev/null |
    jq -r '.spec.template.spec.containers[0].env[]? | select(.name == "INFRARED_TENANT_PODS") | .value // empty' |
    jq -r 'try (.placement // {}) catch {} | [(if .nodeSelector then "  nodeSelector: " + (.nodeSelector | tojson) else empty end), (if .tolerations then "  tolerations: " + (.tolerations | tojson) else empty end), (if .runtimeClassName then "  runtimeClassName: " + .runtimeClassName else empty end)] | join("\n")' 2>/dev/null || true
}
PLACEMENT_YAML="$(placement_yaml)"
log() { printf '\n== %s\n' "$*"; }
die() {
  echo "registry-pulls-check: $*" >&2
  exit 1
}
fails=0
pass() { echo "  ok    $*"; }
fail() {
  echo "  FAIL  $*"
  fails=$((fails + 1))
}

for t in kubectl jq curl; do command -v "$t" >/dev/null || die "missing tool: $t"; done
k get --raw /readyz >/dev/null 2>&1 || die "context $CTX does not answer"
REG="$(k -n registry get service zot -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}' 2>/dev/null)" ||
  die "no registry on $CTX (registry/zot)"

stamp="$(date -u +%Y%m%d-%H%M%S)"
pods=()
pf=""
cleanup() {
  local p
  if [ -n "$pf" ]; then kill "$pf" 2>/dev/null || true; fi
  [ "${KEEP:-}" = 1 ] && return
  for p in "${pods[@]+"${pods[@]}"}"; do
    k -n "${p%%/*}" delete pod "${p#*/}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

# zones <org>: the org's zones on this cluster, namespaces with its label and
# a zone's.
zones() { k get namespaces -l "infrared.darkshift.io/org=$1,infrared.darkshift.io/zone" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true; }
org_zones="$(zones "$ORG")"
other_zones="$(zones "$OTHER")"
[ -n "$org_zones" ] || die "org $ORG has no zone on $CTX (a namespace labelled infrared.darkshift.io/org=$ORG and infrared.darkshift.io/zone)"
[ -n "$other_zones" ] || die "org $OTHER has no zone on $CTX"

log "1. Zot's rules"
cfg="$(k -n registry get secret zot-config -o jsonpath='{.data.config\.json}' | base64 -d)"
rules() { jq -c -S ".http.accessControl.repositories[\"$1\"] | {anonymousPolicy, defaultPolicy, users: [.policies[]?.users[]]}" <<<"$cfg"; }
# may <pattern> <user>: what <pattern>'s rule lets <user> do, sorted and comma-joined.
may() { jq -r --arg p "$1" --arg u "$2" '[.http.accessControl.repositories[$p].policies[]? | select(.users | index($u)) | .actions[]] | unique | join(",")' <<<"$cfg"; }
[ "$(rules '**')" = '{"anonymousPolicy":[],"defaultPolicy":[],"users":[]}' ] &&
  pass '"**" reads for no one' || fail "\"**\" is $(rules '**'): the registry still reads for others (tenancy.registryPulls off?)"
[ "$(rules 'platform/**')" = '{"anonymousPolicy":[],"defaultPolicy":["read"],"users":["platform"]}' ] &&
  pass "platform/** reads for every signed-in user, and platform alone writes" || fail "platform/** is $(rules 'platform/**')"
for o in "$ORG" "$OTHER"; do
  [ "$(rules "$o/**")" = "{\"anonymousPolicy\":[],\"defaultPolicy\":[],\"users\":[\"$o\",\"${o}_pull\"]}" ] &&
    pass "$o/** is $o's and ${o}_pull's alone" || fail "$o/** is $(rules "$o/**")"
  [ "$(may "$o/**" "${o}_pull")" = read ] &&
    pass "${o}_pull reads $o/** and does nothing else there" || fail "${o}_pull may '$(may "$o/**" "${o}_pull")' under $o/**"
done
# No rule lets a user that only reads do more than read, and the adminPolicy names none.
over="$(jq -r '[.http.accessControl.repositories | to_entries[] | .key as $k | .value.policies[]?
  | select(any(.users[]; endswith("_pull") or . == "platform_reader")) | select(any(.actions[]; . != "read")) | $k] | unique | join(" ")' <<<"$cfg")"
admin="$(jq -r '[.http.accessControl.adminPolicy.users[]? | select(endswith("_pull") or . == "platform_reader")] | join(" ")' <<<"$cfg")"
[ -z "$over$admin" ] && pass "no rule lets a user that only reads do more than read" ||
  fail "a user that only reads may do more under: ${over:-none}; adminPolicy: ${admin:-none}"

log "2. reads, through a port-forward"
# The image a running pod of the org's zones runs, and the node it is on.
image="" node=""
for z in $org_zones; do
  read -r image node < <(k -n "$z" get pods -o json | jq -r --arg reg "$REG/$ORG/" \
    '[.items[] | select(.status.phase == "Running") | . as $p | .spec.containers[] | select(.image | startswith($reg)) | "\(.image) \($p.spec.nodeName)"][0] // ""') || true
  [ -n "$image" ] && break
done
[ -n "$image" ] || die "no running pod of $ORG's zones runs an image from $REG/$ORG/: release one first"
repo="${image#"$REG"/}"
repo="${repo%@*}"
repo="${repo%:*}"
digest="${image##*@}"
case "$digest" in sha256:*) ;; *) die "$image is not pinned by digest" ;; esac
port=$((20000 + RANDOM % 20000))
k -n registry port-forward service/zot "$port:${REG##*:}" >/dev/null 2>&1 &
pf=$!
for _ in $(seq 1 30); do curl -s -o /dev/null "http://127.0.0.1:$port/v2/" && break || sleep 1; done
# read_as <org or empty>: the status of a manifest read of <org>'s image, as
# that org's user (its password on stdin), or anonymously.
read_as() {
  local url="http://127.0.0.1:$port/v2/$repo/manifests/$digest"
  if [ -z "$1" ]; then
    curl -s -o /dev/null -w '%{http_code}' -I -H "Accept: $ACCEPT" "$url"
    return
  fi
  local user pw
  user="$(k -n builds get secret "registry-push-$1" -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq -r '[.auths[]][0].username')"
  pw="$(k -n builds get secret "registry-push-$1" -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq -r '[.auths[]][0].password')"
  printf 'user = "%s:%s"\n' "$user" "$pw" | curl -s -o /dev/null -w '%{http_code}' -I -H "Accept: $ACCEPT" -K - "$url"
}
[ "$(read_as "")" = 401 ] && pass "an anonymous read of $repo is refused (401)" || fail "an anonymous read of $repo answered $(read_as "")"
[ "$(read_as "$OTHER")" = 403 ] && pass "$OTHER's user reading $repo is refused (403)" || fail "$OTHER's user reading $repo answered $(read_as "$OTHER")"
[ "$(read_as "$ORG")" = 200 ] && pass "$ORG's user reads $repo" || fail "$ORG's user reading $repo answered $(read_as "$ORG")"

log "3. the zones' pull credentials"
# login <namespace> <secret> <field>: a field, username or password, of the
# Secret's one registry login; the script prints a username alone.
login() {
  k -n "$1" get secret "$2" -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 -d |
    jq -r --arg f "$3" '[.auths[]][0][$f] // empty' 2>/dev/null || true
}
for z in $org_zones; do
  [ "$(k -n "$z" get secret zot-pull -o jsonpath='{.metadata.labels.infrared\.darkshift\.io/org}' 2>/dev/null)" = "$ORG" ] &&
    pass "$z holds $ORG's zot-pull" || fail "$z holds no zot-pull of $ORG"
  user="$(login "$z" zot-pull username)"
  [ "$user" = "${ORG}_pull" ] && pass "$z's zot-pull signs in as ${ORG}_pull" ||
    fail "$z's zot-pull signs in as '$user', not ${ORG}_pull (the operator swaps it once Zot knows ${ORG}_pull)"
  k -n "$z" get serviceaccount default -o json | jq -e '[.imagePullSecrets[]?.name] | index("zot-pull")' >/dev/null &&
    pass "$z's default ServiceAccount lists it" || fail "$z's default ServiceAccount does not list zot-pull"
done
for z in $other_zones; do
  owner="$(k -n "$z" get secret zot-pull -o jsonpath='{.metadata.labels.infrared\.darkshift\.io/org}' 2>/dev/null || true)"
  [ "$owner" != "$ORG" ] && pass "$z holds no credential of $ORG" || fail "$z, $OTHER's zone, holds $ORG's credential"
done

log "4. pulls, by the nodes"
other_zone="${other_zones%% *}"
org_zone="${org_zones%% *}"
# pull_pod <namespace> <name> <policy> [node]: a pod running the image, as a
# zone's pod runs; prints Running, or the reason it waits.
pull_pod() {
  local ns=$1 name="registry-pulls-check-$2-$stamp" policy=$3 on=${4:-} state=""
  pods+=("$ns/$name")
  k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $name
  namespace: $ns
  labels:
    app.kubernetes.io/part-of: registry-pulls-check
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
$PLACEMENT_YAML
  ${on:+nodeName: $on}
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: $image
      imagePullPolicy: $policy
      command: ["/bin/sh", "-c", "sleep 30"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
EOF
  local deadline=$((SECONDS + 180))
  while [ "$SECONDS" -lt "$deadline" ]; do
    state="$(k -n "$ns" get pod "$name" -o jsonpath='{.status.containerStatuses[0].state}' 2>/dev/null || true)"
    case "$state" in
      *running* | *terminated*) echo Running && return ;;
      *ErrImagePull* | *ImagePullBackOff*) jq -r '.waiting.reason' <<<"$state" && return ;;
    esac
    sleep 3
  done
  echo "neither ran nor failed to pull in 180s"
}
got="$(pull_pod "$org_zone" own Always)"
[ "$got" = Running ] && pass "a pod of $ORG's zone $org_zone runs $repo, pulled with zot-pull" || fail "a pod of $ORG's zone: $got"
got="$(pull_pod "$other_zone" other Always)"
case "$got" in ErrImagePull | ImagePullBackOff) pass "a pod of $OTHER's zone $other_zone cannot pull $repo ($got)" ;; *) fail "a pod of $OTHER's zone pulling $repo: $got" ;; esac
got="$(pull_pod "$other_zone" cached IfNotPresent "$node")"
case "$got" in
  ErrImagePull | ImagePullBackOff) pass "nor on $node, which holds it, with IfNotPresent: the kubelet asks with the pod's credential ($got)" ;;
  *) fail "a pod of $OTHER's zone on $node, which holds $repo, with IfNotPresent: $got (the kubelet runs another credential's image)" ;;
esac

log "5. no pod stuck without the credential"
stuck=""
for z in $(k get namespaces -l infrared.darkshift.io/zone -o jsonpath='{.items[*].metadata.name}'); do
  stuck="$stuck$(k -n "$z" get pods -o json | jq -r --arg reg "$REG/" '.items[]
    | select(any(.status.containerStatuses[]?; .state.waiting.reason == "ErrImagePull" or .state.waiting.reason == "ImagePullBackOff"))
    | select(any(.spec.containers[]; .image | startswith($reg)))
    | select([.spec.imagePullSecrets[]?.name] | index("zot-pull") | not)
    | select(.metadata.labels["app.kubernetes.io/part-of"] != "registry-pulls-check")
    | " " + .metadata.namespace + "/" + .metadata.name')"
done
[ -z "$stuck" ] && pass "none" || fail "stuck without zot-pull, delete each and its controller makes it again with it:$stuck"

log "6. the logins that only read"
# probe_as <namespace> <secret> <PUT or HEAD> <repository> <reference>: what Zot
# answers the Secret's login. PUT is the operator's push probe, a manifest of a
# media type Zot refuses with 415 once it has let the push through, so nothing
# is stored; HEAD is a manifest read.
probe_as() {
  local user pw url="http://127.0.0.1:$port/v2/$4/manifests/$5"
  user="$(login "$1" "$2" username)"
  pw="$(login "$1" "$2" password)"
  if [ "$3" = PUT ]; then
    printf 'user = "%s:%s"\n' "$user" "$pw" | curl -s -o /dev/null -w '%{http_code}' -X PUT \
      -H 'Content-Type: application/vnd.darkshift.infrared.probe' --data-binary '{}' -K - "$url"
  else
    printf 'user = "%s:%s"\n' "$user" "$pw" | curl -s -o /dev/null -w '%{http_code}' -I -H "Accept: $ACCEPT" -K - "$url"
  fi
}
zone="${org_zones%% *}"
user="$(login "$zone" zot-pull username)"
got="$(probe_as "$zone" zot-pull PUT "$repo" registry-pulls-check)"
[ "$got" = 403 ] && pass "a push as $zone's zot-pull user, $user, under $repo is refused (403)" ||
  fail "a push as $zone's zot-pull user, $user, under $repo answered $got (415: Zot let it through)"
got="$(probe_as "$zone" zot-pull HEAD "$repo" "$digest")"
[ "$got" = 200 ] && pass "$user reads $repo" || fail "$user reading $repo answered $got"
builder="$(k get clusterbuilder infrared-builder -o jsonpath='{.status.latestImage}' 2>/dev/null || true)"
case "$builder" in
  "$REG"/platform/*@sha256:*)
    # <registry>/platform/...kpack-builder:<tag>@sha256:<digest>: the repository alone.
    brepo="${builder#"$REG"/}"
    brepo="${brepo%@*}"
    brepo="${brepo%:*}"
    user="$(login kpack registry-pull username)"
    [ "$user" = platform_reader ] && pass "kpack/registry-pull signs in as platform_reader" ||
      fail "kpack/registry-pull signs in as '$user', not platform_reader"
    got="$(probe_as kpack registry-pull PUT "$brepo" registry-pulls-check)"
    [ "$got" = 403 ] && pass "a push as kpack/registry-pull's user under $brepo is refused (403)" ||
      fail "a push as kpack/registry-pull's user under $brepo answered $got (415: Zot let it through)"
    got="$(probe_as kpack registry-pull HEAD "$brepo" "${builder##*@}")"
    [ "$got" = 200 ] && pass "platform_reader reads $brepo" || fail "platform_reader reading $brepo answered $got"
    ;;
  *) fail "the ClusterBuilder infrared-builder's latest image is '$builder', not one under $REG/platform/ by digest" ;;
esac

if [ "$fails" -ne 0 ]; then
  echo "registry-pulls-check: FAILED ($fails check(s))" >&2
  exit 1
fi
echo "registry-pulls-check: pulls by identity hold"
