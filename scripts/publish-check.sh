#!/usr/bin/env bash
# =============================================================================
# publish-check.sh <kube context> <organization> <token file>: a step of an
# AgentWorkflowRun publishes an image and a chart to the registry inside the
# cluster, a zone runs the image by digest, and the step's key is refused
# outside its organization's path. It starts one agent run, which spends.
# =============================================================================
# Plan step G6. Runs against an install with a Gateway edge and previews, the
# registry inside the cluster (the operator's INFRARED_REGISTRY), the org's
# repos on the install's Gitea and the org's model key (the Secret
# model-provider-anthropic in ir-org-<org>), never from CI. It goes through
# Infrared's API at the Installation's sign-in URL, with the bearer token in
# <token file>, and uses kubectl only for what the API does not do:
#
#   1. makes a Product from a starter zip as scripts/product-check.sh does, and
#      waits until its zone runs kpack's build of it, the first Release, by
#      digest: the image the step builds on;
#   2. makes, with kubectl, since the API creates neither, an AgentRole that
#      may publish (spec.permissions.publish) and an AgentWorkflow of one
#      report step that runs it. The role's instructions are one shell script:
#      crane append builds an image from the zone's image and a page with a new
#      marker, and helm package a chart, both into .infrared/publish/ for the
#      runner to push. The role caps the run: MODEL (empty: the runner's
#      default), at most MAX_TURNS turns (8) and MAX_BUDGET_USD dollars (2.00);
#   3. starts the run through the API. The agent's model calls are billed to
#      the org's Anthropic key, so without SPEND=1 the check makes nothing and
#      stops before step 1;
#   4. while the step runs, reads the step's registry key from its Secret and
#      asks the registry whether it may push: under <org>/<product>/ it may;
#      under another organization's path and under platform/ it is refused
#      (403). Nothing is pushed: a manifest of a type the registry does not
#      take is refused (415) once the push is allowed;
#   5. waits for the run to succeed and reads the step through the API: it
#      published one image and one chart, by digest, under
#      <registry>/<org>/<product>/, and the registry serves both by those
#      digests, the chart as a Helm chart. The step's Secret is gone, and the
#      registry refuses its key (401);
#   6. releases the published image through the API (image.fromStep) as the
#      next patch version: the Release tags it, and the zone runs it by digest,
#      Healthy, its pod on that digest;
#   7. asks https://<product>-rc.<domain>/ through Infrared's sign-in as the
#      Product check does: 200, the page with the step's marker, not the
#      starter's;
#   8. prints what the run cost, from its status: turns, tokens and dollars.
#
# Each step prints how long it took. Then, unless KEEP=1, it removes what it
# made: the Product (Infrared removes its gitops files, Applications and zone),
# its Releases, the run with its Job, the AgentRole and AgentWorkflow, its repo
# (on Gitea, as Gitea's site admin) and every image and chart under
# <org>/<product> (as the registry's admin user infrared). KEEP=1 leaves them,
# and REMOVE=<product> removes them later. Either way it touches only names it
# makes, publish-check-<MMDDhhmmss>, and only objects that say the check made
# them.
#
# The token goes only to Infrared's API, from the file into curl's config on
# stdin; the registry's passwords and the step's key go the same way to the
# registry. None of them, and no pass or cookie, is printed.
# Needs: kubectl, jq, curl, zip.
# =============================================================================
set -euo pipefail
usage='usage: SPEND=1 [KEEP=1] [MODEL=<model>] scripts/publish-check.sh <kube context> <organization> <token file>
       REMOVE=<product> scripts/publish-check.sh <kube context> <organization> <token file>'
CTX="${1:?$usage}"
ORG="${2:?$usage}"
TOKEN_FILE="${3:?$usage}"
MAX_TURNS="${MAX_TURNS:-8}"
MAX_BUDGET_USD="${MAX_BUDGET_USD:-2.00}"
STEP=publish
# The description of everything it makes: remove() takes only what says this.
MADE_BY="Made by the publish check (infrared-gitops-template scripts/publish-check.sh). Safe to delete."
PART_OF=publish-check
ACCEPT='application/vnd.oci.image.manifest.v1+json,application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.docker.distribution.manifest.list.v2+json'
# A manifest of this type is refused (415) only after the push is authorized,
# as the operator asks the registry whether a user may push (internal/zot).
PROBE_TYPE=application/vnd.darkshift.infrared.probe

