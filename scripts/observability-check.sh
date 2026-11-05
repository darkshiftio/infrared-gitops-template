#!/usr/bin/env bash
# =============================================================================
# observability-check.sh <kube context> [options]: an install's monitoring
# works end to end, on a running install (infrared-docs-internal ADR 0069
# T11; README "Checks on a running install").
# =============================================================================
# Thirteen numbered checks, each printing ok, FAIL, WARN or SKIP with its
# reason. The exit status is the number of FAILs. --only 1,3,8 runs a subset.
#
#   1. stack up: VMSingle, vmagent, vmalert, Alertmanager and Grafana are
#      Ready, VMSingle answers /health, its retention is 30d, and its data is
#      on a claim (an emptyDir is WARN on k3s, FAIL on a cloud);
#   2. targets: up is 1 for the API and the operator through the scrape
#      infrared-metrics, by the job label the series carry;
#   3. series present: every metric name the panels of every dashboard
#      ConfigMap read (a name followed by a selector or a range) has a sample
#      in the last 10 minutes. For the template's own dashboards (ConfigMaps
#      infrared-*): a name of lane A's new series (the install and the model
#      calls) SKIPs until the release that brings it; a series only a
#      connected Mac, a runner pool, an agent run or a writer to this plane
#      produces WARNs; any other absence FAILs. The chart's own dashboards'
#      absences are one WARN, since the template does not own them;
#   4. label hygiene: no label value in the store matches a token (sk-ant-,
#      irt_, ghp_, gho_, AKIA, xox[abp]-), an email, or a path (/Users/,
#      /home/ but GKE's own /home/kubernetes/, /private/): ADR 0044's sweep
#      as code. A match names the label, never the value;
#   5. alert path (--alert-path, with --api and --token-file): a synthetic
#      alert for the platform org's first Product opens an Incident through
#      the API within 90 seconds, and the same alert with an endsAt resolves
#      it (the route's group_interval decides when, up to 6 minutes);
#   6. platform route: Alertmanager's root receiver is infrared-platform, a
#      webhook to the API's /v1/webhooks/alertmanager/_platform (the name and
#      the webhook from Alertmanager's own status, the path from the metrics
#      stack Application's rendered values, since Alertmanager redacts a
#      webhook's URL). FAILs on today's installs until
#      infrared-gitops-template's install telemetry template lands;
#   7. rules loaded: vmalert lists every group of every VMRule, the ones the
#      operator wrote for Products among them, and the platform VMRule's
#      (SKIP until the template above lands);
#   8. dashboards: Grafana lists every dashboard ConfigMap by its uid, the
#      Fleet dashboard among them, and each loads;
#   9. Grafana's sign-in: with Grafana's OAuth on, /login/generic_oauth sends
#      the browser to the install's /api/v1/oidc/authorize (SKIP when off);
#  10. telemetry out: the Installation names a plane, the token's Secret
#      monitoring/telemetry-token is there, and the vmagent's accepted writes
#      grow over 60 seconds; with --plane and --platform, the plane's store
#      holds a sample of this install's under 2 minutes old (SKIP when the
#      Installation names no plane);
#  11. opt-out (--opt-out-test, with --api, --token-file and --plane): PUT
#      /v1/telemetry off, then over 10 minutes the Secret stays gone and the
#      plane's count of this install's writes stays flat; then on again, and
#      a first accepted write within 3 minutes. Telemetry pauses for those 10
#      minutes, which it says before it starts;
#  12. backup: on Google Cloud, the CronJob metrics-backup's last success is
#      under 26 hours old (SKIP where the copy does not render);
#  13. Bedrock: with INFRARED_BEDROCK on the operator, model calls and cost
#      are counted on provider bedrock (SKIP when off, or until the release
#      that brings the series).
#
# It reads the store, vmalert and Alertmanager through the API server's proxy
# (kubectl get --raw), Grafana through a port-forward with the admin password
# read from Grafana's Secret into curl's config, and Infrared's API with the
# bearer token in --token-file (one line, mode 600) the same way; no password
# or token is printed. It makes nothing but the port-forward and, with
# --alert-path, one synthetic alert, which it resolves itself, so KEEP=1
# means nothing here. Runs against a cluster, never from CI.
# Needs: kubectl, jq, yq (mikefarah v4, for Alertmanager's config), curl.
# =============================================================================
set -euo pipefail
usage='usage: scripts/observability-check.sh <kube context> [--api <url>] [--token-file <file>]
         [--plane <home context> --platform <name>] [--alert-path] [--opt-out-test] [--only <n,...>]'
CTX="${1:?$usage}"
shift
API="" TOKEN_FILE="" PLANE="" PLATFORM="" ALERT_PATH="" OPT_OUT="" ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --api) API="${2:?$usage}"; shift 2 ;;
    --token-file) TOKEN_FILE="${2:?$usage}"; shift 2 ;;
    --plane) PLANE="${2:?$usage}"; shift 2 ;;
    --platform) PLATFORM="${2:?$usage}"; shift 2 ;;
    --alert-path) ALERT_PATH=1; shift ;;
    --opt-out-test) OPT_OUT=1; shift ;;
    --only) ONLY="${2:?$usage}"; shift 2 ;;
    -h | --help) echo "$usage"; sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac
