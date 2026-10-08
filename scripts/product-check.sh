#!/usr/bin/env bash
# =============================================================================
# product-check.sh <kube context> <organization> <token file>: a Product made
# from a starter zip is built, released and promoted, and its zone answers over
# HTTPS behind sign-in, with nothing made by hand and no agent run.
# =============================================================================
# Runs against an install whose Installation has a Gateway edge and previews
# (spec.edge gateway, spec.previews), never from CI. It does what a person does
# in the UI, through Infrared's API at the Installation's sign-in URL, with the
# bearer token in <token file>:
#
#   1. creates a private repo in the organization's forge and commits a starter
#      zip to it: one index.html that carries a random marker;
#   2. creates a Product on that repo, delivered from Infrared's scaffold, as
#      the UI does; the API gives it one pre-release zone, <product>-rc, with a
#      preview address and a smoke check;
#   3. waits for Infrared to scaffold the build, the chart and the zone into the
#      gitops repo, with the products AppProject when the repo has none, and to
#      start the first Release; then for Argo CD to sync the Product's
#      Applications;
#   4. waits for kpack to build the repo and push the image to the registry
#      inside the cluster, under <organization>/<product>, as the
#      organization's builder;
#   5. waits for the Release to tag the image, pin the zone to it by digest and
#      promote it there: the zone runs it Healthy, and its smoke check passes;
#   6. asks https://<product>-rc.<domain>/ without a cookie, which sends it to
#      Infrared's sign-in; opens the preview there with the token, which hands
#      back a pass for that host; trades the pass for the preview's cookie; and
#      with the cookie gets 200: the starter's page with its marker, uncached;
#   7. reads the Product's links: the zone's address, from its HTTPRoute;
#   8. checks that nothing was made by hand: the zone is served by the edge's
#      Gateway on its wildcard name and certificate, with no DNS record or
#      certificate of its own; the build pushed with the organization's
#      credential, which Infrared made; and no AgentWorkflowRun started, so no
#      agent ran and nothing was spent.
#
# Each step prints how long it took. Then, unless KEEP=1, it removes what it
# made: the Product (Infrared then removes its gitops files, its Applications,
# the zone's namespace and its ReferenceGrant), its Release, its repo (on Gitea,
# as Gitea's site admin) and its images (as the registry's admin user
# infrared). The products AppProject stays, and so does the Product's
# destination in it: Infrared adds one for each Product and removes none.
# KEEP=1 leaves the Product and its zone running, and REMOVE=<product> removes
# such a Product later. Either way it touches only names this check makes,
# product-check-<MMDDhhmmss>, and only a Product that says the check made it.
#
# The token goes only to Infrared's API, from the file into curl's config on
# stdin. No token, password, pass or cookie is printed.
# Needs: kubectl, jq, curl, zip.
# =============================================================================
set -euo pipefail
usage='usage: [KEEP=1] scripts/product-check.sh <kube context> <organization> <token file>
       REMOVE=<product> scripts/product-check.sh <kube context> <organization> <token file>'
CTX="${1:?$usage}"
ORG="${2:?$usage}"
TOKEN_FILE="${3:?$usage}"
# The Product's and the repo's description: remove() takes only what says this.
MADE_BY="Made by the Product check (infrared-gitops-template scripts/product-check.sh). Safe to delete."
ACCEPT='application/vnd.oci.image.manifest.v1+json,application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.docker.distribution.manifest.list.v2+json'

k() { kubectl --context "$CTX" "$@"; }
log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

for t in kubectl jq curl zip; do command -v "$t" >/dev/null || die "missing tool: $t"; done
[ -s "$TOKEN_FILE" ] || die "no token in $TOKEN_FILE"
k get --raw /readyz >/dev/null 2>&1 || die "context $CTX does not answer"
NS="ir-org-$ORG"
k get namespace "$NS" >/dev/null 2>&1 || die "no organization $ORG on $CTX (namespace $NS)"
inst="$(k get installations.infrared.darkshift.io infrared -o json 2>/dev/null)" || die "no Installation on $CTX"
[ "$(jq -r '.spec.edge // ""' <<<"$inst")" = gateway ] ||
  die "the Installation's spec.edge is not gateway: this check is for a Gateway edge"