k() { kubectl --context "$CTX" "$@"; }
log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

for t in kubectl jq curl zip; do command -v "$t" >/dev/null || die "missing tool: $t"; done
[[ "$MAX_TURNS" =~ ^[1-9][0-9]?$ ]] || die "MAX_TURNS is $MAX_TURNS: a number of turns, 1 to 99"
[[ "$MAX_BUDGET_USD" =~ ^[0-9]+(\.[0-9]{1,2})?$ ]] || die "MAX_BUDGET_USD is $MAX_BUDGET_USD: dollars, such as 2.00"
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
op_registry="$(k -n infrared get deployment infrared-operator -o json |
  jq -r '[.spec.template.spec.containers[0].env[]? | select(.name == "INFRARED_REGISTRY") | .value][0] // ""')"
[ "$op_registry" = "$REG" ] ||
  die "the operator's INFRARED_REGISTRY is '$op_registry', not the registry at $REG: no step gets a key to publish with"
gp="$(k -n "$NS" get gitproviders.infrared.darkshift.io -o json | jq -c '.items[0] // empty')"
[ -n "$gp" ] || die "org $ORG has no GitProvider"
[ "$(jq -r '.spec.type' <<<"$gp")" = gitea ] || die "org $ORG's forge is not the install's Gitea: this check removes its repo there"
OWNER="$(jq -r '.spec.owner' <<<"$gp")"

work="$(mktemp -d)"
pfs=""
made=""
cleanup() {
  local rc=$? p
  set +e
  if [ -n "$made" ]; then
    if [ "${KEEP:-}" = 1 ]; then
      echo "KEEP=1: $NAME keeps running; remove it with REMOVE=$NAME scripts/publish-check.sh $CTX $ORG <token file>"
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

# quoted: stdin as a value for curl's config, escaped, with no newline.
quoted() { sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\r\n'; }

# api <method> <path> [curl args...]: one call to Infrared's API with the
# token, which reaches curl as its config on stdin. Prints the body, then the
# HTTP status on a line of its own.
api() {
  local method=$1 path=$2
  shift 2
  {
    printf 'header = "Authorization: Bearer '
    quoted <"$TOKEN_FILE"
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
  } | quoted
  printf '"\n'
}

# probe <user:password file> <repository>: whether that login may push a tag
# to the repository, without pushing anything. Prints the registry's answer:
# 415 when it may, 403 when it may not, 401 when the login is refused.
probe() {
  {
    printf 'user = "'
    quoted <"$1"
    printf '"\n'
  } | curl -sS -K - -o /dev/null -w '%{http_code}' -X PUT -H "Content-Type: $PROBE_TYPE" --data-binary '{}' \
    "http://127.0.0.1:$zport/v2/$2/manifests/publish-check-probe" || echo none
}

# remove <product>: removes a check's Product, its Releases, its run, its
# AgentRole and AgentWorkflow, its repo and its images and charts. Returns 1
# when something is left.
remove() {
  local name=$1 left=0 p r repo="$1" gone="" o repos tags tag digests d host gport gsvc gns n=0
  log "removing $name: the Product, its Releases and run, its AgentRole and AgentWorkflow, its repo, its images and chart"
  if p="$(k -n "$NS" get products.infrared.darkshift.io "$name" -o json 2>/dev/null)"; then
    if [ "$(jq -r '.spec.description // ""' <<<"$p")" != "$MADE_BY" ]; then
      warn "Product $name does not say this check made it: nothing removed"
      return 1
    fi
    repo="$(jq -r '.spec.repos[0].name' <<<"$p")"
    r="$(api DELETE "/v1/orgs/$ORG/products/$name")" || r=$'\nnone'
    case "$(code "$r")" in 204 | 404) ;; *) warn "the API did not delete Product $name: HTTP $(code "$r") $(body "$r")" ;; esac
    for _ in $(seq 1 120); do
      k -n "$NS" get products.infrared.darkshift.io "$name" >/dev/null 2>&1 || { gone=1; break; }
      sleep 5
    done
    if [ -n "$gone" ]; then
      echo "  ok    Product $name is gone, with its gitops files, Applications and zone namespace"
    else
      warn "Product $name is still there after 10 minutes: $(k -n "$NS" get products.infrared.darkshift.io "$name" \
        -o jsonpath='{.status.zoneFiles.message}' 2>/dev/null)"
      left=1
    fi
  fi
  k -n "$NS" delete releases.infrared.darkshift.io -l "infrared.darkshift.io/product=$name" --ignore-not-found >/dev/null ||
    left=1
  # The run, with its Job: the API cancels runs and deletes none.
  k -n "$NS" delete agentworkflowruns.infrared.darkshift.io -l "infrared.darkshift.io/product=$name" \
    --ignore-not-found >/dev/null || left=1
  for o in agentworkflows.infrared.darkshift.io agentroles.infrared.darkshift.io; do
    if k -n "$NS" get "$o" "$name" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null | grep -qx "$PART_OF"; then
      k -n "$NS" delete "$o" "$name" --ignore-not-found >/dev/null || left=1
    fi
  done
  echo "  ok    its Releases, its run, its AgentWorkflow and its AgentRole are deleted"

  # The repo: the API deletes none, so Gitea's site admin does.
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

  # The images and the chart: every tag's manifest of every repository under
  # <org>/<product>, as the registry's admin user infrared. The registry's
  # garbage collection then frees the blobs.
  if ! forward registry zot "${REG##*:}"; then
    warn "no port-forward to registry/zot: the images under $ORG/$name are left"
    return 1
  fi
  repos="$(curl -sS "http://127.0.0.1:$port/v2/_catalog?n=10000" |
    jq -r --arg p "$ORG/$name" '.repositories // [] | .[] | select(. == $p or startswith($p + "/"))' 2>/dev/null || true)"
  for o in $repos; do
    tags="$(curl -sS "http://127.0.0.1:$port/v2/$o/tags/list" | jq -r '.tags // [] | .[]' 2>/dev/null || true)"
    digests="$(for tag in $tags; do
      curl -sS -I -H "Accept: $ACCEPT,application/vnd.cncf.helm.config.v1+json" "http://127.0.0.1:$port/v2/$o/manifests/$tag" |
        awk 'tolower($1) == "docker-content-digest:" { print $2 }' | tr -d '\r'
    done | sort -u)"
    for d in $digests; do
      r="$({
        printf 'user = "infrared:'
        k -n infrared get secret registry-identities -o jsonpath='{.data.infrared}' | base64 -d | quoted
        printf '"\n'
      } | curl -sS -K - -o /dev/null -w '%{http_code}' -X DELETE "http://127.0.0.1:$port/v2/$o/manifests/$d")" || r=none
      if [ "$r" = 202 ]; then n=$((n + 1)); else
        warn "the registry did not delete $o@$d: HTTP $r"
        left=1
      fi
    done
    tags="$(curl -sS "http://127.0.0.1:$port/v2/$o/tags/list" | jq -r '.tags // [] | .[]' 2>/dev/null || true)"
    if [ -n "$tags" ]; then
      warn "tags left under $o: $(tr '\n' ' ' <<<"$tags")"
      left=1
    fi
  done
  echo "  ok    the images and charts under $ORG/$name are deleted ($n manifests in $(wc -w <<<"$repos" | tr -d ' ') repositories)"
  echo "  note  the products AppProject keeps the destination $name-*: Infrared removes none"
  return "$left"
}

