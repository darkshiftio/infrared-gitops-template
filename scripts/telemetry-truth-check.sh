#!/usr/bin/env bash
# =============================================================================
# telemetry-truth-check.sh <kube context> [options]: an install's own metrics
# store says what its records say, org by org (infrared-docs-internal ADR 0075
# D12; README "Checks on a running install").
# =============================================================================
# A table of each org's figures, the records' beside the store's, then six
# numbered checks, each printing ok, FAIL, WARN or SKIP with its reason. The
# exit status is the number of FAILs. --only 1,3,6 runs a subset.
#
# Checks 1 to 5 read the record-derived series of ADR 0075 D7 and D8: gauges
# the operator reads from its records at each scrape (infrared-operator
# internal/controller/record_metrics.go). The script reads the same records
# with kubectl get and counts them the operator's way:
#
#   - every kind is read across the cluster, and a record's org is its
#     namespace less ir-org-;
#   - a run with no status.phase counts as Queued, a Release or a ReleaseCut
#     with none as Pending;
#   - a label set that no record carries has no sample, so an absent row is
#     0 on either side (only infrared_users is always served);
#   - every operator replica serves the gauges, so each series is read as max
#     by its own labels, never summed across pods;
#   - the series are this install's own, by platform: --platform, else the
#     Installation's spec.observability.telemetry.platform, else the external
#     label platform of the stack's VMAgent, else the context's cluster name.
#
#   1. runs: AgentWorkflowRuns by org, workflow (spec.workflowRef.name) and
#      phase, against infrared_runs;
#   2. deployments: Releases by org, Product (spec.productRef.name) and
#      phase, against infrared_deployments;
#   3. releases: ReleaseCuts by org, Product and phase, against
#      infrared_releases;
#   4. builds: for each Product, the sum of status.buildCounter over the kpack
#      Images labelled infrared.darkshift.io/product with its name, in the
#      namespace its org builds in (builds-<org> when the org's GitopsRepo
#      gitops is in mode org, else builds), against infrared_builds;
#   5. users, Products and kinds: Users against infrared_users; each org's
#      Products against infrared_org_products, and their environments (each
#      zone of spec.delivery.zones, by public) against
#      infrared_org_environments; each org's kind from the records (platform
#      for spec.platform; else the label infrared.darkshift.io/org-kind when
#      it is internal or tenant; else tenant when the label
#      infrared.darkshift.io/self-service-owner is set; else internal)
#      against infrared_org_info;
#   6. step spend: 30 days of agent-step spend by org, the runs' records
#      (status.steps[].attemptUsage[].usage.costUSD of agentRole steps)
#      against sum by (org) (increase_pure(infrared_step_cost_usd_total[30d])),
#      within 5 percent, else WARN with both numbers, never FAIL. An attempt
#      carries no time of its own, so it is dated at the earliest finish the
#      record proves it ended by: its round's finishedAt
#      (status.steps[].rounds[], matched in order to the runs of attempt
#      numbers, which start again at each round and each retry), else its
#      step's finishedAt, or the time of reading for a step still running. A
#      step that ran across the window's start is counted whole. The step
#      counter is summed across pods, since only the leader counts; on a
#      store that keeps 30 days, a counter that began before the window
#      counts from 0, in full. An install that named a telemetry plane within
#      the window wrote its series before then under its cluster's name,
#      which counts too.
#
# Checks 1 to 5 must be equal. Each read brackets a scrape: the records, then
# the store once it holds a scrape of the operator taken after them, then the
# records again. A row is equal when its series matches the records, or lies
# between the two reads of a row that changed meanwhile (a run changing
# phase). A row that is not equal is read again the same way after 60 seconds
# (95 when builds differ: the operator reads kpack's Images at most once a
# minute, at a scrape every 30 seconds) before it counts: it FAILs when it
# differs on both reads while its records held still around each scrape, and
# WARNs when it differs on one; builds, which only grow, pass when the series
# lies within what the records said over both reads. Until the install's
# operator exports these series (ADR 0075 lane A), or under a --platform that
# has none, checks 1 to 5 SKIP.
#
# Read-only: kubectl get, and the store (VMSingle in monitoring) through the
# API server's service proxy, with no port-forward; the records pass through
# jq as they arrive, and only the counts and dollars are kept. --kubectl-arg
# <arg> (repeatable) adds an argument to every kubectl call, such as --server
# and --tls-server-name for a cluster reached by its address. --mask-tenants
# prints an org a self-service sign-up made, or whose kind is tenant, as
# tenant-<the first 6 hex of the SHA-256 of its name>, an org the records do
# not hold as org-<6 hex>, and those orgs' workflows and Products as
# workflow-<6 hex> and product-<6 hex>. No secret, token, person's name or
# email is printed. Runs against a cluster, never from CI.
# Needs: kubectl, jq; with --mask-tenants, sha256sum or shasum.
# =============================================================================
set -euo pipefail
usage='usage: scripts/telemetry-truth-check.sh <kube context> [--platform <name>] [--kubectl-arg <arg>]...
         [--mask-tenants] [--only <n,...>]'