DOMAIN="$(jq -r '.spec.previews.domain // ""' <<<"$inst")"
SIGNIN="$(jq -r '.spec.previews.signInURL // "" | rtrimstr("/")' <<<"$inst")"
[ -n "$DOMAIN" ] && [ -n "$SIGNIN" ] || die "the Installation has no previews (spec.previews.domain and signInURL)"
API="$SIGNIN/api"
REG="$(k -n registry get service zot -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}' 2>/dev/null)" ||
  die "no registry on $CTX (registry/zot)"
gp="$(k -n "$NS" get gitproviders.infrared.darkshift.io -o json | jq -c '.items[0] // empty')"
[ -n "$gp" ] || die "org $ORG has no GitProvider"
OWNER="$(jq -r '.spec.owner' <<<"$gp")"

work="$(mktemp -d)"
pfs=""
made=""
cleanup() {
  local rc=$? p
  set +e
  if [ -n "$made" ]; then
    if [ "${KEEP:-}" = 1 ]; then
      echo "KEEP=1: $NAME keeps running; remove it with REMOVE=$NAME scripts/product-check.sh $CTX $ORG <token file>"
    elif ! remove "$NAME"; then
      rc=1
    fi
  fi
  # wait takes each port-forward's end, so bash reports none of them.
  for p in $pfs; do
    kill "$p" 2>/dev/null
    wait "$p" 2>/dev/null
  done
  rm -rf "$work"
  exit "$rc"
}
trap cleanup EXIT

# api <method> <path> [curl args...]: one call to Infrared's API with the
# token, which reaches curl as its config on stdin. Prints the body, then the
# HTTP status on a line of its own.
api() {
  local method=$1 path=$2
  shift 2
  {
    printf 'header = "Authorization: Bearer '
    tr -d '\r\n' <"$TOKEN_FILE" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n'
    printf '"\n'
  } | curl -sS -K - --max-time 120 -X "$method" -w '\n%{http_code}' "$@" "$API$path"
}
code() { printf '%s' "${1##*$'\n'}"; }
body() { printf '%s' "${1%$'\n'*}"; }

# forward <namespace> <service> <port>: a port-forward to the Service on a free
# local port, left in $port.
forward() {
  local out="$work/forward-$2"
  k -n "$1" port-forward "service/$2" ":$3" >"$out" 2>&1 &
  pfs="$pfs $!"
  port=""
  for _ in $(seq 1 30); do
    port="$(awk '/^Forwarding from 127\.0\.0\.1:/ { split($3, a, ":"); print a[2]; exit }' "$out")"
    [ -n "$port" ] && return 0
    sleep 1
  done
  return 1
}

# login <namespace> <secret> <user key> <password key>: curl's config, for
# stdin, that signs in as the user in that Secret.
login() {
  printf 'user = "'
  {
    k -n "$1" get secret "$2" -o jsonpath="{.data.$3}" | base64 -d
    printf ':'
    k -n "$1" get secret "$2" -o jsonpath="{.data.$4}" | base64 -d
  } | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n'
  printf '"\n'
}