if [ -n "${REMOVE:-}" ]; then
  [[ "$REMOVE" =~ ^publish-check-[0-9]{10}$ ]] || die "REMOVE takes a Product this check made: publish-check-<MMDDhhmmss>"
  NAME="$REMOVE" made=1 KEEP=
  exit 0
fi

me="$(api GET /v1/auth/me)" || die "Infrared's API does not answer at $API"
[ "$(code "$me")" = 200 ] || die "Infrared's API refuses the token in $TOKEN_FILE: HTTP $(code "$me")"
k -n "$NS" get secret model-provider-anthropic >/dev/null 2>&1 ||
  die "org $ORG has no model key (the Secret $NS/model-provider-anthropic): the step's agent cannot run"
[ "${SPEND:-}" = 1 ] || die "this check starts one agent run, billed to org $ORG's Anthropic key (at most $MAX_TURNS turns and \$$MAX_BUDGET_USD):
       run it again with SPEND=1 once the run has its go-ahead. Nothing was made."
NAME="publish-check-$(date -u +%m%d%H%M%S)"
runs_before="$(k get agentworkflowruns.infrared.darkshift.io -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}')"
OTHER="$(k get organizations.infrared.darkshift.io -o json |
  jq -r --arg o "$ORG" '[.items[].metadata.name | select(. != $o and . != "platform" and . != "infrared")][0] // ""')"