done
MON="${MON_NS:-monitoring}"
INFRARED_NS="${INFRARED_NS:-infrared}"
VMSINGLE=vmsingle-victoria-metrics-k8s-stack
VMAGENT=vmagent-victoria-metrics-k8s-stack
VMALERT=vmalert-victoria-metrics-k8s-stack
ALERTMANAGER=vmalertmanager-victoria-metrics-k8s-stack
GRAFANA=victoria-metrics-k8s-stack-grafana
# Lane A's series (infrared-operator, the install and the model calls): absent
# until the release that carries them, so check 3 and 13 SKIP, never FAIL.
LANE_A_SERIES="infrared_install_info infrared_installation_ready infrared_installation_created_timestamp_seconds infrared_orgs_total infrared_products_total infrared_humans_total infrared_cloud_accounts infrared_org_model_provider infrared_incidents_open infrared_model_calls_total infrared_model_call_seconds_total"
LANE_A_NOTE="comes with infrared-operator's release that carries the install and model-call series (ADR 0069 T7, lane A)"

k() { kubectl --context "$CTX" "$@"; }
kp() { kubectl --context "$PLANE" "$@"; }
log() { printf '\n== %s\n' "$*"; }
die() {
  echo "observability-check: $*" >&2
  exit 1
}
fails=0 warns=0 skips=0
pass() { echo "  ok    $*"; }
fail() {
  echo "  FAIL  $*"
  fails=$((fails + 1))
}
warn() {
  echo "  WARN  $*"
  warns=$((warns + 1))
}
skip() {
  echo "  SKIP  $*"
  skips=$((skips + 1))
}
# runs <n>: whether check n is among --only's (every check without --only).
runs() { [ -z "$ONLY" ] || case ",$ONLY," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

for t in kubectl jq yq curl; do command -v "$t" >/dev/null || die "missing tool: $t"; done
k get --raw /readyz >/dev/null 2>&1 || die "context $CTX does not answer"
if [ -n "$PLANE" ] || [ -n "$PLATFORM" ]; then
  [ -n "$PLANE" ] && [ -n "$PLATFORM" ] || die "--plane and --platform go together"
  kp get --raw /readyz >/dev/null 2>&1 || die "the plane's context $PLANE does not answer"
fi
if [ -n "$TOKEN_FILE" ]; then
  [ -s "$TOKEN_FILE" ] || die "no token in $TOKEN_FILE"
  mode="$(stat -f %Lp "$TOKEN_FILE" 2>/dev/null || stat -c %a "$TOKEN_FILE")"
  [ "$mode" = 600 ] || die "$TOKEN_FILE is mode $mode, want 600: it holds a token"
  [ "$(wc -l <"$TOKEN_FILE" | tr -d ' ')" -le 1 ] || die "$TOKEN_FILE holds more than one line, want the token alone"
fi
inst="$(k get installations.infrared.darkshift.io -o json 2>/dev/null | jq -c '.items[0] // empty')"
[ -n "$inst" ] || die "no Installation on $CTX"
INST_NAME="$(jq -r '.metadata.name' <<<"$inst")"
if [ -z "$API" ]; then
  API="$(jq -r '.spec.previews.signInURL // "" | rtrimstr("/")' <<<"$inst")"
  [ -z "$API" ] || API="$API/api"
fi
API="${API%/}"
# needs_api <check>: true when the check may call Infrared's API; else SKIP.
needs_api() {
  if [ -z "$TOKEN_FILE" ]; then skip "$1 needs --token-file (and --api, unless the Installation has previews)"; return 1; fi
  if [ -z "$API" ]; then skip "$1 needs --api: the Installation names no sign-in URL to derive it from"; return 1; fi
  return 0
}

work="$(mktemp -d)"
pfs=""
alert_posted=""
cleanup() {
  local rc=$? p
  set +e
  # A synthetic alert this run left firing is resolved on the way out.
  if [ -n "$alert_posted" ]; then post_alert "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null 2>&1; fi
  for p in $pfs; do
    kill "$p" 2>/dev/null
    wait "$p" 2>/dev/null
  done
  rm -rf "$work"
  exit "$rc"
}
trap cleanup EXIT

# enc <text>: URL-encoded, for a query string.
enc() { jq -rn --arg s "$1" '$s | @uri'; }
# raw <context> <service> <port> <path>: one GET through the API server's proxy
# to a Service in monitoring; nothing on an error.
raw() { kubectl --context "$1" get --raw "/api/v1/namespaces/$MON/services/$2:$3/proxy$4" 2>/dev/null || true; }
vm() { raw "$CTX" "$VMSINGLE" 8428 "$1"; }
# scalar <promql> [context]: the first value an instant query yields, or
# nothing (no series, or no store).
scalar() { raw "${2:-$CTX}" "$VMSINGLE" 8428 "/api/v1/query?query=$(enc "$1")" | jq -r '.data.result[0].value[1] // empty' 2>/dev/null || true; }
# forward <service> <port>: a port-forward to the Service in monitoring on a
# free local port, left in $port.
forward() {
  local out="$work/forward-$1"
  k -n "$MON" port-forward "service/$1" ":$2" >"$out" 2>&1 &
  pfs="$pfs $!"
  port=""
  for _ in $(seq 1 30); do
    port="$(awk '/^Forwarding from 127\.0\.0\.1:/ { split($3, a, ":"); print a[2]; exit }' "$out")"
    [ -n "$port" ] && return 0
    sleep 1
  done
  return 1
}
# grafana_login: curl's config, for stdin, that signs in as Grafana's admin
# from its Secret; the password never reaches a command line or the output.
grafana_login() {
  local s
  s="$(k -n "$MON" get secret "$GRAFANA" -o json)"
  printf 'user = "'
  {
    jq -r '.data["admin-user"]' <<<"$s" | base64 -d
    printf ':'
    jq -r '.data["admin-password"]' <<<"$s" | base64 -d
  } | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n'
  printf '"\n'
}
# grafana <path>: one GET to Grafana through the port-forward as its admin;
# the body, then the HTTP status on a line of its own.
grafana() { grafana_login | curl -sS -K - --max-time 60 -w '\n%{http_code}' "http://127.0.0.1:$gport$1"; }
# api <method> <path> [curl args...]: one call to Infrared's API with the
# token, which reaches curl as its config on stdin. The body, then the HTTP
# status on a line of its own.
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
# op_env <name>: the operator's setting from its Deployment's environment.
op_env() {
  k -n "$INFRARED_NS" get deployment infrared-operator -o json 2>/dev/null |
    jq -r --arg n "$1" '.spec.template.spec.containers[] | select(.name == "operator") | .env[]? | select(.name == $n) | .value // empty'
}
# epoch <RFC 3339>: seconds since the epoch, or nothing.
epoch() { jq -rn --arg t "$1" '$t | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch empty'; }
# accepted_writes: the vmagent's count of writes the plane accepted, read from
# its own /metrics through the API server's proxy, so it works with the stack
# (the stack's vmagent, after the install telemetry template) and without it
# (the telemetry component's vmagent). Writes to the stack's own store are
# left out: after the template they name VMSingle's URL, before it they are
# the first URL, 1:secret-url.
accepted_writes() {
  local pod dep=vmagent
  k -n "$MON" get deployment vmagent >/dev/null 2>&1 || dep="$VMAGENT"
  pod="$(k -n "$MON" get pods -l "app.kubernetes.io/name=vmagent" -o json 2>/dev/null |
    jq -r --arg d "$dep" '[.items[] | select(.metadata.name | startswith($d + "-")) | select(.status.phase == "Running") | .metadata.name][0] // empty')"
  [ -n "$pod" ] || return 1
  k get --raw "/api/v1/namespaces/$MON/pods/$pod:8429/proxy/metrics" 2>/dev/null |
    awk -v stack="$([ "$dep" = vmagent ] && echo 0 || echo 1)" '
      /^vmagent_remotewrite_requests_total\{/ && /status_code="2XX"/ {
        if (stack && (index($0, "vmsingle-") || index($0, "url=\"1:secret-url\""))) next
        sum += $NF
      }
      END { printf "%d\n", sum }'
}
# post_alert [endsAt]: the synthetic alert to Alertmanager through its
# port-forward; with an endsAt it resolves. Prints the HTTP status.
post_alert() {
  local ends="${1:-}"
  jq -n --arg org "$PLATFORM_ORG" --arg p "$PRODUCT" --arg z "$ZONE" --arg id "$STAMP" --arg ends "$ends" '
    [{labels: {alertname: "ObservabilityCheck", severity: "warning", namespace: ("ir-org-" + $org), infrared_product: $p, infrared_zone: $z, observability_check: $id},
      annotations: {summary: "observability-check.sh: a synthetic alert to prove the path to an Incident; it resolves itself"}}
     + (if $ends == "" then {} else {endsAt: $ends} end)]' |
    curl -sS -o /dev/null -w '%{http_code}' --max-time 30 -X POST -H 'Content-Type: application/json' \
      --data-binary @- "http://127.0.0.1:$amport/api/v2/alerts" || echo 000
}

STAMP="$(date -u +%Y%m%d-%H%M%S)"
echo "observability-check: $CTX (Installation $INST_NAME$([ -n "$API" ] && echo ", API $API")$([ -n "$PLANE" ] && echo ", plane $PLANE as $PLATFORM"))"

# --- 1. stack up ---------------------------------------------------------------
stack=1
log "1. The metrics stack is up"
if runs 1 && ! k -n "$MON" get "deployment/$VMSINGLE" >/dev/null 2>&1; then
  fail "no metrics stack on $CTX (no deployment/$VMSINGLE in $MON): victoria-metrics-k8s-stack is among the Installation's disabled components, or not synced; checks 2 to 9 and 13 cannot run"
elif runs 1; then
  for w in "deployment/$VMSINGLE" "deployment/$VMAGENT" "deployment/$VMALERT" "statefulset/$ALERTMANAGER" "deployment/$GRAFANA"; do
    ready="$(k -n "$MON" get "$w" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo missing)"
    case "$ready" in
      missing) fail "$w is not there: the metrics stack is off (victoria-metrics-k8s-stack among the disabled components) or not synced" ;;
      "" | 0) fail "$w has no Ready replica" ;;
      *) pass "$w: $ready Ready" ;;
    esac
  done
  if [ "$(vm /health)" = OK ]; then pass "VMSingle answers /health"; else fail "VMSingle does not answer /health through the API server's proxy"; fi
  vms="$(k -n "$MON" get vmsingles.operator.victoriametrics.com victoria-metrics-k8s-stack -o json 2>/dev/null || true)"
  if [ -z "$vms" ]; then
    fail "no VMSingle object victoria-metrics-k8s-stack in $MON"
  else
    retention="$(jq -r '.spec.retentionPeriod // ""' <<<"$vms")"
    if [ "$retention" = 30d ]; then pass "retention 30d"; else fail "retention '$retention', want 30d"; fi
    provider="$(k get nodes -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null || true)"
    case "$provider" in
      k3s://*) where=k3s ;;
      gce://*) where="Google Cloud" ;;
      aws://*) where=AWS ;;
      linode://*) where=Linode ;;
      *) where="an unknown provider (${provider:-no providerID})" ;;
    esac
    if [ "$(jq -r '.spec.storage.resources.requests.storage // ""' <<<"$vms")" = 0 ] &&
      [ "$(jq -r '[.spec.volumes[]? | select(.name == "data") | has("emptyDir")] | any' <<<"$vms")" = true ]; then
      if [ "$where" = k3s ]; then
        warn "the data is on an emptyDir on $where: the metrics start empty after a node loss or a pod restart (README, Metrics with the stores)"
      else
        fail "the data is on an emptyDir on $where, want a PersistentVolumeClaim"
      fi
    else
      pvc="$(k -n "$MON" get pvc "$VMSINGLE" -o json 2>/dev/null || true)"
      if [ "$(jq -r '.status.phase // ""' <<<"$pvc")" = Bound ]; then
        pass "the data is on the claim $VMSINGLE ($(jq -r '.status.capacity.storage // "?"' <<<"$pvc"), class $(jq -r '.spec.storageClassName // "default"' <<<"$pvc")) on $where"
      else
        fail "the claim $VMSINGLE is not Bound ('$(jq -r '.status.phase // "missing"' <<<"$pvc")')"
      fi
    fi
  fi