# remove <product>: removes a Product this check made, its Releases, its repo
# and its images. Returns 1 when something is left.
remove() {
  local name=$1 left=0 p r repo="$1" gone="" tags tag digests d host gport gsvc gns
  log "removing $name: the Product, its Release, its repo and its images"
  if p="$(k -n "$NS" get products.infrared.darkshift.io "$name" -o json 2>/dev/null)"; then
    if [ "$(jq -r '.spec.description // ""' <<<"$p")" != "$MADE_BY" ]; then
      warn "Product $name does not say this check made it: nothing removed"
      return 1
    fi
    repo="$(jq -r '.spec.repos[0].name' <<<"$p")"
    r="$(api DELETE "/v1/orgs/$ORG/products/$name")" || r=$'\nnone'
    case "$(code "$r")" in 204 | 404) ;; *) warn "the API did not delete Product $name: HTTP $(code "$r") $(body "$r")" ;; esac
    # Infrared removes the zone's files from the gitops repo, then its
    # Applications and namespace, and only then lets the Product go.
    for _ in $(seq 1 120); do
      k -n "$NS" get products.infrared.darkshift.io "$name" >/dev/null 2>&1 || { gone=1; break; }
      sleep 5
    done
    if [ -n "$gone" ]; then
      echo "  ok    Product $name is gone, with its gitops files, Applications and zone namespace"
      if [ -n "$(k get referencegrants.gateway.networking.k8s.io -A -l "infrared.darkshift.io/product=$name" -o name 2>/dev/null)" ]; then
        warn "a ReferenceGrant of $name is left"
        left=1
      fi
    else
      warn "Product $name is still there after 10 minutes: $(k -n "$NS" get products.infrared.darkshift.io "$name" \
        -o jsonpath='{.status.zoneFiles.message}' 2>/dev/null)"
      left=1
    fi
  fi
  # A Release that ran in a zone cannot be dismissed through the API, and the
  # Product's removal leaves it.
  k -n "$NS" delete releases.infrared.darkshift.io -l "infrared.darkshift.io/product=$name" --ignore-not-found >/dev/null ||
    left=1
  echo "  ok    its Releases are deleted"

  # The repo: the API deletes none, so Gitea's site admin does, from the chart's
  # Secret beside Gitea.
  if [ "$(jq -r '.spec.type' <<<"$gp")" != gitea ]; then
    warn "the repo $OWNER/$repo is on GitHub, where this check deletes nothing: delete it by hand"
    left=1
  else
    host="$(jq -r '.spec.gitea.url' <<<"$gp")"
    host="${host#*://}"
    host="${host%%/*}"
    gport="${host##*:}"
    [ "$gport" != "$host" ] || gport=80
    host="${host%%:*}"
    gsvc="${host%%.*}"
    gns="${host#*.}"
    gns="${gns%%.*}"
    if ! forward "$gns" "$gsvc" "$gport"; then
      warn "no port-forward to $gns/$gsvc: the repo $OWNER/$repo is left"
      left=1
    else
      r="$(login "$gns" infrared-gitea-admin username password |
        curl -sS -K - -w '\n%{http_code}' "http://127.0.0.1:$port/api/v1/repos/$OWNER/$repo")" || r=$'\nnone'
      case "$(code "$r")" in
        404) echo "  ok    the repo $OWNER/$repo is gone already" ;;
        200)
          if [ "$(body "$r" | jq -r '.description // ""')" != "$MADE_BY" ]; then
            warn "the repo $OWNER/$repo does not say this check made it: left"
            left=1
          else
            d="$(login "$gns" infrared-gitea-admin username password |
              curl -sS -K - -o /dev/null -w '%{http_code}' -X DELETE "http://127.0.0.1:$port/api/v1/repos/$OWNER/$repo")" || d=none
            if [ "$d" = 204 ]; then echo "  ok    the repo $OWNER/$repo is deleted"; else
              warn "Gitea did not delete $OWNER/$repo: HTTP $d"
              left=1
            fi
          fi
          ;;
        *)
          warn "Gitea did not answer for $OWNER/$repo: HTTP $(code "$r")"
          left=1
          ;;
      esac
    fi
  fi

  # The images: every tag's manifest, as the registry's admin user infrared,
  # whose password the operator keeps in infrared/registry-identities. The
  # registry's garbage collection then frees the blobs.
  if ! forward registry zot "${REG##*:}"; then
    warn "no port-forward to registry/zot: the images under $ORG/$name are left"
    return 1
  fi
  tags="$(curl -sS "http://127.0.0.1:$port/v2/$ORG/$name/tags/list" | jq -r '.tags // [] | .[]' 2>/dev/null || true)"
  digests="$(for tag in $tags; do
    curl -sS -I -H "Accept: $ACCEPT" "http://127.0.0.1:$port/v2/$ORG/$name/manifests/$tag" |
      awk 'tolower($1) == "docker-content-digest:" { print $2 }' | tr -d '\r'
  done | sort -u)"
  for d in $digests; do
    r="$({
      printf 'user = "infrared:'
      k -n infrared get secret registry-identities -o jsonpath='{.data.infrared}' | base64 -d |
        sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n'
      printf '"\n'
    } | curl -sS -K - -o /dev/null -w '%{http_code}' -X DELETE "http://127.0.0.1:$port/v2/$ORG/$name/manifests/$d")" || r=none
    [ "$r" = 202 ] || {
      warn "the registry did not delete $ORG/$name@$d: HTTP $r"
      left=1
    }
  done
  tags="$(curl -sS "http://127.0.0.1:$port/v2/$ORG/$name/tags/list" | jq -r '.tags // [] | .[]' 2>/dev/null || true)"
  if [ -z "$tags" ]; then
    echo "  ok    the images under $ORG/$name are deleted ($(wc -w <<<"$digests" | tr -d ' ') manifests)"
  else
    warn "tags left under $ORG/$name: $(tr '\n' ' ' <<<"$tags")"
    left=1
  fi
  echo "  note  the products AppProject keeps the destination $name-*: Infrared removes none"
  return "$left"
}

