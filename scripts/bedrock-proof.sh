#!/usr/bin/env bash
# =============================================================================
# bedrock-proof.sh <kube context> <api url> <org> [options]: an org's first
# agent step runs on Amazon Bedrock, with its calls, tokens and cost read
# back from the run, the install's store, the plane and CloudWatch
# (infrared-docs-internal ADR 0069 T11; workspace TODO 514; README "Checks on
# a running install").
# =============================================================================
# On an install with Bedrock on (the Infrared chart's runner.bedrock.enabled,
# INFRARED_BEDROCK on the operator), in order:
#
#   1. with --account-id and --role-arn, adds the org's AWS CloudAccount
#      (--cloud-account, bedrock) through the API, skipped when it exists,
#      and waits up to 2 minutes for it to be Verified;
#   2. sets the org's model tiers to Bedrock's model IDs: Opus 4.6, Sonnet
#      4.6 and Haiku 4.5 as us.anthropic.* (--tiers names others);
#   3. sets the org's model provider to Bedrock on that account and region
#      (--region, us-east-1): ir org model-provider set --bedrock
#      (infrared-cli, lane D2), and when this ir does not know it, prints
#      the kubectl patch of the Organization and runs it only with
#      --kubectl-fallback;
#   4. creates the Product (--product, hello-bedrock) with ir product create
#      -f from scripts/testdata/hello-bedrock.yaml and its starter beside it,
#      hello-bedrock.zip: one private repo on the install's own forge with a
#      one-page site, no build (a build needs a registry on the nodes, which
#      an EKS install has not: workspace TODO 514), so no zone; skipped when
#      it exists;
#   5. opens an issue on it with ir issue create, which starts the
#      change-quick run, whose first step, hydrate, is the architect's;
#   6. waits up to 15 minutes for that step to end;
#   7. asserts the step ran on Bedrock: its model is us.anthropic.*, its
#      usage has output tokens and a cost, and, from an operator that records
#      them, its attempt's provider is bedrock with forwarded model calls
#      (SKIP on an older operator); that the install's store counts
#      infrared_model_calls_total{provider="bedrock"} (SKIP until the release
#      that brings it, or with no metrics stack); and the plane too, with
#      --plane and --platform;
#   8. with --cloudwatch, reads AWS/Bedrock OutputTokenCount for the step's
#      model over the run's window, read-only with --profile
#      darkshift-preprod, and prints it beside the step's output tokens (on
#      2026-11-03 they matched to the token);
#   9. prints the figures. The run then waits at triage: approving it on an
#      EKS install without a registry on the nodes fails at the build step.
#
# Every API call carries the bearer token of --token-file (one line, mode
# 600), which reaches curl as its config on stdin; without it, steps 1 and 2
# are skipped and the rest goes through ir. ir uses its own login at <api
# url> (--config passes a config file through). No token is printed. The
# exit status is the number of failed assertions. Spends: one agent step on
# the org's Bedrock account. Runs against a cluster, never from CI.
# Needs: kubectl, jq, curl, ir; aws with --cloudwatch.
# =============================================================================
set -euo pipefail
usage='usage: scripts/bedrock-proof.sh <kube context> <api url> <org> [--token-file <file>]
         [--cloud-account <name> --account-id <id> --role-arn <arn> --region <r>] [--tiers <frontier>,<balanced>,<fast>]
         [--product <name>] [--kubectl-fallback] [--cloudwatch] [--plane <home context> --platform <name>] [--config <ir config>]'