fi
k -n "$MON" get "deployment/$VMSINGLE" >/dev/null 2>&1 || stack=""
no_stack="no metrics stack on $CTX (see 1)"

# --- 2. targets -----------------------------------------------------------------
log "2. The API and the operator are scraped"
if runs 2; then
  if [ -z "$stack" ]; then skip "$no_stack"; else
    ups="$(vm "/api/v1/query?query=$(enc "up{namespace=\"$INFRARED_NS\"}")" | jq -c '[.data.result[]? | {job: .metric.job, service: (.metric.service // ""), pod: (.metric.pod // ""), up: .value[1]}]' 2>/dev/null || echo '[]')"
    for what in api operator; do
      hit="$(jq -r --arg w "$what" '[.[] | select((.service + " " + .pod + " " + .job) | test("infrared-" + $w))] | first // empty | "\(.up) \(.job) \(.service)"' <<<"$ups")"
      case "$hit" in
        "") fail "no up series for the $what in $INFRARED_NS: the scrape infrared-metrics finds no Service port named metrics for it" ;;
        1\ *) pass "the $what is up through job ${hit#1 } (up=1)" ;;
        *) fail "the $what's target is down: up=${hit%% *} through job ${hit#* }" ;;
      esac
    done
  fi
fi

# --- 3. series present ----------------------------------------------------------
log "3. Every series the dashboards read has a sample in the last 10 minutes"
dashboards="$(k -n "$MON" get configmaps -l grafana_dashboard=1 -o json 2>/dev/null || echo '{"items":[]}')"
if runs 3; then
  if [ -z "$stack" ]; then skip "$no_stack"; else
    # name<TAB>dashboard, one per metric name a panel's expr reads: an
    # identifier followed by { or [ (a selector or a range), as verify.sh
    # reads the Fleet dashboard's; functions (followed by a parenthesis),
    # labels (followed by a matcher) and Grafana's $variables never are.
    tab="$(printf '\t')"
    jq -r '.items[] | .metadata.name as $cm | .data | to_entries[] | select(.key | endswith(".json")) | .value | fromjson
      | [.. | objects | select(has("expr")) | .expr | strings] | .[] | gsub("[\\n\\t]"; " ") | . + "\t" + $cm' <<<"$dashboards" 2>/dev/null |
      while IFS="$tab" read -r expr cm; do
        printf '%s\n' "$expr" | { grep -oE '(^|[^a-zA-Z0-9_:$])[a-zA-Z_:][a-zA-Z0-9_:]*[[:space:]]*[{[]' || true; } |
          sed -E 's/^[^a-zA-Z_:]//; s/[[:space:]]*[{[]$//' | sed "s/\$/$tab$cm/"
      done | sort -u >"$work/names.tsv" || true
    if [ ! -s "$work/names.tsv" ]; then fail "no dashboard ConfigMap (label grafana_dashboard=1) in $MON names a series"; fi
    cut -f1 "$work/names.tsv" | sort -u | while read -r name; do
      dash="$(awk -F'\t' -v n="$name" '$1 == n { print $2 }' "$work/names.tsv" | sed 's/-dashboard$//' | sort -u | tr '\n' ' ' | sed 's/ $//')"
      v="$(scalar "count(count_over_time(${name}[10m]))")"
      if [ -n "$v" ] && [ "$v" != 0 ]; then
        echo "  ok    $name ($v series; $dash)"
        continue
      fi
      case " $dash " in
        *" infrared-"*) ;;
        *) echo "  CHART $name ($dash)"; continue ;;
      esac
      case " $LANE_A_SERIES " in
        *" $name "*) echo "  SKIP  $name is absent: $LANE_A_NOTE ($dash)"; continue ;;
      esac
      case "$name" in
        claude_code_* | localred_machine_* | infrared_plan_*) echo "  WARN  $name is absent: only a connected Mac's stack pushes it to this plane ($dash)" ;;
        infrared_agentvm_* | infrared_lease_lost_total) echo "  WARN  $name is absent: only a runner pool produces it ($dash)" ;;
        infrared_step_* | infrared_runs_active) echo "  WARN  $name is absent: only an agent run since the operator's start produces it ($dash)" ;;
        infrared_telemetry_writes_total) echo "  WARN  $name is absent: only a plane that a stack writes to produces it ($dash)" ;;
        *) echo "  FAIL  $name has no sample in the last 10 minutes ($dash)" ;;
      esac
    done >"$work/series.txt"
    { grep -v '^  CHART' "$work/series.txt" || true; }
    chart_absent="$(awk '/^  CHART/ { print $2 }' "$work/series.txt" | tr '\n' ' ' | sed 's/ $//')"
    [ -z "$chart_absent" ] || warn "the chart's own dashboards read $(wc -w <<<"$chart_absent" | tr -d ' ') series with no sample in the last 10 minutes: $chart_absent"
    fails=$((fails + $(grep -c '^  FAIL' "$work/series.txt" || true)))
    warns=$((warns + $(grep -c '^  WARN' "$work/series.txt" || true)))
    skips=$((skips + $(grep -c '^  SKIP' "$work/series.txt" || true)))
  fi