if [ -n "${REMOVE:-}" ]; then
  [[ "$REMOVE" =~ ^product-check-[0-9]{10}$ ]] || die "REMOVE takes a Product this check made: product-check-<MMDDhhmmss>"
  NAME="$REMOVE" made=1 KEEP=
  exit 0
fi

me="$(api GET /v1/auth/me)" || die "Infrared's API does not answer at $API"
[ "$(code "$me")" = 200 ] || die "Infrared's API refuses the token in $TOKEN_FILE: HTTP $(code "$me")"
NAME="product-check-$(date -u +%m%d%H%M%S)"
runs_before="$(k get agentworkflowruns.infrared.darkshift.io -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}')"
project_before="$(k -n argocd get appprojects.argoproj.io products -o name 2>/dev/null || true)"
echo "Product $NAME of org $ORG on $CTX, through $API as $(body "$me" | jq -r '"\(.kind) \(.tokenName // .user // "")"')"
t0=$SECONDS

log "1. the repo $OWNER/$NAME, from a starter zip"
t=$SECONDS
marker="$(od -An -N10 -tx1 /dev/urandom | tr -d ' \n')"
mkdir "$work/site"
cat >"$work/site/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Product check</title>
</head>
<body>
<h1>Product check</h1>
<p>Built from a starter zip by Infrared's Product check.</p>
<p id="marker">$marker</p>
</body>
</html>
EOF
(cd "$work/site" && zip -q -X "$work/starter.zip" index.html)
made=1
r="$(api POST "/v1/orgs/$ORG/repos" -H 'Content-Type: application/json' \
  --data "$(jq -nc --arg n "$NAME" --arg d "$MADE_BY" '{name: $n, description: $d, private: true}')")" ||
  die "step 1: the API did not answer"
[ "$(code "$r")" = 201 ] || die "step 1: the API did not create the repo: HTTP $(code "$r") $(body "$r")"
r="$(api POST "/v1/orgs/$ORG/repos/$NAME/starter" -H 'Content-Type: application/zip' --data-binary "@$work/starter.zip")" ||
  die "step 1: the API did not answer"
[ "$(code "$r")" = 200 ] || die "step 1: the API did not take the starter: HTTP $(code "$r") $(body "$r")"
kind="$(body "$r" | jq -r '.kind // ""')"
root="$(body "$r" | jq -r '.root // ""')"
commit="$(body "$r" | jq -r '.commit')"
[ "$kind" = static ] || die "step 1: the API reads the starter as '$kind', not static"
echo "  ok    $OWNER/$NAME at ${commit:0:7}: one index.html, a static site ($((SECONDS - t)) s)"

log "2. the Product $NAME, delivered from Infrared's scaffold"
t=$SECONDS
r="$(api POST "/v1/orgs/$ORG/products" -H 'Content-Type: application/json' \
  --data "$(jq -nc --arg n "$NAME" --arg d "$MADE_BY" --arg root "$root" '{name: $n, spec: {
    displayName: "Product check", description: $d, repos: [{name: $n}],
    delivery: {zones: [], scaffold: ({kind: "static"} + (if $root == "" then {} else {root: $root} end))}}}')")" ||
  die "step 2: the API did not answer"