CTX="${1:?$usage}"
API="${2:?$usage}"
ORG="${3:?$usage}"
shift 3
TOKEN_FILE="" CA=bedrock ACCOUNT_ID="" ROLE_ARN="" REGION=us-east-1 PRODUCT=hello-bedrock FALLBACK="" CLOUDWATCH="" PLANE="" PLATFORM="" IR_CONFIG=""
TIERS="us.anthropic.claude-opus-4-6-v1,us.anthropic.claude-sonnet-4-6,us.anthropic.claude-haiku-4-5-20251001-v1:0"
while [ $# -gt 0 ]; do
  case "$1" in
    --token-file) TOKEN_FILE="${2:?$usage}"; shift 2 ;;
    --cloud-account) CA="${2:?$usage}"; shift 2 ;;
    --account-id) ACCOUNT_ID="${2:?$usage}"; shift 2 ;;
    --role-arn) ROLE_ARN="${2:?$usage}"; shift 2 ;;
    --region) REGION="${2:?$usage}"; shift 2 ;;
    --tiers) TIERS="${2:?$usage}"; shift 2 ;;
    --product) PRODUCT="${2:?$usage}"; shift 2 ;;
    --kubectl-fallback) FALLBACK=1; shift ;;
    --cloudwatch) CLOUDWATCH=1; shift ;;
    --plane) PLANE="${2:?$usage}"; shift 2 ;;
    --platform) PLATFORM="${2:?$usage}"; shift 2 ;;
    --config) IR_CONFIG="${2:?$usage}"; shift 2 ;;
    -h | --help) echo "$usage"; sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac
done
API="${API%/}"
INFRARED_NS="${INFRARED_NS:-infrared}"
MON="${MON_NS:-monitoring}"
VMSINGLE=vmsingle-victoria-metrics-k8s-stack
NS="ir-org-$ORG"
TITLE="Say hello from Bedrock"
BODY="Add a line under the heading of index.html that says hello from Amazon Bedrock. This issue is scripts/bedrock-proof.sh's (infrared-gitops-template): its hydration step proves the org's model calls run on Bedrock, and the run may stay at triage."
LANE_A_NOTE="comes with infrared-operator's release that carries the model-call series (ADR 0069 T7, lane A)"
HERE="$(cd "$(dirname "$0")" && pwd)"

k() { kubectl --context "$CTX" "$@"; }
log() { printf '\n== %s\n' "$*"; }
die() {
  echo "bedrock-proof: $*" >&2
  exit 1
}
fails=0 skips=0
pass() { echo "  ok    $*"; }
fail() {
  echo "  FAIL  $*"
  fails=$((fails + 1))
}
skip() {
  echo "  SKIP  $*"
  skips=$((skips + 1))
}
# utc <epoch>: RFC 3339 in UTC, on macOS and GNU.
utc() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
enc() { jq -rn --arg s "$1" '$s | @uri'; }
# scalar <promql> [context]: the first value an instant query of that
# cluster's store yields, or nothing.
scalar() {
  kubectl --context "${2:-$CTX}" get --raw "/api/v1/namespaces/$MON/services/$VMSINGLE:8428/proxy/api/v1/query?query=$(enc "$1")" 2>/dev/null |
    jq -r '.data.result[0].value[1] // empty' 2>/dev/null || true
}
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
detail() { body "$1" | jq -r '.detail // .title // ""' 2>/dev/null || true; }
op_env() {
  k -n "$INFRARED_NS" get deployment infrared-operator -o json 2>/dev/null |
    jq -r --arg n "$1" '.spec.template.spec.containers[] | select(.name == "operator") | .env[]? | select(.name == $n) | .value // empty'
}

for t in kubectl jq curl ir; do command -v "$t" >/dev/null || die "missing tool: $t"; done
[ -s "$HERE/testdata/hello-bedrock.zip" ] || die "no starter at $HERE/testdata/hello-bedrock.zip"
[ -z "$CLOUDWATCH" ] || command -v aws >/dev/null || die "missing tool: aws (--cloudwatch)"
if [ -n "$TOKEN_FILE" ]; then
  [ -s "$TOKEN_FILE" ] || die "no token in $TOKEN_FILE"
  mode="$(stat -f %Lp "$TOKEN_FILE" 2>/dev/null || stat -c %a "$TOKEN_FILE")"
  [ "$mode" = 600 ] || die "$TOKEN_FILE is mode $mode, want 600: it holds a token"
  [ "$(wc -l <"$TOKEN_FILE" | tr -d ' ')" -le 1 ] || die "$TOKEN_FILE holds more than one line, want the token alone"