fi

# --- 4. label hygiene -----------------------------------------------------------
log "4. No label value looks like a token, an email or a path"
if runs 4; then
  if [ -z "$stack" ]; then skip "$no_stack"; else
    labels="$(vm /api/v1/labels | jq -r '.data[]?' 2>/dev/null || true)"
    if [ -z "$labels" ]; then fail "the store lists no labels"; else
      n=0 hits=0
      while read -r label; do
        [ -n "$label" ] || continue
        n=$((n + 1))
        vm "/api/v1/label/$(enc "$label")/values" | jq -r '.data[]?' 2>/dev/null >"$work/values.txt" || true
        tokens="$(grep -cE 'sk-ant-|irt_|ghp_|gho_|AKIA|xox[abp]-' "$work/values.txt" || true)"
        emails="$(grep -cE '[^@ ]+@[^@ ]+\.[a-z]+' "$work/values.txt" || true)"
        paths="$( { grep -E '/Users/|/private/' "$work/values.txt" || true; { grep -E '/home/' "$work/values.txt" || true; } | { grep -Ev '/home/kubernetes/' || true; }; } | sort -u | wc -l | tr -d ' ')"
        for kind in "token $tokens" "email $emails" "path $paths"; do
          [ "${kind#* }" = 0 ] || { fail "label $label: ${kind#* } value(s) look like a ${kind% *}"; hits=$((hits + 1)); }
        done
      done <<<"$labels"
      [ "$hits" != 0 ] || pass "$n labels, no value matches a token, an email or a path"
    fi
  fi