[ "$(code "$r")" = 201 ] || die "step 2: the API did not create the Product: HTTP $(code "$r") $(body "$r")"
ZONE="$(body "$r" | jq -r '.spec.delivery.zones[0].name // ""')"
[ -n "$ZONE" ] || die "step 2: the API gave the Product no zone"
HOST="$ZONE.$DOMAIN"
echo "  ok    zone $ZONE, a preview at https://$HOST/ ($((SECONDS - t)) s)"

log "3. Infrared scaffolds it into the gitops repo, and Argo CD syncs it"
t=$SECONDS
rel=""
p="{}"
for _ in $(seq 1 60); do
  p="$(k -n "$NS" get products.infrared.darkshift.io "$NAME" -o json 2>/dev/null || echo '{}')"
  rel="$(jq -r '.metadata.annotations["infrared.darkshift.io/first-release"] // ""' <<<"$p")"
  [ -n "$rel" ] && [ "$(jq -r '.status.zoneFiles.ready // false' <<<"$p")" = true ] && break
  rel=""
  sleep 5
done
[ -n "$rel" ] || die "step 3: Infrared did not scaffold $NAME in 5 minutes: $(jq -r '.status.zoneFiles.message // "no message"' <<<"$p")"
echo "  ok    the build, the chart and zone $ZONE are in the gitops repo; Infrared started Release $rel ($((SECONDS - t)) s)"
zapp="$(jq -r --arg z "$ZONE" '.status.zoneFiles.zones[] | select(.name == $z) | .applicationName' <<<"$p")"
bapp="product-$NAME-build"
state() { k -n argocd get applications.argoproj.io "$1" -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true; }
dest=0 b="" z=""
# Argo CD reads the gitops repo every three minutes.
for _ in $(seq 1 120); do
  dest="$(k -n argocd get appprojects.argoproj.io products -o json 2>/dev/null |
    jq --arg d "$NAME-*" '[.spec.destinations[]? | select(.namespace == $d)] | length' 2>/dev/null || true)"
  dest="${dest:-0}"
  b="$(state "$bapp")" z="$(state "$zapp")"
  [ "$dest" -ge 1 ] && [ "$b" = Synced/Healthy ] && [ "$z" = Synced/Healthy ] && break
  sleep 5
done
[ "$dest" -ge 1 ] || die "step 3: the AppProject products admits no $NAME-* after 10 minutes"
[ "$b" = Synced/Healthy ] && [ "$z" = Synced/Healthy ] ||
  die "step 3: after 10 minutes $bapp is ${b:-missing} and $zapp is ${z:-missing}, not Synced/Healthy"
made_by="$(k -n argocd get appprojects.argoproj.io products -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}')"
if [ -n "$project_before" ]; then what="it was there already"; else what="Infrared made it now"; fi
echo "  ok    AppProject products ($made_by; $what) admits $NAME-*, and $bapp and $zapp are Synced and Healthy ($((SECONDS - t)) s)"

log "4. kpack builds it into the registry, as org $ORG"
t=$SECONDS
ready=""
for _ in $(seq 1 180); do
  ready="$(k -n builds get images.kpack.io "$NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  [ "$ready" = True ] && break
  failed="$(k -n builds get builds.kpack.io -l "image.kpack.io/image=$NAME" \
    -o jsonpath='{.items[*].status.conditions[?(@.type=="Succeeded")].status}' 2>/dev/null || true)"
  case " $failed " in *" False "*) die "step 4: the build failed: kubectl --context $CTX -n builds get builds -l image.kpack.io/image=$NAME" ;; esac
  sleep 5