fi
if [ -n "$PLANE" ] || [ -n "$PLATFORM" ]; then
  [ -n "$PLANE" ] && [ -n "$PLATFORM" ] || die "--plane and --platform go together"
  kubectl --context "$PLANE" get --raw /readyz >/dev/null 2>&1 || die "the plane's context $PLANE does not answer"
fi
k get --raw /readyz >/dev/null 2>&1 || die "context $CTX does not answer"
k get namespace "$NS" >/dev/null 2>&1 || die "no org $ORG on $CTX (namespace $NS)"
[ "$(op_env INFRARED_BEDROCK)" = true ] || die "Bedrock is off on $CTX: the operator's INFRARED_BEDROCK is not true (the chart's runner.bedrock.enabled)"
IR=(ir --server "$API" --org "$ORG")
[ -z "$IR_CONFIG" ] || IR=(ir --config "$IR_CONFIG" --server "$API" --org "$ORG")
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
if ! "${IR[@]}" org get "$ORG" -o json >/dev/null 2>"$work/ir.err"; then
  die "ir cannot act in org $ORG at $API: $(tail -1 "$work/ir.err"). Sign in with ir login --server $API --token-stdin < <token file>, or pass --config <its config file>"
fi
t_start="$(date +%s)"
echo "bedrock-proof: $CTX, $API, org $ORG, cloud account $CA in $REGION, Product $PRODUCT"

# --- 1. the cloud account --------------------------------------------------------
log "1. The org's AWS CloudAccount $CA is Verified"
phase=""
if [ -n "$TOKEN_FILE" ]; then
  r="$(api GET "/v1/orgs/$ORG/cloud-accounts/$CA")" || r=$'\n000'
  case "$(code "$r")" in
    200) phase="$(body "$r" | jq -r '.phase // ""')"; pass "cloud account $CA exists ($phase)" ;;
    404)
      [ -n "$ACCOUNT_ID" ] && [ -n "$ROLE_ARN" ] || die "no cloud account $CA in org $ORG: pass --account-id and --role-arn to add it"
      r="$(api POST "/v1/orgs/$ORG/cloud-accounts" -H 'Content-Type: application/json' \
        --data "$(jq -n --arg n "$CA" --arg id "$ACCOUNT_ID" --arg arn "$ROLE_ARN" '{name: $n, displayName: "Bedrock", aws: {accountID: $id, roleARN: $arn}}')")" || r=$'\n000'
      case "$(code "$r")" in
        201 | 202) pass "cloud account $CA added (AWS account $ACCOUNT_ID, role ${ROLE_ARN##*/})" ;;
        *) die "POST /v1/orgs/$ORG/cloud-accounts answered $(code "$r"): $(detail "$r")" ;;
      esac
      ;;
    *) die "GET /v1/orgs/$ORG/cloud-accounts/$CA answered $(code "$r"): $(detail "$r")" ;;
  esac
  deadline=$((SECONDS + 120))
  while [ "$phase" != Verified ] && [ "$SECONDS" -lt "$deadline" ]; do
    sleep 5
    r="$(api GET "/v1/orgs/$ORG/cloud-accounts/$CA")" || r=$'\n000'
    phase="$(body "$r" | jq -r '.phase // ""' 2>/dev/null || true)"
  done
  if [ "$phase" = Verified ]; then pass "Verified as $(body "$r" | jq -r '.identity // "?"')"
  else die "cloud account $CA is '$phase' after 2 minutes: $(body "$r" | jq -r '.message // ""')"; fi
else
  phase="$(k -n "$NS" get cloudaccounts.infrared.darkshift.io "$CA" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [ -n "$phase" ] || die "no CloudAccount $CA in $NS, and no --token-file to add one through the API"
  deadline=$((SECONDS + 120))
  while [ "$phase" != Verified ] && [ "$SECONDS" -lt "$deadline" ]; do
    sleep 5
    phase="$(k -n "$NS" get cloudaccounts.infrared.darkshift.io "$CA" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  done
  if [ "$phase" = Verified ]; then pass "CloudAccount $CA is Verified as $(k -n "$NS" get cloudaccounts.infrared.darkshift.io "$CA" -o jsonpath='{.status.identity}')"
  else die "CloudAccount $CA is '$phase' after 2 minutes"; fi