fi

# --- 5. alert path --------------------------------------------------------------
log "5. A synthetic alert opens an Incident and resolves (--alert-path)"
PLATFORM_ORG="$(jq -r '.status.platformOrg // ""' <<<"$inst")"
if runs 5; then
  if [ -z "$ALERT_PATH" ]; then skip "without --alert-path (it posts one alert to Alertmanager)"
  elif [ -z "$stack" ]; then skip "$no_stack"
  elif needs_api "the alert path"; then
    [ -n "$PLATFORM_ORG" ] || die "the Installation names no platform org (status.platformOrg)"
    prod="$(k -n "ir-org-$PLATFORM_ORG" get products.infrared.darkshift.io -o json 2>/dev/null |
      jq -r '[.items[] | select(.metadata.deletionTimestamp == null)] | sort_by(.metadata.creationTimestamp, .metadata.name) | first // empty | .metadata.name + " " + (.spec.zones[0].name // "")')"
    PRODUCT="${prod%% *}" ZONE="${prod#* }"
    if [ -z "$PRODUCT" ]; then fail "the platform org $PLATFORM_ORG has no Product: nothing to open an Incident on"
    elif ! k -n "ir-org-$PLATFORM_ORG" get vmalertmanagerconfigs.operator.victoriametrics.com infrared-incidents >/dev/null 2>&1; then
      fail "org $PLATFORM_ORG has no VMAlertmanagerConfig infrared-incidents: the operator writes it once the org has a Product with a zone"
    elif ! forward "$ALERTMANAGER" 9093; then fail "no port-forward to $MON/$ALERTMANAGER"
    else
      amport="$port"
      c="$(post_alert)"
      if [ "$c" != 200 ]; then fail "Alertmanager answered $c to the synthetic alert"; else
        alert_posted=1
        pass "posted the alert ObservabilityCheck for Product $PRODUCT, zone ${ZONE:-(none)}, namespace ir-org-$PLATFORM_ORG"
        t0=$SECONDS name=""
        while [ $((SECONDS - t0)) -le 90 ]; do
          r="$(api GET "/v1/orgs/$PLATFORM_ORG/incidents?product=$(enc "$PRODUCT")&open=true")" || r=$'\n000'
          if [ "$(code "$r")" = 200 ]; then
            name="$(body "$r" | jq -r --arg id "$STAMP" '[.[]? | select(.spec.alert.labels.alertname == "ObservabilityCheck" and .spec.alert.labels.observability_check == $id)] | first // empty | .name')"
            [ -z "$name" ] || break
          fi
          sleep 5
        done
        if [ -z "$name" ]; then
          fail "no open Incident on $PRODUCT from the alert within 90 s (the API's last answer: HTTP $(code "$r"))"
        else
          pass "Incident $name opened after $((SECONDS - t0)) s ($(body "$r" | jq -r --arg n "$name" '.[] | select(.name == $n) | .spec.severity + ", " + .status.phase'))"
          c="$(post_alert "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
          alert_posted=""
          if [ "$c" != 200 ]; then fail "Alertmanager answered $c to the alert's endsAt"; else
            t1=$SECONDS phase=""
            while [ $((SECONDS - t1)) -le 360 ]; do
              r="$(api GET "/v1/orgs/$PLATFORM_ORG/incidents/$name")" || r=$'\n000'
              phase="$(body "$r" | jq -r '.status.phase // ""' 2>/dev/null || true)"
              [ "$phase" != Resolved ] || break
              sleep 10
            done
            if [ "$phase" = Resolved ]; then pass "Incident $name resolved $((SECONDS - t1)) s after the endsAt (the route's group_interval decides)"
            else fail "Incident $name is '$phase' 6 minutes after the endsAt, want Resolved"; fi
          fi
        fi
      fi
    fi
  fi