other_note="org $OTHER's path"
if [ -z "$OTHER" ]; then
  OTHER=publish-check-other
  other_note="the path of an organization that does not exist: $CTX has no other"
fi
echo "Product $NAME of org $ORG on $CTX, through $API as $(body "$me" | jq -r '"\(.kind) \(.tokenName // .user // "")"')"
t0=$SECONDS

log "1. the Product $NAME from a starter zip, and its zone on kpack's build"
t=$SECONDS
marker0="$(od -An -N10 -tx1 /dev/urandom | tr -d ' \n')"
mkdir "$work/site"
cat >"$work/site/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Publish check</title>
</head>
<body>
<h1>Publish check</h1>
<p>Built from a starter zip by Infrared's publish check.</p>
<p id="marker">$marker0</p>
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
[ "$(body "$r" | jq -r '.kind // ""')" = static ] || die "step 1: the API does not read the starter as a static site"
root="$(body "$r" | jq -r '.root // ""')"
r="$(api POST "/v1/orgs/$ORG/products" -H 'Content-Type: application/json' \
  --data "$(jq -nc --arg n "$NAME" --arg d "$MADE_BY" --arg root "$root" '{name: $n, spec: {
    displayName: "Publish check", description: $d, repos: [{name: $n}],
    delivery: {zones: [], scaffold: ({kind: "static"} + (if $root == "" then {} else {root: $root} end))}}}')")" ||
  die "step 1: the API did not answer"
[ "$(code "$r")" = 201 ] || die "step 1: the API did not create the Product: HTTP $(code "$r") $(body "$r")"
ZONE="$(body "$r" | jq -r '.spec.delivery.zones[0].name // ""')"
[ -n "$ZONE" ] || die "step 1: the API gave the Product no zone"
HOST="$ZONE.$DOMAIN"
rel0=""
for _ in $(seq 1 60); do
  p="$(k -n "$NS" get products.infrared.darkshift.io "$NAME" -o json 2>/dev/null || echo '{}')"
  rel0="$(jq -r '.metadata.annotations["infrared.darkshift.io/first-release"] // ""' <<<"$p")"
  [ -n "$rel0" ] && break
  sleep 5
done
[ -n "$rel0" ] || die "step 1: Infrared did not scaffold $NAME in 5 minutes: $(jq -r '.status.zoneFiles.message // "no message"' <<<"$p")"
phase=""
for _ in $(seq 1 240); do
  r="$(k -n "$NS" get releases.infrared.darkshift.io "$rel0" -o json 2>/dev/null || echo '{}')"
  phase="$(jq -r '.status.phase // ""' <<<"$r")"
  case "$phase" in
    Released) break ;;
    Failed) die "step 1: the first Release $rel0 failed: $(jq -r '.status.message' <<<"$r")" ;;
  esac
  sleep 5
done
[ "$phase" = Released ] || die "step 1: the first Release $rel0 is not Released after 20 minutes: $(jq -r '.status.message // ""' <<<"$r")"
version0="$(jq -r '.status.version' <<<"$r")"
image0="$(jq -r '.status.image' <<<"$r")"
case "$image0" in "$REG/$ORG/$NAME:$version0@sha256:"*) ;; *) die "step 1: the first Release tagged $image0, not $REG/$ORG/$NAME by digest" ;; esac
BASE="$REG/$ORG/$NAME@${image0##*@}"
# The page goes where the build serves its files: /workspace/<root>.
page_root="$(k -n builds get images.kpack.io "$NAME" -o json |
  jq -r '[.spec.build.env[]? | select(.name == "BP_WEB_SERVER_ROOT") | .value][0] // "public"')"
page="workspace/${page_root#./}"
page="${page%/.}"
page="${page%/}/index.html"
echo "  ok    zone $ZONE runs $image0, Release $rel0 ($((SECONDS - t)) s); the step builds on $BASE"