fi

# --- 2. the tiers -------------------------------------------------------------------
log "2. The org's model tiers are Bedrock's model IDs"
IFS=, read -r frontier balanced fast <<<"$TIERS"
[ -n "$frontier" ] && [ -n "$balanced" ] && [ -n "$fast" ] || die "--tiers wants three model IDs, frontier,balanced,fast"
if [ -z "$TOKEN_FILE" ]; then skip "no --token-file: the tiers are left as they are (ir has no command for them)"; else
  r="$(api PUT "/v1/orgs/$ORG/models/tiers" -H 'Content-Type: application/json' \
    --data "$(jq -n --arg f "$frontier" --arg b "$balanced" --arg h "$fast" '{tiers: {frontier: $f, balanced: $b, fast: $h}}')")" || r=$'\n000'
  if [ "$(code "$r")" = 200 ]; then pass "frontier $frontier, balanced $balanced, fast $fast"
  else die "PUT /v1/orgs/$ORG/models/tiers answered $(code "$r"): $(detail "$r")"; fi
fi

# --- 3. the provider ----------------------------------------------------------------
log "3. The org's model provider is Bedrock on $CA in $REGION"
provider() { k get organizations.infrared.darkshift.io "$ORG" -o json 2>/dev/null | jq -r '.spec.modelProvider.bedrock // {} | (.cloudAccount // "") + " " + (.region // "")'; }
patch="kubectl --context $CTX patch organization $ORG --type merge -p '{\"spec\":{\"modelProvider\":{\"bedrock\":{\"cloudAccount\":\"$CA\",\"region\":\"$REGION\"}}}}'"
if [ "$(provider)" = "$CA $REGION" ]; then pass "already set on the Organization"; else
  if "${IR[@]}" org model-provider set --bedrock --cloud-account "$CA" --region "$REGION" >"$work/ir.out" 2>"$work/ir.err"; then
    pass "set with ir org model-provider set --bedrock: $(tail -1 "$work/ir.out")"
  elif grep -qiE 'unknown command|unknown flag|unknown shorthand|unrecognized' "$work/ir.err"; then
    echo "        this ir has no org model-provider set --bedrock (infrared-cli, lane D2). The Organization takes it by hand:"
    echo "        $patch"
    if [ -n "$FALLBACK" ]; then
      k patch organizations.infrared.darkshift.io "$ORG" --type merge -p "{\"spec\":{\"modelProvider\":{\"bedrock\":{\"cloudAccount\":\"$CA\",\"region\":\"$REGION\"}}}}" >/dev/null
      pass "patched the Organization (--kubectl-fallback)"
    else
      die "run that line, or pass --kubectl-fallback to have this script run it"
    fi
  else
    die "ir org model-provider set failed: $(tail -1 "$work/ir.err")"
  fi
  [ "$(provider)" = "$CA $REGION" ] || die "the Organization's spec.modelProvider.bedrock is '$(provider)', want '$CA $REGION'"
fi

# --- 4. the Product -----------------------------------------------------------------
log "4. The Product $PRODUCT exists, with its repo on the install's own forge"
if k -n "$NS" get products.infrared.darkshift.io "$PRODUCT" >/dev/null 2>&1; then pass "Product $PRODUCT exists: left as it is"; else
  # The manifest and its starter, copied together: ir reads the starter from
  # the manifest's directory. --product renames the Product and its repo (the
  # two name fields), not the starter.
  cp "$HERE/testdata/hello-bedrock.zip" "$work/hello-bedrock.zip"
  sed -E "s/^( +(- )?name: )hello-bedrock\$/\\1$PRODUCT/" "$HERE/testdata/hello-bedrock.yaml" >"$work/hello-bedrock.yaml"
  "${IR[@]}" product create -f "$work/hello-bedrock.yaml" | sed 's/^/        /'
  k -n "$NS" get products.infrared.darkshift.io "$PRODUCT" >/dev/null 2>&1 || die "Product $PRODUCT is not on $CTX after ir product create"
  pass "Product $PRODUCT created from scripts/testdata/hello-bedrock.yaml, its repo started from the one-page starter hello-bedrock.zip"