fi

# --- 6. platform route ----------------------------------------------------------
log "6. Alertmanager routes the install's own alerts to the API's platform receiver"
if runs 6; then
  if [ -z "$stack" ]; then skip "$no_stack"; else
    am="$(raw "$CTX" "$ALERTMANAGER" 9093 /api/v2/status | jq -r '.config.original // ""' 2>/dev/null || true)"
    if [ -z "$am" ]; then fail "Alertmanager does not answer /api/v2/status through the API server's proxy"; else
      root="$(yq -N -r '.route.receiver // ""' <<<"$am" 2>/dev/null || true)"
      webhooks="$(yq -N -r '.receivers[] | select(.name == "infrared-platform") | .webhook_configs | length' <<<"$am" 2>/dev/null || true)"
      # Alertmanager's status redacts a webhook's url as <secret>, so the path
      # is read from the metrics stack Application's rendered values, the
      # template's intent as applied; nothing of it is a secret.
      url="$(k -n "${ARGO_NS:-argocd}" get applications.argoproj.io victoria-metrics-k8s-stack -o json 2>/dev/null |
        jq -r '[.spec.source.helm.valuesObject.alertmanager.config.receivers[]? | select(.name == "infrared-platform") | .webhook_configs[]?.url] | first // ""' 2>/dev/null || true)"
      path="${url#*://}"
      path="/${path#*/}"
      [ -n "$url" ] || path=""
      if [ "$root" = infrared-platform ] && [ "${webhooks:-0}" != 0 ] && [ "$path" = /v1/webhooks/alertmanager/_platform ]; then
        pass "the root receiver infrared-platform is a webhook to $path"
      elif [ "$root" = infrared-platform ] && [ "${webhooks:-0}" != 0 ] && [ -z "$url" ]; then
        warn "the root receiver infrared-platform is a webhook, whose path the Application victoria-metrics-k8s-stack's values do not show (not readable, or the chart's values changed shape)"
      else
        fail "the root receiver is '${root:-none}'$([ -n "$path" ] && echo " and infrared-platform's webhook path is $path"): the install's own alerts reach no one, until infrared-gitops-template's install telemetry template lands (ADR 0069 T9, lane C)"
      fi
    fi
  fi
fi

# --- 7. rules loaded ------------------------------------------------------------
log "7. vmalert loads every VMRule's groups"
if runs 7; then
  if [ -z "$stack" ]; then skip "$no_stack"; else
    groups="$(raw "$CTX" "$VMALERT" 8080 /api/v1/rules | jq -r '.data.groups[]? | .name + "\t" + (.file // "")' 2>/dev/null || true)"
    if [ -z "$groups" ]; then fail "vmalert lists no rule group at /api/v1/rules"; else
      rules="$(k get vmrules.operator.victoriametrics.com -A -o json 2>/dev/null | jq -r '.items[] | .metadata.namespace + "\t" + .metadata.name + "\t" + ([.spec.groups[].name] | join(","))')"
      products=0
      while IFS=$'\t' read -r ns name gs; do
        [ -n "$name" ] || continue
        missing=""
        for g in $(tr ',' ' ' <<<"$gs"); do
          awk -F'\t' -v g="$g" -v f="$ns-$name" '$1 == g && index($2, f) { found = 1 } END { exit !found }' <<<"$groups" ||
            awk -F'\t' -v g="$g" '$1 == g { found = 1 } END { exit !found }' <<<"$groups" || missing="$missing $g"
        done
        case "$name" in infrared-slo-*) products=$((products + 1)) ;; esac
        if [ -z "$missing" ]; then pass "$ns/$name: $(tr ',' '\n' <<<"$gs" | wc -l | tr -d ' ') group(s) loaded"
        else fail "$ns/$name: group(s) not loaded:$missing"; fi
      done <<<"$rules"
      [ "$products" != 0 ] || warn "no Product VMRule (infrared-slo-<product>): the operator writes one per Product with a zone"
      grep -q "^$MON	infrared-platform	" <<<"$rules" ||
        skip "no VMRule $MON/infrared-platform: the install's own alerts come with infrared-gitops-template's install telemetry template (ADR 0069 T9, lane C)"
    fi
  fi
fi

# --- 8. dashboards --------------------------------------------------------------
log "8. Grafana lists every dashboard ConfigMap, and each loads"
gport=""
if runs 8 || runs 9; then
  if [ -n "$stack" ]; then forward "$GRAFANA" 80 && gport="$port" || true; fi
fi
if runs 8; then
  if [ -z "$stack" ]; then skip "$no_stack"
  elif [ -z "$gport" ]; then fail "no port-forward to $MON/$GRAFANA"
  else
    uids="$(jq -r '.items[] | .metadata.name as $cm | .data | to_entries[] | select(.key | endswith(".json")) | .value | fromjson | (.uid // "") + "\t" + $cm' <<<"$dashboards" 2>/dev/null || true)"
    grep -q '^infrared-fleet	' <<<"$uids" || fail "no dashboard ConfigMap carries the Fleet dashboard (uid infrared-fleet): the template ships it with the metrics stack"
    r="$(grafana "/api/search?type=dash-db&limit=5000")" || r=$'\n000'
    if [ "$(code "$r")" != 200 ]; then fail "Grafana answered $(code "$r") to /api/search"; else
      listed="$(body "$r" | jq -r '.[]?.uid')"
      while IFS=$'\t' read -r uid cm; do
        [ -n "$uid" ] || { fail "a dashboard in ConfigMap $cm has no uid"; continue; }
        if ! grep -qx "$uid" <<<"$listed"; then fail "Grafana does not list $uid (ConfigMap $cm): the sidecar has not loaded it"; continue; fi
        d="$(grafana "/api/dashboards/uid/$uid")" || d=$'\n000'
        if [ "$(code "$d")" = 200 ]; then pass "$uid loads: $(body "$d" | jq -r '.dashboard.title // "?"') ($(body "$d" | jq -r '[.dashboard.panels[]?] | length') panels)"
        else fail "$uid: /api/dashboards/uid answered $(code "$d")"; fi
      done <<<"$uids"
    fi
  fi