help() {
  echo "$usage"
  awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"
}
case "${1:-}" in
  -h | --help) help; exit 0 ;;
  "" | -*) echo "$usage" >&2; exit 2 ;;
esac
CTX="$1"
shift
PLATFORM="" MASK="" ONLY=""
KARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --platform) PLATFORM="${2:?$usage}"; shift 2 ;;
    --platform=*) PLATFORM="${1#*=}"; shift ;;
    --kubectl-arg) KARGS+=("${2:?$usage}"); shift 2 ;;
    --kubectl-arg=*) KARGS+=("${1#*=}"); shift ;;
    --mask-tenants) MASK=1; shift ;;
    --only) ONLY="${2:?$usage}"; shift 2 ;;
    --only=*) ONLY="${1#*=}"; shift ;;
    -h | --help) help; exit 0 ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac
done
MON="${MON_NS:-monitoring}"
VMSINGLE=vmsingle-victoria-metrics-k8s-stack
VMAGENT=victoria-metrics-k8s-stack
DAYS=30
# A record's org, as the operator's orgOf reads it from the namespace.
JQ_DEFS='def orgof: if startswith("ir-org-") then .[7:] else . end;'
# The rows of one read, {c, org, k, ra, rb, s}: the records before the scrape,
# after it, and the series; and how a row compares (class): E equal, or
# between the records of a row that changed; D its records held still and the
# series differ; U its records changed and the series lie outside them.
# shellcheck disable=SC2016 # jq's own variables
JQ_CMP='def key: "\(.c)\t\(.org)\t\(.k | join("\t"))";
  def idx: map({key: key, value: .}) | from_entries;
  def zero($k): if $k == ["kind"] then "none" else 0 end;
  def rows($a; $b; $s): ($a | idx) as $A | ($b | idx) as $B | ($s | idx) as $S
    | [($A + $B + $S) | to_entries[] | .key as $key | .value as $row | zero($row.k) as $z
       | {c: $row.c, org: $row.org, k: $row.k, ra: ($A[$key].v // $z), rb: ($B[$key].v // $z), s: ($S[$key].v // $z)}];
  def class: if .ra == .rb then (if .s == .ra then "E" else "D" end)
    elif ([.ra, .rb, .s] | all(type == "number")) then (if .s >= ([.ra, .rb] | min) and .s <= ([.ra, .rb] | max) then "E" else "U" end)
    elif .s == .ra or .s == .rb then "E" else "U" end;'

k() { kubectl --context "$CTX" ${KARGS[@]+"${KARGS[@]}"} "$@"; }
die() {
  echo "telemetry-truth-check: $*" >&2
  exit 1
}
# wanted <n>: whether check n is among --only's (every check without --only).
wanted() { [ -z "$ONLY" ] || case ",$ONLY," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

case "$ONLY" in *[!0-9,]*) die "--only takes check numbers, as 1,3,6" ;; esac
for t in kubectl jq; do command -v "$t" >/dev/null || die "missing tool: $t"; done
if [ -n "$MASK" ]; then
  if command -v sha256sum >/dev/null; then sha() { sha256sum; }
  elif command -v shasum >/dev/null; then sha() { shasum -a 256; }
  else die "--mask-tenants needs sha256sum or shasum"; fi
fi
k get --raw /readyz >/dev/null 2>&1 || die "context $CTX does not answer"
inst="$(k get installations.infrared.darkshift.io -o json 2>/dev/null | jq -c '.items[0] // empty' || true)"
[ -n "$inst" ] || die "no Installation on $CTX"
INST_NAME="$(jq -r '.metadata.name' <<<"$inst")"

# The install's own platform, and the one its series carried before its
# Installation named a telemetry plane: the template's VMAgent labels every
# series platform (the Installation's telemetry platform, else the cluster's
# name) and cluster (the cluster's name).
agent="$(k -n "$MON" get vmagents.operator.victoriametrics.com -o json 2>/dev/null |
  jq -c --arg n "$VMAGENT" '[.items[] | select(.metadata.name == $n)] + [.items[] | select((.spec.externalLabels.platform // "") != "")]
    | first | .spec.externalLabels // {}' || echo '{}')"
FORMER="" note=""
if [ -n "$PLATFORM" ]; then
  from="--platform"
else
  PLATFORM="$(jq -r '.spec.observability.telemetry.platform // ""' <<<"$inst")" from="the Installation's telemetry platform"
  if [ -z "$PLATFORM" ]; then PLATFORM="$(jq -r '.platform // ""' <<<"$agent")" from="the VMAgent's external label"; fi
  if [ -z "$PLATFORM" ]; then
    PLATFORM="$(kubectl config view --minify --context "$CTX" ${KARGS[@]+"${KARGS[@]}"} -o jsonpath='{.contexts[0].context.cluster}' 2>/dev/null || true)"
    from="the context's cluster name"
  fi
  cluster="$(jq -r '.cluster // ""' <<<"$agent")"
  [ -z "$cluster" ] || [ "$cluster" = "$PLATFORM" ] || FORMER="$cluster"
  written="$(jq -r '.platform // ""' <<<"$agent")"
  [ -z "$written" ] || [ "$written" = "$PLATFORM" ] ||
    note="the stack's VMAgent still writes platform $written: the gitops repo has not taken the Installation's platform yet"
fi
[ -n "$PLATFORM" ] || die "no platform: the Installation, the VMAgent and the context name none; pass --platform"
case "$PLATFORM$FORMER" in *[!A-Za-z0-9._:-]*) die "platform '$PLATFORM' holds a character this check does not quote" ;; esac
SEL="platform=\"$PLATFORM\""

store() { k get --raw "/api/v1/namespaces/$MON/services/$VMSINGLE:8428/proxy$1" 2>/dev/null; }
[ "$(store /health || true)" = OK ] || die "the store $MON/$VMSINGLE does not answer /health through the API server's proxy"
enc() { jq -rn --arg s "$1" '$s | @uri'; }
# query <promql> [unix time]: an instant query's result vector, as JSON; fails
# when the store does not answer. latency_offset lets it see the last scrape,
# which VictoriaMetrics otherwise holds back for 30 seconds.
query() {
  local at=""
  [ -z "${2:-}" ] || at="&time=$2"
  store "/api/v1/query?query=$(enc "$1")$at&latency_offset=1s" | jq -ce 'select(.status == "success") | .data.result'
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# objects <resource> <jq filter> [kubectl args...]: the resource's objects
# across the cluster, reduced by the filter as kubectl hands them over, so no
# record is kept whole; dies when they cannot be listed.
objects() {
  local res=$1 filter=$2
  shift 2
  k get "$res" -A -o json "$@" 2>/dev/null | jq -c "$JQ_DEFS $filter" || die "could not list $res on $CTX"
}

# read_records <file>: the rows {c, org, k, v} of checks 1 to 5 that run, from
# the records, counted as the operator counts them.
read_records() {
  local f
  for f in runs rels cuts products repos images; do echo '[]' >"$work/$f.json"; done
  echo 0 >"$work/users.json"
  # shellcheck disable=SC2016 # the jq program's own variables
  objects organizations.infrared.darkshift.io '[.items[] | (.metadata.labels // {}) as $l
    | ($l["infrared.darkshift.io/org-kind"] // "") as $label | (($l["infrared.darkshift.io/self-service-owner"] // "") != "") as $self
    | {name: .metadata.name, self: $self,
       kind: (if .spec.platform == true then "platform" elif $label == "internal" or $label == "tenant" then $label
              elif $self then "tenant" else "internal" end)}]' >"$work/orgs.json"
  if wanted 1; then
    objects agentworkflowruns.infrared.darkshift.io '[.items[] | {org: (.metadata.namespace | orgof),
      k: [(.spec.workflowRef.name // ""), (if (.status.phase // "") == "" then "Queued" else .status.phase end)]}]' >"$work/runs.json"
  fi
  if wanted 2; then
    objects releases.infrared.darkshift.io '[.items[] | {org: (.metadata.namespace | orgof),
      k: [(.spec.productRef.name // ""), (if (.status.phase // "") == "" then "Pending" else .status.phase end)]}]' >"$work/rels.json"
  fi
  if wanted 3; then
    objects releasecuts.infrared.darkshift.io '[.items[] | {org: (.metadata.namespace | orgof),
      k: [(.spec.productRef.name // ""), (if (.status.phase // "") == "" then "Pending" else .status.phase end)]}]' >"$work/cuts.json"
  fi
  if wanted 4 || wanted 5; then
    objects products.infrared.darkshift.io '[.items[] | {ns: .metadata.namespace, org: (.metadata.namespace | orgof), name: .metadata.name,
      zones: (if .spec.delivery == null then [] else [.spec.delivery.zones[]? | (.public == true | tostring)] end)}]' >"$work/products.json"
  fi
  if wanted 4; then
    objects gitopsrepos.infrared.darkshift.io '[.items[] | select(.metadata.name == "gitops") | {ns: .metadata.namespace, mode: (.spec.mode // "")}]' >"$work/repos.json"
    # An install without kpack serves no Images, and the operator no builds.
    if k get --raw /apis/kpack.io >/dev/null 2>&1; then
      objects images.kpack.io '[.items[] | {ns: .metadata.namespace, p: (.metadata.labels["infrared.darkshift.io/product"] // ""),
        n: (.status.buildCounter // 0)}]' -l infrared.darkshift.io/product >"$work/images.json"
    fi
  fi
  if wanted 5; then objects users.infrared.darkshift.io '.items | length' >"$work/users.json"; fi
  jq -n --slurpfile orgs "$work/orgs.json" --slurpfile runs "$work/runs.json" --slurpfile rels "$work/rels.json" \
    --slurpfile cuts "$work/cuts.json" --slurpfile products "$work/products.json" --slurpfile repos "$work/repos.json" \
    --slurpfile images "$work/images.json" --slurpfile users "$work/users.json" --argjson five "$(wanted 5 && echo true || echo false)" '
    def counted($c): group_by([.org, .k]) | map({c: $c, org: .[0].org, k: .[0].k, v: length});
    ($runs[0] | counted(1)) + ($rels[0] | counted(2)) + ($cuts[0] | counted(3))
    # Builds: an Image counts for the Product its label names in the namespace
    # its org builds in, for every Product of that name there (buildsNamespaceOf).
    + (($repos[0] | map({key: .ns, value: .mode}) | from_entries) as $mode
       | ($images[0] | group_by([.ns, .p]) | map({key: "\(.[0].ns)/\(.[0].p)", value: (map(.n) | add)}) | from_entries) as $built
       | [$products[0][] | (if $mode[.ns] == "org" then "builds-" + .org else "builds" end) as $ns
          | $built["\($ns)/\(.name)"] as $n | select($n != null) | {org, k: [.name], n: $n}]
       | group_by([.org, .k]) | map({c: 4, org: .[0].org, k: .[0].k, v: (map(.n) | add)}))
    + (if $five then
         [{c: 5, org: "", k: ["users"], v: $users[0]}]
         + ($products[0] | group_by(.org) | map({c: 5, org: .[0].org, k: ["products"], v: length}))
         + ([$products[0][] | .org as $o | .zones[] | {org: $o, k: ["environments", .]}] | counted(5))
         + ($orgs[0] | map({c: 5, org: .name, k: ["kind"], v: .kind}))
       else [] end)' >"$1"
}

# series <promql> <jq filter>: the query's rows {c, org, k, v}, the filter
# reading its result vector; appended to the read's rows.
series() {
  local r
  r="$(query "$1")" || die "the store did not answer the query $1"
  jq -c "$2" <<<"$r" >>"$work/series.jsonl"
}
# read_series <file>: the rows of checks 1 to 5 that run, from the store, each
# series read as max by its own labels across the operator's pods.
read_series() {
  : >"$work/series.jsonl"
  local row='{org: (.metric.org // ""), v: (.value[1] | tonumber)}'
  if wanted 1; then series "max by (org, workflow, phase) (infrared_runs{$SEL})" ".[] | $row + {c: 1, k: [(.metric.workflow // \"\"), (.metric.phase // \"\")]}"; fi
  if wanted 2; then series "max by (org, product, phase) (infrared_deployments{$SEL})" ".[] | $row + {c: 2, k: [(.metric.product // \"\"), (.metric.phase // \"\")]}"; fi
  if wanted 3; then series "max by (org, product, phase) (infrared_releases{$SEL})" ".[] | $row + {c: 3, k: [(.metric.product // \"\"), (.metric.phase // \"\")]}"; fi
  if wanted 4; then series "max by (org, product) (infrared_builds{$SEL})" ".[] | $row + {c: 4, k: [(.metric.product // \"\")]}"; fi
  if wanted 5; then
    series "max(infrared_users{$SEL})" ".[] | $row + {c: 5, k: [\"users\"]}"
    series "max by (org) (infrared_org_products{$SEL})" ".[] | $row + {c: 5, k: [\"products\"]}"
    series "max by (org, public) (infrared_org_environments{$SEL})" ".[] | $row + {c: 5, k: [\"environments\", (.metric.public // \"\")]}"
    series "max by (org, kind) (infrared_org_info{$SEL})" \
      'group_by(.metric.org // "") | .[] | {c: 5, org: (.[0].metric.org // ""), k: ["kind"], v: (map(.metric.kind // "") | sort | join(","))}'
  fi
  jq -s '.' "$work/series.jsonl" >"$1"
}
# scraped_after <unix time>: waits up to 90 seconds until the store holds a
# scrape of every operator pod taken after that second.
scraped_after() {
  local t0=$SECONDS at
  while [ $((SECONDS - t0)) -le 90 ]; do
    at="$(query "min(max by (pod) (timestamp({__name__=~\"infrared_(users|org_info)\",$SEL})))" | jq -r '.[0].value[1] // empty' || true)"
    if [ -n "$at" ] && [ "${at%.*}" -gt "$1" ]; then
      sleep 2 # the rest of that scrape's samples
      return 0
    fi
    sleep 3
  done
  return 1
}
# read_once <n>: read n of checks 1 to 5: the records (rec<n>a.json), the
# store's first scrape of the operator after them (ser<n>.json), and the
# records again (rec<n>b.json).
read_once() {
  local t
  read_records "$work/rec${1}a.json"
  t="$(date +%s)"
  scraped_after "$t" || die "the store holds no scrape of the operator taken after the records were read, 90 s on: is the operator scraped?"
  read_series "$work/ser$1.json"
  read_records "$work/rec${1}b.json"
}
# unequal <n> [check]: how many rows of read n are not equal (of one check).
unequal() {
  jq -n --slurpfile a "$work/rec${1}a.json" --slurpfile b "$work/rec${1}b.json" --slurpfile s "$work/ser$1.json" --arg c "${2:-}" \
    "$JQ_CMP"' rows($a[0]; $b[0]; $s[0]) | map(select($c == "" or (.c | tostring) == $c) | select(class != "E")) | length'
}

echo "telemetry-truth-check: $CTX (Installation $INST_NAME, platform $PLATFORM from $from$([ -z "$FORMER" ] || echo ", and $FORMER before it named a telemetry plane")$([ -z "$MASK" ] || echo ", tenants masked"))"
[ -z "$note" ] || echo "        $note"

# --- checks 1 to 5: the records and the store, read once, and again when a
# row is not equal -------------------------------------------------------------
laneA=false wait=0 checks=""
for n in 1 2 3 4 5 6; do if wanted "$n"; then checks="$checks${checks:+,}$n"; fi; done
if wanted 1 || wanted 2 || wanted 3 || wanted 4 || wanted 5; then
  present="$(query "count({__name__=~\"infrared_(org_info|users|runs|deployments|releases|builds|org_products|org_environments)\",$SEL})")" ||
    die "the store did not answer"
  [ "$(jq 'length' <<<"$present")" = 0 ] || laneA=true
fi
if [ "$laneA" = true ]; then
  read_once 1
else
  read_records "$work/rec1a.json"
  cp "$work/rec1a.json" "$work/rec1b.json"
  echo '[]' >"$work/ser1.json"
fi
cp "$work/rec1a.json" "$work/rec2a.json"
cp "$work/rec1b.json" "$work/rec2b.json"
cp "$work/ser1.json" "$work/ser2.json"
reread=false
if [ "$laneA" = true ] && [ "$(unequal 1)" != 0 ]; then
  reread=true wait=60
  [ "$(unequal 1 4)" = 0 ] || wait=95
  echo "        $(unequal 1) row(s) not equal on the first read: reading the records and the store again in $wait s"
  sleep "$wait"
  read_once 2
fi

# --- check 6: thirty days of step spend ---------------------------------------
echo '[]' >"$work/spend.json"
now="$(date +%s)"
if wanted 6; then
  objects agentworkflowruns.infrared.darkshift.io '[.items[] | {org: (.metadata.namespace | orgof),
    steps: [.status.steps[]? | select((.agentRole // "") != "" and ((.attemptUsage // []) | length) > 0)
      | {fin: .finishedAt, rounds: [.rounds[]? | select((.attempts // 0) > 0) | .finishedAt],
         att: [.attemptUsage[] | [(.attempt // 0), ((.usage.costUSD // "0") | tonumber? // 0)]]}]}
    | select(.steps | length > 0)]' >"$work/steps.json"
  # Each attempt is dated at the first finish the record holds from its round
  # on: the round's, a later round's, its step's, else now. Attempt numbers
  # start again at each round and each retry, so the n-th run of them ended
  # by the n-th round, or later where a person retried the step.
  jq -c --argjson now "$now" --argjson since "$((now - DAYS * 86400))" '
    def at: if . == null then null else sub("\\.[0-9]+"; "") | fromdateiso8601 end;
    [.[] | .org as $org | .steps[] | (.fin | at) as $fin | [.rounds[] | at] as $rounds | .att as $att
      | (reduce range(1; $att | length) as $i ([0]; . + [.[-1] + (if $att[$i][0] <= $att[$i - 1][0] then 1 else 0 end)])) as $run
      | range(0; $att | length) as $i
      | ([$rounds[$run[$i]:][] | select(. != null)] + [$fin, $now] | map(select(. != null)) | first) as $when
      | select($when > $since) | {org: $org, usd: $att[$i][1]}]
    | group_by(.org) | map({org: .[0].org, r: (map(.usd) | add)})' "$work/steps.json" >"$work/spend-records.json"
  query "sum by (org) (increase_pure(infrared_step_cost_usd_total{$SEL}[${DAYS}d]))" "$now" >"$work/spend-series.json" ||
    die "the store did not answer the step spend query"
  echo '[]' >"$work/spend-former.json"
  if [ -n "$FORMER" ]; then
    query "sum by (org) (increase_pure(infrared_step_cost_usd_total{platform=\"$FORMER\",cluster=\"$FORMER\"}[${DAYS}d]))" "$now" \
      >"$work/spend-former.json" || die "the store did not answer the step spend query"
  fi
  jq -n --slurpfile r "$work/spend-records.json" --slurpfile p "$work/spend-series.json" --slurpfile f "$work/spend-former.json" '
    def byorg: map({key: (.metric.org // ""), value: (.value[1] | tonumber)}) | from_entries;
    ($r[0] | map({key: .org, value: .r}) | from_entries) as $R | ($p[0] | byorg) as $P | ($f[0] | byorg) as $F
    | [($R + $P + $F) | keys[] | {org: ., r: ($R[.] // 0), sp: ($P[.] // 0), sf: ($F[.] // 0)}]' >"$work/spend.json"
fi

# --- names: a tenant's, with --mask-tenants, only ever as a hash -------------
echo '{"orgs": {}, "workflows": {}, "products": {}}' >"$work/mask.json"
if [ -n "$MASK" ]; then
  jq -rn --slurpfile orgs "$work/orgs.json" --slurpfile spend "$work/spend.json" \
    --slurpfile a "$work/rec1a.json" --slurpfile b "$work/rec1b.json" --slurpfile c "$work/ser1.json" \
    --slurpfile d "$work/rec2a.json" --slurpfile e "$work/rec2b.json" --slurpfile f "$work/ser2.json" '
    ($a[0] + $b[0] + $c[0] + $d[0] + $e[0] + $f[0]) as $rows
    | ($orgs[0] | map(select(.self or .kind == "tenant") | .name)
       + [$rows[] | select(.c == 5 and .k == ["kind"] and (.v | tostring | test("tenant"))) | .org]) as $tenants
    | ($orgs[0] | map(.name)) as $known
    | ([$rows[].org, $spend[0][].org] + $known | unique | map(select(. != ""))) as $all
    | ([$all[] | select(. as $o | $tenants | any(. == $o))]) as $t
    | ([$all[] | select(. as $o | ($known | any(. == $o)) | not)] - $t) as $u
    | ($t[] | "orgs\ttenant\t\(.)"), ($u[] | "orgs\torg\t\(.)"),
      ([$rows[] | select(.org as $o | $t + $u | any(. == $o)) | select(.c >= 1 and .c <= 4) | [.c, .k[0]]] | unique | .[]
       | if .[0] == 1 then "workflows\tworkflow\t\(.[1])" else "products\tproduct\t\(.[1])" end)' >"$work/to-mask.tsv"
  while IFS="$(printf '\t')" read -r map prefix name; do
    printf '%s\t%s\t%s-%s\n' "$map" "$name" "$prefix" "$(printf '%s' "$name" | sha | cut -c1-6)"
  done <"$work/to-mask.tsv" | jq -Rn '[inputs | split("\t")] | reduce .[] as $m ({"orgs": {}, "workflows": {}, "products": {}};
    .[$m[0]][$m[1]] = $m[2])' >"$work/mask.json"
fi

# --- the table and the checks -------------------------------------------------
jq -rn --slurpfile orgs "$work/orgs.json" --slurpfile spend "$work/spend.json" --slurpfile mask "$work/mask.json" \
  --slurpfile rec1a "$work/rec1a.json" --slurpfile rec1b "$work/rec1b.json" --slurpfile ser1 "$work/ser1.json" \
  --slurpfile rec2a "$work/rec2a.json" --slurpfile rec2b "$work/rec2b.json" --slurpfile ser2 "$work/ser2.json" \
  --argjson laneA "$laneA" --argjson reread "$reread" --argjson wait "$wait" --argjson now "$now" --argjson days "$DAYS" \
  --arg checks "$checks" --arg platform "$PLATFORM" --arg former "$FORMER" --arg apos "'" "$JQ_CMP"'
  def num: if type == "number" then . else 0 end;
  def fmt: if type == "number" and . != floor then (. * 100 | round / 100 | tostring) else tostring end;
  def usd: (. * 100 | round) as $c | "\($c / 100 | floor).\($c % 100 | tostring | if length < 2 then "0" + . else . end)";
  def wants($c): $checks | split(",") | any(. == ($c | tostring));
  def count($n; $one): "\($n | fmt) \($one)\(if $n == 1 then "" else "s" end)";
  ($mask[0]) as $mask | ($orgs[0] | map({key: .name, value: .kind}) | from_entries) as $kinds
  | def masked: $mask.orgs[.] != null;
    def shown: if . == "" then "(install)" else ($mask.orgs[.] // .) end;
    def rank: {"platform": 0, "internal": 1, "tenant": 2}[$kinds[.] // ""] // 3;
    def order: sort_by([(.org | rank), (.org | shown)]);
    def name($c; $org): if ($org | masked) then (if $c == 1 then $mask.workflows[.] else $mask.products[.] end) // "?" else . end;
    def shown_k($c; $org):
      if $c == 1 or $c == 2 or $c == 3 then (.[0] | name($c; $org)) + " " + .[1]
      elif $c == 4 then .[0] | name($c; $org)
      elif .[0] == "products" then "Products"
      elif .[0] == "environments" then "environments (public \(.[1]))"
      elif .[0] == "users" then "Users"
      else .[0] end;
    def table: (transpose | map(map(length) | max)) as $w
      | .[] | [range(0; length) as $i | .[$i] + (" " * ($w[$i] - (.[$i] | length) + 2))] | add | sub(" +$"; "");
  # Each row of checks 1 to 5 over both reads, and its verdict.
  (if $laneA then
     (rows($rec1a[0]; $rec1b[0]; $ser1[0]) | map({key: key, value: .}) | from_entries) as $one
     | (rows($rec2a[0]; $rec2b[0]; $ser2[0]) | map({key: key, value: .}) | from_entries) as $two
     | [($one + $two) | keys[] as $key | ($one[$key] // $two[$key]) as $row | zero($row.k) as $z
        | ($one[$key] // {ra: $z, rb: $z, s: $z}) as $x | ($two[$key] // {ra: $z, rb: $z, s: $z}) as $y
        | {c: $row.c, org: $row.org, k: $row.k, r1a: $x.ra, r1b: $x.rb, s1: $x.s, r2a: $y.ra, r2b: $y.rb, s2: $y.s,
           k1: ($x | class), k2: ($y | class)}
        | .verdict = (if .c == 4 then
                        ([.r1a, .r1b, .r2a, .r2b]) as $r
                        | (if ($reread | not) or (.s2 >= ($r | min) and .s2 <= ($r | max)) then "ok" elif .k1 == "E" then "WARN" else "FAIL" end)
                      elif .k2 == "E" then "ok"
                      elif .k2 == "D" then (if .k1 == "D" then "FAIL" else "WARN" end)
                      elif .k1 == "E" then "ok" else "WARN" end)]
   else [$rec1a[0][] | {c, org, k, r1a: .v, r1b: .v, r2a: .v, r2b: .v, s1: null, s2: null, k1: "E", k2: "E", verdict: "ok"}] end) as $v
  | ($spend[0] | map(.s = .sp + .sf | ([.r, .s] | max) as $m | ((.r - .s) | if . < 0 then -. else . end) as $d
      | .pct = (if $m == 0 then 0 else ($d * 1000 / $m | round / 10) end)
      | .verdict = (if $d <= ([0.05 * $m, 0.01] | max) then "ok" else "WARN" end))) as $spend
  | def cell($c; $org; f): ($v | map(select(.c == $c and .org == $org and (.k | f)))) as $rs
      | (($rs | map(.r2b | num) | add // 0) | fmt) + "/" + (if $laneA then (($rs | map(.s2 | num) | add // 0) | fmt) else "-" end)
        + (if $rs | any(.verdict != "ok") then " *" else "" end);
    def nouns: {"1": "run", "2": "Release", "3": "ReleaseCut", "4": "build"};
    def per: {"1": "workflow and phase row", "2": "Product and phase row", "3": "Product and phase row", "4": "Product"};
    def titles: {
      "1": "AgentWorkflowRuns by org, workflow and phase equal infrared_runs",
      "2": "Releases (deployments) by org, Product and phase equal infrared_deployments",
      "3": "ReleaseCuts (releases) by org, Product and phase equal infrared_releases",
      "4": "Builds by org and Product, the buildCounter of their kpack Images added up, equal infrared_builds",
      "5": "Users, and the Products, environments and kind of each org, equal infrared_users, infrared_org_products, infrared_org_environments and infrared_org_info",
      "6": "\($days) days of agent-step spend by org, the records of the runs against infrared_step_cost_usd_total, within 5 percent"};
    def names: {"1": "infrared_runs", "2": "infrared_deployments", "3": "infrared_releases", "4": "infrared_builds",
      "5": "infrared_users, infrared_org_products, infrared_org_environments or infrared_org_info"};
    def skipped($c): "  SKIP  the install\($apos)s operator does not export \(names[$c | tostring]) yet (ADR 0075 lane A): the store holds no series of lane A under platform \($platform)";
    def problem($org): . as $row | ([.r1a, .r1b, .r2a, .r2b]) as $r
      | "  \(.verdict)  \($org | shown): \(.k | shown_k($row.c; $org)): "
        + (if .c == 4 then "series \(.s2 | fmt), outside what the records said over both reads, \($r | min | fmt) to \($r | max | fmt)"
                           + (if .verdict == "WARN" then ", equal on the first read" else "" end)
           elif .k2 == "U" then "the records went from \(.r2a | fmt) to \(.r2b | fmt) around the scrape, the series said \(.s2 | fmt)"
           else "records \(.r2b | fmt), series \(.s2 | fmt)" end)
        + (if .c == 4 then ""
           elif .verdict == "FAIL" then "; \($wait) s earlier, records \(.r1b | fmt), series \(.s1 | fmt): the records held still around both scrapes"
           elif .k1 == "E" then ", equal on the first read: a record changed close to the scrape"
           else "; \($wait) s earlier, records \(.r1a | fmt) to \(.r1b | fmt), series \(.s1 | fmt)" end);
    def again: if any(.k1 != "E") then ", on the second read" else "" end;
    def section($c):
      "", "== \($c). \(titles[$c | tostring])",
      (if ($laneA | not) then skipped($c)
       else ($v | map(select(.c == $c))) as $rows
       | if ($rows | length) == 0 then "  ok    no \(nouns[$c | tostring])s on either side"
         else ($rows | group_by(.org) | map({org: .[0].org, rows: .}) | order[]) as $o
         | ($o.rows | map(select(.verdict != "ok"))) as $bad
         | if ($bad | length) == 0 then
             "  ok    \($o.org | shown): \(count($o.rows | map(.r2b | num) | add; nouns[$c | tostring])) in \(count($o.rows | length; per[$c | tostring])), equal\($o.rows | again)"
           else $bad[] | problem($o.org) end
         end
       end);
    def section5:
      "", "== 5. \(titles["5"])",
      (if ($laneA | not) then skipped(5)
       else ($v | map(select(.c == 5))) as $rows
       | ($rows | map(select(.org == "")) | .[] | if .verdict == "ok" then "  ok    \(count(.r2b; "User")), equal\([.] | again)" else problem("") end),
         (($rows | map(select(.org != "")) | group_by(.org) | map({org: .[0].org, rows: .}) | order[]) as $o
          | ($o.rows | map(select(.verdict != "ok"))) as $bad
          | if ($bad | length) == 0 then
              ($o.rows | map(select(.k[0] == "environments"))) as $env
              | "  ok    \($o.org | shown): kind \($o.rows | map(select(.k == ["kind"]) | .r2b) | first // "none"), "
                + "\(count($o.rows | map(select(.k == ["products"]) | .r2b) | add // 0; "Product")), "
                + "\(count($env | map(.r2b) | add // 0; "environment")) (\($env | map(select(.k[1] == "true") | .r2b) | add // 0) public), equal\($o.rows | again)"
            else $bad[] | problem($o.org) end)
       end);
    def section6:
      "", "== 6. \(titles["6"])",
      "        each attempt dated at the finish of its round or its step, from \($now - $days * 86400 | todate) to \($now | todate)",
      (if $former != "" then "        the series count platform \($former) too: the series of this install before its Installation named a telemetry plane" else empty end),
      (if ($spend | length) == 0 then "  ok    no agent-step spend in \($days) days on either side"
       else ($spend | order[]
             | "  \(if .verdict == "ok" then "ok  " else "WARN" end)  \(.org | shown): USD \(.r | usd) by the records, USD \(.s | usd) by the series, \(.pct) percent apart"
               + (if .verdict == "ok" then ""
                  elif .s == 0 then ", over 5: the store holds no step spend of the org under platform \($platform) in the window"
                  elif .r > .s then ", over 5: a step dated at its last finish, or a store that lost samples"
                  else ", over 5: attempts the records no longer hold (a run deleted), or a counter older than the window" end)
               + (if .sf > 0 then " (USD \(.sf | usd) of the series under \($former))" else "" end)),
            "        all orgs: USD \($spend | map(.r) | add | usd) by the records, USD \($spend | map(.s) | add | usd) by the series"
       end);
  # The table: every org the records or the store name.
  ([$orgs[0][].name, $v[].org, $spend[].org] | unique | map(select(. != "")) | map({org: .}) | order | map(.org)) as $all
  | ([$spend[] | {key: .org, value: .}] | from_entries) as $spent
  | "", "The records and the store, org by org (records/series; * where a row differs):", "",
    ([["org", "kind"] + (if wants(1) then ["runs"] else [] end) + (if wants(2) then ["deployments"] else [] end)
       + (if wants(3) then ["releases"] else [] end) + (if wants(4) then ["builds"] else [] end)
       + (if wants(5) then ["products", "environments"] else [] end) + (if wants(6) then ["spend \($days)d USD"] else [] end)]
     + [$all[] as $org
        | [($org | shown),
           (($kinds[$org] // "none") + (if wants(5) and $laneA then "/" + ($v | map(select(.c == 5 and .org == $org and .k == ["kind"]) | .s2) | first // "none")
                                         + (if $v | any(.c == 5 and .org == $org and .k == ["kind"] and .verdict != "ok") then " *" else "" end)
                                       else "" end))]
          + (if wants(1) then [cell(1; $org; true)] else [] end) + (if wants(2) then [cell(2; $org; true)] else [] end)
          + (if wants(3) then [cell(3; $org; true)] else [] end) + (if wants(4) then [cell(4; $org; true)] else [] end)
          + (if wants(5) then [cell(5; $org; .[0] == "products"), cell(5; $org; .[0] == "environments")] else [] end)
          + (if wants(6) then [($spent[$org] // {r: 0, s: 0, verdict: "ok"}) | "\(.r | usd)/\(.s | usd)\(if .verdict == "ok" then "" else " *" end)"] else [] end)]
     | table | "  " + .),
    (if wants(5) then "", "  Users of the install, which belong to no org: \(cell(5; ""; .[0] == "users"))" else empty end),
    (if wants(1) then section(1) else empty end), (if wants(2) then section(2) else empty end),
    (if wants(3) then section(3) else empty end), (if wants(4) then section(4) else empty end),
    (if wants(5) then section5 else empty end), (if wants(6) then section6 else empty end)' >"$work/report.txt"
cat "$work/report.txt"
fails="$(grep -c '^  FAIL' "$work/report.txt" || true)"
warns="$(grep -c '^  WARN' "$work/report.txt" || true)"
skips="$(grep -c '^  SKIP' "$work/report.txt" || true)"
echo
echo "telemetry-truth-check: $fails failed, $warns warned, $skips skipped on $CTX"
[ "$fails" = 0 ] || exit "$fails"