fi

# --- 5. the issue and its run ---------------------------------------------------------
log "5. An issue on $PRODUCT starts a run"
created="$("${IR[@]}" issue create --product "$PRODUCT" --title "$TITLE" --body "$BODY" -o json)"
RUN="$(jq -r '.run // ""' <<<"$created")"
issue="$(jq -r '(.issue.repo // "") + "#" + ((.issue.number // 0) | tostring)' <<<"$created")"
if [ -z "$RUN" ]; then die "issue $issue opened, but hydration did not start: $(jq -r '.note // "no note"' <<<"$created")"; fi
pass "issue $issue opened; run $RUN started"

# --- 6. the hydrate step ----------------------------------------------------------------
log "6. The run's hydrate step ends (up to 15 minutes)"
step_json() {
  "${IR[@]}" run get "$RUN" -o json 2>/dev/null |
    jq -c '.status.steps // [] | (map(select(.type == "agentRole" and (.name | test("hydrat")))) + map(select(.type == "agentRole"))) | first // empty'
}
run_phase() { "${IR[@]}" run get "$RUN" -o json 2>/dev/null | jq -r '.status.phase // ""'; }
deadline=$((SECONDS + 900)) last="" step="" phase=""
while [ "$SECONDS" -lt "$deadline" ]; do
  step="$(step_json || true)"
  phase="$(jq -r '.phase // ""' <<<"${step:-{\}}")"
  state="$(jq -r '(.name // "?") + " " + (.phase // "?") + " attempts " + ((.attempts // 0) | tostring)' <<<"${step:-{\}}")"
  if [ "$state" != "$last" ]; then
    echo "        $(date -u +%H:%M:%S) $state"
    last="$state"
  fi
  case "$phase" in Succeeded | Failed | Cancelled | DeadLettered | Skipped) break ;; esac
  case "$(run_phase)" in Failed | Cancelled) break ;; esac
  sleep 15
done
case "$phase" in
  Succeeded) pass "step $(jq -r '.name' <<<"$step") Succeeded" ;;
  Failed | Cancelled | DeadLettered | Skipped) fail "step $(jq -r '.name' <<<"$step") ended $phase: $(jq -r '.message // ""' <<<"$step")" ;;
  *) die "the step is '$phase' after 15 minutes (run $(run_phase)): ir run get $RUN" ;;
esac

# --- 7. the figures -----------------------------------------------------------------------
log "7. The step ran on Bedrock"
model="$(jq -r '.model // ""' <<<"$step")"
case "$model" in
  us.anthropic.*) pass "model $model" ;;
  "") fail "the step names no model" ;;
  *) fail "model $model, want us.anthropic.*" ;;
esac
out_tokens="$(jq -r '.usage.outputTokens // 0' <<<"$step")"
in_tokens="$(jq -r '.usage.inputTokens // 0' <<<"$step")"
cost="$(jq -r '.usage.costUSD // "0"' <<<"$step")"
if [ "$out_tokens" -gt 0 ]; then pass "$out_tokens output tokens ($in_tokens input)"; else fail "no output tokens in the step's usage"; fi
if jq -en --arg c "$cost" '($c | tonumber) > 0' >/dev/null 2>&1; then pass "cost USD $cost"; else fail "no cost in the step's usage (costUSD '$cost')"; fi
attempt="$(jq -c '.attemptUsage // [] | last // {}' <<<"$step")"
forwarded="$(jq -r '.modelCalls.forwarded // 0' <<<"$attempt")"
att_provider="$(jq -r '.provider // ""' <<<"$attempt")"
if [ "$(jq -r 'has("provider") or has("modelCalls")' <<<"$attempt")" != true ]; then
  skip "the attempt records no provider or model calls: an operator from before ADR 0069 T7 (lane A)"