done
[ "$ready" = True ] || die "step 4: the kpack Image builds/$NAME is not Ready after 15 minutes"
built="$(k -n builds get images.kpack.io "$NAME" -o jsonpath='{.status.latestImage}')"
sa="$(k -n builds get images.kpack.io "$NAME" -o jsonpath='{.spec.serviceAccountName}')"
case "$built" in "$REG/$ORG/$NAME@sha256:"*) ;; *) die "step 4: the build is $built, not under $REG/$ORG/$NAME" ;; esac
echo "  ok    $built, as builds/$sa ($((SECONDS - t)) s)"

log "5. Release $rel tags it and promotes it to $ZONE"
t=$SECONDS
phase=""
for _ in $(seq 1 180); do
  r="$(k -n "$NS" get releases.infrared.darkshift.io "$rel" -o json 2>/dev/null || echo '{}')"
  phase="$(jq -r '.status.phase // ""' <<<"$r")"
  case "$phase" in
    Released) break ;;
    Failed) die "step 5: Release $rel failed: $(jq -r '.status.message' <<<"$r")" ;;
  esac
  sleep 5
done
[ "$phase" = Released ] || die "step 5: Release $rel is not Released after 15 minutes: $(jq -r '.status.message // ""' <<<"$r")"
version="$(jq -r '.status.version' <<<"$r")"
image="$(jq -r '.status.image' <<<"$r")"
zphase="$(jq -r --arg z "$ZONE" '.status.zones[] | select(.name == $z) | .phase' <<<"$r")"
zmsg="$(jq -r --arg z "$ZONE" '.status.zones[] | select(.name == $z) | .message' <<<"$r")"
runs="$(k -n "$ZONE" get deployment "$NAME" -o jsonpath='{.spec.template.spec.containers[0].image}')"
# A registry with a port keeps it in the pinned repository.
case "$image" in "$REG/$ORG/$NAME:$version@sha256:"*) ;; *) die "step 5: the Release tagged $image, not $REG/$ORG/$NAME:$version by digest" ;; esac
[ "$runs" = "$REG/$ORG/$NAME@${image##*@}" ] || die "step 5: zone $ZONE runs $runs, not $REG/$ORG/$NAME@${image##*@}"
[ "$zphase" = Healthy ] || die "step 5: zone $ZONE is $zphase: $zmsg"
echo "  ok    $image; $ZONE runs it by digest, Healthy: $zmsg ($((SECONDS - t)) s)"

log "6. https://$HOST/ asks for sign-in, then serves the starter"
t=$SECONDS
first=""
for _ in $(seq 1 24); do
  first="$(curl -sS -o /dev/null --max-time 30 -w '%{http_code} %{redirect_url}' "https://$HOST/" || true)"
  [ "${first%% *}" = 302 ] && break
  sleep 5
done
login_url="${first#* }"
case "$first" in "302 $API/v1/auth/preview-login?"*) ;; *) die "step 6: without a cookie, want a redirect to $API/v1/auth/preview-login, got ${first%%\?*}" ;; esac
echo "  ok    without a cookie: 302 to ${login_url%%\?*}"
# The token goes to Infrared's own host only, never to the zone.
second="$({
  printf 'header = "Authorization: Bearer '
  tr -d '\r\n' <"$TOKEN_FILE" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n'
  printf '"\n'
} | curl -sS -K - -o /dev/null --max-time 30 -w '%{http_code} %{redirect_url}' "$login_url")" || second="none"
pass_url="${second#* }"
case "$second" in "302 https://$HOST/?"*__ir_preview=*) ;; *) die "step 6: Infrared's sign-in, with the token, answered ${second%%\?*}, not a pass for $HOST" ;; esac
echo "  ok    with the token, Infrared's sign-in sends it back with a pass for $HOST"
jar="$work/cookies"
third="$(curl -sS -o /dev/null -c "$jar" --max-time 30 -w '%{http_code} %{redirect_url}' "$pass_url")" || third="none"
if [ "$third" != "302 https://$HOST/" ] || ! grep -q "ir_preview" "$jar"; then
  die "step 6: the pass did not become a cookie: ${third%%\?*}"