log "2. an AgentRole that may publish, and an AgentWorkflow that runs it"
t=$SECONDS
marker="$(od -An -N10 -tx1 /dev/urandom | tr -d ' \n')"
TARGET="$REG/$ORG/$NAME/site:publish-check"
script="set -eu
out=.infrared/publish
mkdir -p \"\$out\" /tmp/publish-check/page/${page%/index.html} /tmp/publish-check/chart/publish-check
cat >/tmp/publish-check/page/$page <<'PAGE'
<!doctype html>
<html lang=\"en\">
<head>
<meta charset=\"utf-8\">
<title>Publish check</title>
</head>
<body>
<h1>Publish check</h1>
<p>Published by a step of an AgentWorkflowRun, for Infrared's publish check.</p>
<p id=\"marker\">$marker</p>
</body>
</html>
PAGE
tar -C /tmp/publish-check/page -cf /tmp/publish-check/page.tar $page
crane append --insecure --base $BASE --new_layer /tmp/publish-check/page.tar --new_tag $TARGET --output \"\$out/site.tar\"
cat >/tmp/publish-check/chart/publish-check/Chart.yaml <<'CHART'
apiVersion: v2
name: publish-check
description: A chart published by a step of an AgentWorkflowRun, for Infrared's publish check.
type: application
version: 0.1.0
CHART
helm package /tmp/publish-check/chart/publish-check --destination \"\$out\"
printf '%s\\n' '{\"images\":[{\"file\":\"site.tar\",\"name\":\"site\",\"tag\":\"publish-check\"}],\"charts\":[{\"file\":\"publish-check-0.1.0.tgz\"}]}' >\"\$out/publish.json\"
ls -l \"\$out\"
echo 'publish-check: ready'"
instructions="This step is Infrared's publish check. Its whole task is the shell script below. Run it with Bash, once, as one command, exactly as written, from your working directory, the workspace root. It leaves an image and a chart in .infrared/publish/, which the runner pushes once you have finished.