fi

# --- 9. Grafana's sign-in -------------------------------------------------------
log "9. Grafana signs people in through Infrared"
if runs 9; then
  if [ -z "$stack" ]; then skip "$no_stack"; else
    gdep="$(k -n "$MON" get deployment "$GRAFANA" -o json 2>/dev/null || true)"
    genv() { jq -r --arg n "$1" '[.spec.template.spec.containers[] | .env[]? | select(.name == $n) | .value // ""] | first // ""' <<<"$gdep"; }
    ini="$(k -n "$MON" get configmap "$GRAFANA" -o json 2>/dev/null | jq -r '.data["grafana.ini"] // ""' 2>/dev/null || true)"
    on="$(genv GF_AUTH_GENERIC_OAUTH_ENABLED)"
    [ -n "$on" ] || on="$(awk '/^\[auth\.generic_oauth\]/ { s = 1; next } /^\[/ { s = 0 } s && /^enabled *= *true/ { print "true" }' <<<"$ini")"
    auth_url="$(genv GF_AUTH_GENERIC_OAUTH_AUTH_URL)"
    [ -n "$auth_url" ] || auth_url="$(awk '/^\[auth\.generic_oauth\]/ { s = 1; next } /^\[/ { s = 0 } s && /^auth_url *=/ { sub(/^auth_url *= */, ""); print }' <<<"$ini")"
    if [ "$on" != true ]; then skip "Grafana's OAuth is off (the Installation's OIDC for its own tools, ADR 0053, is not set)"
    elif [ -z "$gport" ]; then fail "no port-forward to $MON/$GRAFANA"
    else
      got="$(curl -sS -o /dev/null --max-time 30 -w '%{http_code} %{redirect_url}' "http://127.0.0.1:$gport/login/generic_oauth" || echo "000 ")"
      status="${got%% *}" location="${got#* }"
      case "$auth_url" in */api/v1/oidc/authorize) ;; *) fail "Grafana's auth_url is '$auth_url', want the install's /api/v1/oidc/authorize" ;; esac
      if [ "$status" = 302 ] && [ "${location%%\?*}" = "$auth_url" ]; then pass "/login/generic_oauth answers 302 to $auth_url"
      else fail "/login/generic_oauth answers $status to '${location%%\?*}', want 302 to $auth_url"; fi
    fi
  fi
fi