fi
echo "  ok    the pass becomes a cookie for $HOST, and a redirect to https://$HOST/"
fourth="$(curl -sS -b "$jar" -D "$work/headers" -o "$work/page" --max-time 30 -w '%{http_code}' "https://$HOST/")" || fourth="none"
[ "$fourth" = 200 ] || die "step 6: with the cookie, want 200, got $fourth"
grep -q "$marker" "$work/page" || die "step 6: the page is not the starter's: its marker is missing"
grep -qi '^cache-control: *no-store' "$work/headers" || die "step 6: the page is not sent with Cache-Control: no-store"
if grep -qiE '^(etag|last-modified):' "$work/headers"; then die "step 6: the page still carries an ETag or a Last-Modified"; fi
echo "  ok    with the cookie: 200, the starter's page with its marker, Cache-Control: no-store and no ETag ($((SECONDS - t)) s)"

log "7. the Product's links name the zone, from its HTTPRoute"
r="$(api GET "/v1/orgs/$ORG/products/$NAME/links")" || die "step 7: the API did not answer"
[ "$(code "$r")" = 200 ] || die "step 7: HTTP $(code "$r") $(body "$r")"
link="$(body "$r" | jq -c --arg z "$ZONE" '[.[] | select(.kind == "zone" and .zone == $z)][0] // {}')"
[ "$(jq -r '.url' <<<"$link")" = "https://$HOST/" ] && [ "$(jq -r '.access' <<<"$link")" = sign-in ] &&
  [ "$(jq -r '.note // ""' <<<"$link")" = "" ] || die "step 7: the zone's link is $link, not https://$HOST/ behind sign-in from its HTTPRoute"
echo "  ok    https://$HOST/, behind sign-in, $(jq -r '.version' <<<"$link")"

log "8. nothing made by hand, and no agent ran"
route="$(k -n "$ZONE" get httproutes.gateway.networking.k8s.io "$NAME-preview" -o json)"
jq -e '(.spec.parentRefs[0] | .namespace == "envoy-gateway-system" and .name == "edge" and .sectionName == "https") and
  ([.status.parents[]? | select(.parentRef.name == "edge") | .conditions[] | select(.type == "Accepted" or .type == "ResolvedRefs")
    | .status == "True"] | length == 2 and all)' <<<"$route" >/dev/null ||
  die "step 8: the zone's HTTPRoute is not Accepted on the edge's https listener"
[ "$(jq -r '.metadata.labels["infrared.darkshift.io/dns"] // ""' <<<"$route")" = "" ] ||
  die "step 8: the zone's HTTPRoute carries the label external-dns publishes"
certs="$(k -n "$ZONE" get certificates.cert-manager.io -o name 2>/dev/null || true)"
[ -z "$certs" ] || die "step 8: the zone has a certificate of its own: $certs"
echo "  ok    the edge's Gateway serves it on its https listener (*.$DOMAIN, the edge's certificate); no DNS record or certificate of its own"
k -n builds get serviceaccount "$sa" -o json | jq -e --arg s "registry-push-$ORG" \
  '.metadata.labels["app.kubernetes.io/managed-by"] == "infrared" and ([.secrets[]?.name] | index($s) != null)' >/dev/null ||
  die "step 8: builds/$sa is not Infrared's, or lists no registry-push-$ORG"
k -n builds get secret "registry-push-$ORG" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' | grep -qx infrared ||
  die "step 8: builds/registry-push-$ORG is not Infrared's"
echo "  ok    the build pushed with builds/registry-push-$ORG, which Infrared made with builds/$sa"
runs_after="$(k get agentworkflowruns.infrared.darkshift.io -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}')"
new="$(comm -13 <(sort <<<"$runs_before") <(sort <<<"$runs_after") | sed '/^$/d')"
[ -z "$new" ] || die "step 8: AgentWorkflowRuns started during the check: $(tr '\n' ' ' <<<"$new")"
echo "  ok    no AgentWorkflowRun started"

log "PASS: Product $NAME, Release $rel ($version), zone $ZONE at https://$HOST/, on $CTX, in $((SECONDS - t0)) s"