\`\`\`sh
$script
\`\`\`

Do nothing else: do not read, change or test the repository, and do not run the script twice. If it printed \"publish-check: ready\", your verdict is PUBLISHED. Otherwise it is BLOCKED, and your summary quotes the last lines of the script's output."
labels="$(jq -nc --arg p "$PART_OF" --arg n "$NAME" '{"app.kubernetes.io/part-of": $p, "infrared.darkshift.io/product": $n}')"
jq -n --arg ns "$NS" --arg n "$NAME" --argjson l "$labels" --arg d "$MADE_BY" --arg i "$instructions" --arg m "${MODEL:-}" \
  --arg b "$MAX_BUDGET_USD" --argjson turns "$MAX_TURNS" '{
  apiVersion: "infrared.darkshift.io/v1alpha1", kind: "AgentRole",
  metadata: {namespace: $ns, name: $n, labels: $l, annotations: {"infrared.darkshift.io/made-by": $d}},
  spec: {
    displayName: "Publish check", category: "builder", enabled: true,
    summary: "Builds an image and a chart for the runner to publish, for the publish check.",
    mission: "Leave one image and one chart in .infrared/publish/, built by the given script, and nothing else.",
    responsibilities: ["Run the given script once, as written"],
    triggers: [{type: "adhoc", description: "Started by scripts/publish-check.sh"}],
    successCriteria: ["The script printed publish-check: ready"],
    verdicts: ["PUBLISHED", "BLOCKED"],
    instructions: $i,
    permissions: {publish: true, network: "allowlist"},
    model: ({maxTurns: $turns, maxBudgetUSD: $b} + (if $m == "" then {} else {model: $m} end))
  }}' >"$work/agentrole.json"
jq -n --arg ns "$NS" --arg n "$NAME" --argjson l "$labels" --arg d "$MADE_BY" --arg s "$STEP" '{
  apiVersion: "infrared.darkshift.io/v1alpha1", kind: "AgentWorkflow",
  metadata: {namespace: $ns, name: $n, labels: $l, annotations: {"infrared.darkshift.io/made-by": $d}},
  spec: {
    displayName: "Publish check", description: $d, enabled: true, maxConcurrency: 1,
    triggers: [{type: "adhoc", description: "Started by scripts/publish-check.sh"}],
    steps: [{name: $s, type: "agentRole", agentRole: $n, mode: "report", onFailure: "fail", maxAttempts: 1,
      timeout: "20m", description: "Builds an image and a chart; the runner publishes them."}]
  }}' >"$work/agentworkflow.json"
k apply -f "$work/agentrole.json" >/dev/null || die "step 2: kubectl did not make the AgentRole"
k apply -f "$work/agentworkflow.json" >/dev/null || die "step 2: kubectl did not make the AgentWorkflow"
r="$(api GET "/v1/orgs/$ORG/agentroles/$NAME")" || die "step 2: the API did not answer"
[ "$(code "$r")" = 200 ] && [ "$(body "$r" | jq -r '.agentRole.spec.permissions.publish // false')" = true ] ||
  die "step 2: the API does not show AgentRole $NAME as one that may publish: HTTP $(code "$r")"
model="${MODEL:-}"
[ -n "$model" ] || model="the runner's default"
echo "  ok    AgentRole and AgentWorkflow $NAME: one report step, publish allowed, at most $MAX_TURNS turns and \$$MAX_BUDGET_USD, model $model ($((SECONDS - t)) s)"

log "3. the run, through the API: this spends"
t=$SECONDS
r="$(api POST "/v1/orgs/$ORG/agentworkflowruns" -H 'Content-Type: application/json' \
  --data "$(jq -nc --arg w "$NAME" --arg p "$NAME" '{workflow: $w, product: $p}')")" || die "step 3: the API did not answer"
[ "$(code "$r")" = 201 ] || die "step 3: the API did not start the run: HTTP $(code "$r") $(body "$r")"
RUN="$(body "$r" | jq -r '.name')"
echo "  ok    AgentWorkflowRun $RUN ($((SECONDS - t)) s)"

log "4. while the step runs, its key pushes under org $ORG's path and nowhere else"
t=$SECONDS
keyfile="$work/step-key"
sec=""
for _ in $(seq 1 300); do
  sec="$(k -n "$NS" get secrets -l infrared.darkshift.io/registry-key -o json |
    jq -r --arg r "$RUN" '[.items[] | select(any(.metadata.ownerReferences[]?; .name == $r))][0].metadata.name // ""')"
  [ -n "$sec" ] && break
  ph="$(k -n "$NS" get agentworkflowruns.infrared.darkshift.io "$RUN" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  case "$ph" in Succeeded | Failed | Cancelled | DeadLettered) break ;; esac
  sleep 2
done
[ -n "$sec" ] || die "step 4: no registry Secret for run $RUN's step appeared before it ended: $(k -n "$NS" get \
  agentworkflowruns.infrared.darkshift.io "$RUN" -o jsonpath='{.status.steps[0].message}' 2>/dev/null)"
{
  k -n "$NS" get secret "$sec" -o jsonpath='{.data.username}' | base64 -d
  printf ':'
  k -n "$NS" get secret "$sec" -o jsonpath='{.data.password}' | base64 -d
} >"$keyfile"
chmod 600 "$keyfile"
[ "$(cut -d: -f1 "$keyfile")" = "$ORG" ] || die "step 4: the step's key is not of the registry user $ORG"
forward registry zot "${REG##*:}" || die "step 4: no port-forward to registry/zot"
zport=$port
own="$(probe "$keyfile" "$ORG/$NAME/probe")"
to_other="$(probe "$keyfile" "$OTHER/probe")"
to_platform="$(probe "$keyfile" "platform/probe")"
[ "$own" = 415 ] || die "step 4: the step's key pushing under $ORG/$NAME/: HTTP $own, want it allowed (415 for the probe's type)"
[ "$to_other" = 403 ] || die "step 4: the step's key pushing under $OTHER/, $other_note: HTTP $to_other, want 403"
[ "$to_platform" = 403 ] || die "step 4: the step's key pushing under platform/: HTTP $to_platform, want 403"
echo "  ok    $sec holds a key of user $ORG: allowed under $ORG/$NAME/, refused (403) under $OTHER/ ($other_note) and under platform/ ($((SECONDS - t)) s)"

log "5. the step publishes an image and a chart, by digest"
t=$SECONDS
phase=""
for _ in $(seq 1 180); do
  r="$(api GET "/v1/orgs/$ORG/agentworkflowruns/$RUN")" || r=$'\nnone'
  phase="$(body "$r" | jq -r '.status.phase // ""' 2>/dev/null || true)"
  case "$phase" in Succeeded | Failed | Cancelled | DeadLettered) break ;; esac
  sleep 10
done
s="$(api GET "/v1/orgs/$ORG/agentworkflowruns/$RUN/steps/$STEP")" || die "step 5: the API did not answer"
[ "$(code "$s")" = 200 ] || die "step 5: the API did not return step $STEP of $RUN: HTTP $(code "$s")"
step="$(body "$s" | jq -c '.step')"
usage="$(body "$r" | jq -c '.status.usage // {}' 2>/dev/null || echo '{}')"
cost="$(jq -r '"\(.turns // 0) turns, \(.inputTokens // 0) input, \(.cacheReadTokens // 0) cache-read and \(.outputTokens // 0) output tokens, $\(.costUSD // "0")"' <<<"$usage")"
[ "$phase" = Succeeded ] || die "step 5: run $RUN ended ${phase:-unfinished after 30 minutes} (it cost $cost): $(jq -r '"\(.verdict // "") \(.message // "")"' <<<"$step")"
pub="$(jq -c '.published // []' <<<"$step")"
refused="$(jq -r '[.[] | select((.refused // "") != "")] | map(.refused) | join("; ")' <<<"$pub")"
[ -z "$refused" ] || die "step 5: the registry refused the step's pushes: $refused"
img="$(jq -r --arg p "$REG/$ORG/$NAME/site@sha256:" '[.[] | select(.kind == "image" and (.ref // "" | startswith($p)))] | if length == 1 then .[0].ref else "" end' <<<"$pub")"
chart="$(jq -r --arg p "$REG/$ORG/$NAME/publish-check@sha256:" '[.[] | select(.kind == "chart" and (.ref // "" | startswith($p)) and .version == "0.1.0")] | if length == 1 then .[0].ref else "" end' <<<"$pub")"
[ -n "$img" ] && [ -n "$chart" ] && [ "$(jq length <<<"$pub")" = 2 ] ||
  die "step 5: the step published $pub, not one image site and one chart publish-check 0.1.0 under $REG/$ORG/$NAME/"
digest="${img##*@}"
m="$(curl -sS -D "$work/image.headers" -H "Accept: $ACCEPT" "http://127.0.0.1:$zport/v2/$ORG/$NAME/site/manifests/$digest")"
grep -qi "^docker-content-digest: $digest" "$work/image.headers" || die "step 5: the registry does not serve $img by its digest"
[ "$(jq -r '.layers | length' <<<"$m")" -ge 2 ] || die "step 5: $img has no layer of its own on the zone's image"
m="$(curl -sS -D "$work/chart.headers" -H "Accept: $ACCEPT" "http://127.0.0.1:$zport/v2/$ORG/$NAME/publish-check/manifests/${chart##*@}")"
grep -qi "^docker-content-digest: ${chart##*@}" "$work/chart.headers" || die "step 5: the registry does not serve $chart by its digest"
[ "$(jq -r '.config.mediaType' <<<"$m")" = application/vnd.cncf.helm.config.v1+json ] || die "step 5: $chart is not a Helm chart"
echo "  ok    $img (tag publish-check) and the chart $chart (0.1.0), each served by its digest ($((SECONDS - t)) s)"
k -n "$NS" get secret "$sec" >/dev/null 2>&1 && die "step 5: the step's registry Secret $sec is still there after the run"
after="$(probe "$keyfile" "$ORG/$NAME/probe")"
rm -f "$keyfile"
[ "$after" = 401 ] || die "step 5: after the step the registry answers its key with HTTP $after, want 401"
echo "  ok    the step's Secret is gone and the registry refuses its key (401)"

log "6. a Release of the published image: the zone runs it by digest"
t=$SECONDS
v="${version0#v}"
version="v${v%.*}.$((${v##*.} + 1))"
r="$(api POST "/v1/orgs/$ORG/releases" -H 'Content-Type: application/json' \
  --data "$(jq -nc --arg p "$NAME" --arg v "$version" --arg r "$RUN" --arg s "$STEP" --arg i "$img" \
    '{product: $p, version: $v, notes: "The image a step published, for the publish check.", image: {fromStep: {run: $r, step: $s, ref: $i}}}')")" ||
  die "step 6: the API did not answer"
[ "$(code "$r")" = 201 ] || die "step 6: the API did not start the Release: HTTP $(code "$r") $(body "$r")"
rel="$(body "$r" | jq -r '.name')"
phase=""
for _ in $(seq 1 120); do
  r="$(k -n "$NS" get releases.infrared.darkshift.io "$rel" -o json 2>/dev/null || echo '{}')"
  phase="$(jq -r '.status.phase // ""' <<<"$r")"
  case "$phase" in
    Released) break ;;
    Failed) die "step 6: Release $rel failed: $(jq -r '.status.message' <<<"$r")" ;;
  esac
  sleep 5
done
[ "$phase" = Released ] || die "step 6: Release $rel is not Released after 10 minutes: $(jq -r '.status.message // ""' <<<"$r")"
[ "$(jq -r '.status.image' <<<"$r")" = "$REG/$ORG/$NAME/site:$version@$digest" ] ||
  die "step 6: Release $rel tagged $(jq -r '.status.image' <<<"$r"), not $REG/$ORG/$NAME/site:$version@$digest"
[ "$(jq -r '.status.build' <<<"$r")" = "step $STEP of AgentWorkflowRun $RUN" ] ||
  die "step 6: Release $rel took $(jq -r '.status.build' <<<"$r"), not the step's image"
zphase="$(jq -r --arg z "$ZONE" '.status.zones[] | select(.name == $z) | .phase' <<<"$r")"
[ "$zphase" = Healthy ] || die "step 6: zone $ZONE is $zphase: $(jq -r --arg z "$ZONE" '.status.zones[] | select(.name == $z) | .message' <<<"$r")"
runs="$(k -n "$ZONE" get deployment "$NAME" -o jsonpath='{.spec.template.spec.containers[0].image}')"
[ "$runs" = "$REG/$ORG/$NAME/site@$digest" ] || die "step 6: zone $ZONE runs $runs, not $REG/$ORG/$NAME/site@$digest"
sel="$(k -n "$ZONE" get deployment "$NAME" -o json | jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")')"
ids="$(k -n "$ZONE" get pods -l "$sel" -o json |
  jq -r '.items[] | select(.metadata.deletionTimestamp == null) | .status.containerStatuses[]? | select(.ready) | .imageID')"
grep -q "@$digest\$" <<<"$ids" || die "step 6: no ready pod of zone $ZONE runs $digest: $(tr '\n' ' ' <<<"$ids")"
echo "  ok    Release $rel tagged it $version; zone $ZONE runs $REG/$ORG/$NAME/site@$digest, Healthy, its pod on that digest ($((SECONDS - t)) s)"

log "7. https://$HOST/ serves the step's page"
t=$SECONDS
first=""
for _ in $(seq 1 24); do
  first="$(curl -sS -o /dev/null --max-time 30 -w '%{http_code} %{redirect_url}' "https://$HOST/" || true)"
  [ "${first%% *}" = 302 ] && break
  sleep 5
done
login_url="${first#* }"
case "$first" in "302 $API/v1/auth/preview-login?"*) ;; *) die "step 7: without a cookie, want a redirect to $API/v1/auth/preview-login, got ${first%%\?*}" ;; esac
second="$({
  printf 'header = "Authorization: Bearer '
  quoted <"$TOKEN_FILE"
  printf '"\n'
} | curl -sS -K - -o /dev/null --max-time 30 -w '%{http_code} %{redirect_url}' "$login_url")" || second="none"
pass_url="${second#* }"
case "$second" in "302 https://$HOST/?"*__ir_preview=*) ;; *) die "step 7: Infrared's sign-in, with the token, answered ${second%%\?*}, not a pass for $HOST" ;; esac
jar="$work/cookies"
third="$(curl -sS -o /dev/null -c "$jar" --max-time 30 -w '%{http_code} %{redirect_url}' "$pass_url")" || third="none"
if [ "$third" != "302 https://$HOST/" ] || ! grep -q "ir_preview" "$jar"; then
  die "step 7: the pass did not become a cookie: ${third%%\?*}"
fi
ok=""
for _ in $(seq 1 12); do
  fourth="$(curl -sS -b "$jar" -o "$work/page" --max-time 30 -w '%{http_code}' "https://$HOST/")" || fourth="none"
  if [ "$fourth" = 200 ] && grep -q "$marker" "$work/page"; then ok=1 && break; fi
  sleep 5
done
[ -n "$ok" ] || die "step 7: with the cookie, want 200 and the step's page, got $fourth$(grep -q "$marker0" "$work/page" && echo ", the starter's page")"
echo "  ok    behind sign-in, 200: the page with the step's marker, not the starter's ($((SECONDS - t)) s)"

log "8. what the run cost"
runs_after="$(k get agentworkflowruns.infrared.darkshift.io -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}')"
new="$(comm -13 <(sort <<<"$runs_before") <(sort <<<"$runs_after") | sed '/^$/d')"
[ "$new" = "$NS/$RUN" ] || die "step 8: AgentWorkflowRuns other than $RUN started during the check: $(tr '\n' ' ' <<<"$new")"
echo "  ok    one run, $RUN, and no other: $cost"

log "PASS: run $RUN published $img and $chart; Release $rel ($version) runs it in zone $ZONE at https://$HOST/, on $CTX, in $((SECONDS - t0)) s"