else
  if [ "$att_provider" = bedrock ]; then pass "the attempt's provider is bedrock$(jq -r 'if .region then " in " + .region else "" end' <<<"$attempt")"
  else fail "the attempt's provider is '$att_provider', want bedrock"; fi
  if [ "$forwarded" -gt 0 ]; then pass "$forwarded model call(s) forwarded by the runner's proxy ($(jq -r '[.modelCalls.byModel[]? | .model + " " + (.status // "?") + " x" + ((.calls // 0) | tostring)] | join(", ")' <<<"$attempt"))"
  else fail "the attempt's modelCalls.forwarded is $forwarded, want more than 0"; fi
fi
if ! k -n "$MON" get "deployment/$VMSINGLE" >/dev/null 2>&1; then skip "no metrics stack on $CTX: nothing counts the model calls locally"
elif [ -z "$(scalar 'count(infrared_model_calls_total)')" ]; then skip "infrared_model_calls_total is absent on $CTX: $LANE_A_NOTE"
else
  calls="$(scalar 'sum(infrared_model_calls_total{provider="bedrock"})')"
  if [ -n "$calls" ] && [ "$calls" != 0 ]; then pass "$CTX's store counts $calls model call(s) on provider bedrock"; else fail "$CTX's store counts no model call on provider bedrock"; fi
fi
if [ -n "$PLANE" ]; then
  if [ -z "$(scalar 'count(infrared_model_calls_total)' "$PLANE")" ]; then skip "infrared_model_calls_total is absent on the plane $PLANE: $LANE_A_NOTE"
  else
    calls="$(scalar "sum(infrared_model_calls_total{provider=\"bedrock\",platform=\"$PLATFORM\"})" "$PLANE")"
    if [ -n "$calls" ] && [ "$calls" != 0 ]; then pass "the plane $PLANE counts $calls model call(s) on provider bedrock for platform $PLATFORM"
    else fail "the plane $PLANE counts no model call on provider bedrock for platform $PLATFORM"; fi
  fi
fi

# --- 8. CloudWatch ------------------------------------------------------------------------
log "8. CloudWatch's OutputTokenCount beside the step's (--cloudwatch)"
cw="not read"
if [ -z "$CLOUDWATCH" ]; then skip "without --cloudwatch"
elif [ -z "$model" ]; then skip "the step names no model to read CloudWatch for"
else
  now="$(date +%s)"
  if out="$(aws --profile darkshift-preprod --region "$REGION" cloudwatch get-metric-statistics --namespace AWS/Bedrock \
    --metric-name OutputTokenCount --dimensions "Name=ModelId,Value=$model" --statistics Sum --period 3600 \
    --start-time "$(utc $((t_start - 600)))" --end-time "$(utc $((now + 300)))" --output json 2>"$work/aws.err")"; then
    cw="$(jq -r '[.Datapoints[]?.Sum] | add // 0 | floor' <<<"$out")"
    pass "step output tokens $out_tokens; CloudWatch OutputTokenCount for $model from $(utc $((t_start - 600))) to now: $cw (CloudWatch lags a few minutes, and other callers of the model in the account add to it)"
  else
    echo "  WARN  aws did not answer (read-only, --profile darkshift-preprod): $(tail -1 "$work/aws.err"); when the session expired, run aws sso login --sso-session darkshift"
  fi
fi

# --- 9. the figures -----------------------------------------------------------------------
log "9. The figures"
cat <<EOF
  run          $RUN (issue $issue on $PRODUCT, org $ORG)
  step         $(jq -r '.name // "?"' <<<"$step"), $phase, started $(jq -r '.startedAt // "?"' <<<"$step"), finished $(jq -r '.finishedAt // "?"' <<<"$step")
  model        ${model:-?} (tier $(jq -r '.modelTier // "?"' <<<"$step"))
  provider     ${att_provider:-not recorded}, $forwarded forwarded call(s)
  tokens       $in_tokens in, $out_tokens out; CloudWatch OutputTokenCount: $cw
  cost         USD $cost
EOF
echo
echo "The run now waits at triage (ir run get $RUN). Approving it on an EKS install without a registry on the nodes fails at the build step (workspace TODO 514)."
echo "bedrock-proof: $fails failed, $skips skipped"
[ "$fails" = 0 ] || exit "$fails"