# --- 10. telemetry out ----------------------------------------------------------
log "10. The install writes to its telemetry plane"
tele_url="$(jq -r '.spec.observability.telemetry.url // ""' <<<"$inst")"
tele_platform="$(jq -r '.spec.observability.telemetry.platform // ""' <<<"$inst")"
if runs 10; then
  if [ -z "$tele_url" ]; then skip "the Installation names no telemetry plane (spec.observability.telemetry): nothing leaves this install"
  else
    pass "the Installation writes to $tele_url as platform ${tele_platform:-$(jq -r '.metadata.name' <<<"$inst")}"
    if k -n "$MON" get secret telemetry-token >/dev/null 2>&1; then pass "the Secret $MON/telemetry-token is there"; else fail "no Secret $MON/telemetry-token: the vmagent has no token to write with"; fi
    before="$(accepted_writes || echo none)"
    if [ "$before" = none ]; then fail "no Running vmagent in $MON to read the write counters from"; else
      echo "        waiting 60 s for the vmagent's next accepted write ($before so far)"
      sleep 60
      after="$(accepted_writes || echo 0)"
      if [ "$after" -gt "$before" ]; then pass "the plane accepted $((after - before)) write(s) in 60 s ($after in all since the vmagent started)"
      else fail "no write accepted in 60 s ($after in all): the plane refuses or does not answer; the vmagent's own log says which"; fi
    fi
    if [ -n "$PLANE" ]; then
      v="$(scalar "count(count_over_time(infrared_install_info{platform=\"$PLATFORM\"}[2m]))" "$PLANE")"
      if [ -n "$v" ] && [ "$v" != 0 ]; then pass "the plane $PLANE holds infrared_install_info for platform $PLATFORM under 2 minutes old"
      else
        u="$(scalar "count(count_over_time(up{platform=\"$PLATFORM\"}[2m]))" "$PLANE")"
        if [ -n "$u" ] && [ "$u" != 0 ]; then pass "the plane $PLANE holds up{platform=\"$PLATFORM\"} under 2 minutes old ($u series; infrared_install_info $LANE_A_NOTE)"
        else fail "the plane $PLANE holds no sample of platform $PLATFORM under 2 minutes old"; fi
      fi
    fi
  fi
fi

# --- 11. opt-out ----------------------------------------------------------------
log "11. Turned off, the install sends nothing; turned on again, it writes (--opt-out-test)"
if runs 11; then
  if [ -z "$OPT_OUT" ]; then skip "without --opt-out-test (it pauses the install's telemetry for 10 minutes)"
  elif [ -z "$PLANE" ]; then skip "--opt-out-test needs --plane and --platform, to read the plane's count of this install's writes"
  elif needs_api "the opt-out test"; then
    r="$(api GET /v1/telemetry)" || r=$'\n000'
    case "$(code "$r")" in
      200) ;;
      404) skip "GET /v1/telemetry answers 404: the rollout flag installTelemetry is off here, or the API predates it (ADR 0069 T5, lane D1)"; r="" ;;
      *) fail "GET /v1/telemetry answered $(code "$r")"; r="" ;;
    esac
    if [ -n "$r" ]; then
      plat="$(body "$r" | jq -r '.platform // ""')"
      [ -n "$plat" ] || plat="$PLATFORM"
      if [ "$(body "$r" | jq -r '.enabled')" != true ]; then
        fail "the install's telemetry is off already (GET /v1/telemetry enabled=false): turn it on first, then run the test"
      else
        echo "        WARNING: telemetry pauses now for 10 minutes: PUT /v1/telemetry {enabled: false}, then on again"
        flat0="$(scalar "sum(infrared_telemetry_writes_total{platform=\"$plat\"})" "$PLANE")"
        r="$(api PUT /v1/telemetry -H 'Content-Type: application/json' --data '{"enabled":false}')" || r=$'\n000'
        if [ "$(code "$r")" != 200 ]; then fail "PUT /v1/telemetry {enabled: false} answered $(code "$r"): $(body "$r" | jq -r '.detail // ""' 2>/dev/null)"; else
          pass "telemetry off (the API cleared the Installation's field and revoked the token)"
          gone=1 t0=$SECONDS
          while [ $((SECONDS - t0)) -lt 600 ]; do
            if k -n "$MON" get secret telemetry-token >/dev/null 2>&1; then gone=""; break; fi
            sleep 60
          done
          if [ -n "$gone" ]; then pass "the Secret $MON/telemetry-token stayed gone for 10 minutes"; else fail "the Secret $MON/telemetry-token came back while telemetry was off"; fi
          flat1="$(scalar "sum(infrared_telemetry_writes_total{platform=\"$plat\"})" "$PLANE")"
          if [ "${flat0:-0}" = "${flat1:-0}" ]; then pass "the plane's count of $plat's writes stayed flat (${flat1:-0})"
          else fail "the plane counted $plat's writes while off: ${flat0:-0} then ${flat1:-0}"; fi
          r="$(api PUT /v1/telemetry -H 'Content-Type: application/json' --data '{"enabled":true}')" || r=$'\n000'
          if [ "$(code "$r")" != 200 ]; then fail "PUT /v1/telemetry {enabled: true} answered $(code "$r"): $(body "$r" | jq -r '.detail // ""' 2>/dev/null)"; else
            pass "telemetry on again as platform $(body "$r" | jq -r '.platform // "?"')"
            t1=$SECONDS wrote=""
            while [ $((SECONDS - t1)) -lt 180 ]; do
              flat2="$(scalar "sum(infrared_telemetry_writes_total{platform=\"$plat\"})" "$PLANE")"
              if [ -n "$flat2" ] && [ "$flat2" != "${flat1:-0}" ]; then wrote=1; break; fi
              sleep 15
            done
            if [ -n "$wrote" ]; then pass "the plane accepted a first write $((SECONDS - t1)) s after the switch"
            else fail "no write reached the plane within 3 minutes of the switch: the vmagent comes with the gitops repo's next render and sync"; fi
          fi
        fi
      fi
    fi
  fi
fi

# --- 12. backup -----------------------------------------------------------------
log "12. The metrics' nightly copy ran"
if runs 12; then
  cj="$(k -n "$MON" get cronjob metrics-backup -o json 2>/dev/null || true)"
  if [ -z "$cj" ]; then skip "no CronJob $MON/metrics-backup: the copy renders on Google Cloud with a Google Cloud Storage backup bucket only"
  else
    last="$(jq -r '.status.lastSuccessfulTime // ""' <<<"$cj")"
    at="$(epoch "$last")"
    if [ -z "$last" ]; then fail "metrics-backup has never succeeded (last schedule: $(jq -r '.status.lastScheduleTime // "none"' <<<"$cj"))"
    elif [ -z "$at" ]; then fail "metrics-backup's lastSuccessfulTime '$last' does not parse"
    else
      age=$(( $(date +%s) - at ))
      if [ "$age" -lt $((26 * 3600)) ]; then pass "last successful copy $last, $((age / 3600)) h ago"
      else fail "last successful copy $last, $((age / 3600)) h ago, want under 26 h"; fi
    fi
  fi
fi

# --- 13. Bedrock ----------------------------------------------------------------
log "13. Model calls on Amazon Bedrock are counted"
if runs 13; then
  if [ "$(op_env INFRARED_BEDROCK)" != true ]; then skip "Bedrock is off on this install (the chart's runner.bedrock.enabled)"
  elif [ -z "$stack" ]; then skip "$no_stack"
  elif [ -z "$(scalar 'count(infrared_model_calls_total)')" ]; then skip "infrared_model_calls_total is absent: $LANE_A_NOTE"
  else
    calls="$(scalar 'sum(infrared_model_calls_total{provider="bedrock"})')"
    cost="$(scalar 'sum(infrared_step_cost_usd_total{provider="bedrock"})')"
    if [ -n "$calls" ] && [ "$calls" != 0 ]; then pass "$calls model call(s) on provider bedrock"; else fail "no model call counted on provider bedrock: run scripts/bedrock-proof.sh"; fi
    if [ -n "$cost" ] && [ "$cost" != 0 ]; then pass "USD $cost of step cost on provider bedrock"; else fail "no step cost counted on provider bedrock"; fi
  fi
fi

echo
echo "observability-check: $fails failed, $warns warned, $skips skipped on $CTX"
[ "$fails" = 0 ] || exit "$fails"
