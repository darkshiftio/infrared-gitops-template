#!/usr/bin/env bash
# =============================================================================
# substrate-counter-test.sh <kube context>: Substrate's counter test, on an
# install of this template.
# =============================================================================
# The test the Substrate spike proved (its scripts/test.sh), run from a place
# the policy in components/substrate/network-policies.yaml admits: a Job in
# ate-system labelled infrared.darkshift.io/substrate-client. It
#
#   1. creates a counter actor from the template counter-v1 in the atespace
#      platform, and sends it three requests through the router: both its
#      counters, one in memory and one on disk, go 1, 2, 3;
#   2. suspends it: a Full snapshot to SeaweedFS's bucket ate-snapshots, listed
#      there with Substrate's own S3 keys;
#   3. deletes the worker pod it ran on, so the resume has to land on another;
#   4. sends the fourth request, which wakes it from its snapshot on another
#      worker with both counters at 4;
#   5. suspends and deletes the actor (Substrate deletes only a suspended one).
#
# It fails on any broken expectation, prints atelet's timings for the actor, and
# removes the Job, its ConfigMap, the ServiceAccount substrate-check and its
# Role in ate-workers (delete pods, to delete the worker) unless KEEP=1.
#
# PHASE splits it in two around a rebuild, for the full drill: PHASE=prepare
# ACTOR=<name> does 1 and 2 and keeps the suspended actor; PHASE=resume
# ACTOR=<name>, on the restored install, sends the fourth request, which has to
# wake it from its snapshot with both counters at 4, then does 5. The default,
# PHASE=all, is the whole test with an actor of its own.
# Needs: kubectl, jq. Applies objects in ate-system and ate-workers only.
# =============================================================================
set -euo pipefail
CTX="${1:?usage: [PHASE=all|prepare|resume ACTOR=<name>] scripts/substrate-counter-test.sh <kube context>}"
PHASE="${PHASE:-all}"
ACTOR="${ACTOR:-}"
case "$PHASE" in
  all) ;;
  prepare | resume) [[ "$ACTOR" =~ ^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$ ]] || { echo "PHASE=$PHASE needs ACTOR=<a name: lowercase letters, digits and hyphens>" >&2; exit 2; } ;;
  *) echo "PHASE is all, prepare or resume, not $PHASE" >&2; exit 2 ;;
esac
# shellcheck source-path=SCRIPTDIR source=substrate-lib.sh
. "$(dirname "$0")/substrate-lib.sh"
preflight

job="substrate-counter-test-$(date -u +%Y%m%d-%H%M%S)"
start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
[ "${KEEP:-}" = 1 ] || trap 'cleanup_client "$job"' EXIT

log "the Job $job in ate-system on $CTX"
client_account
k apply -f - >/dev/null <<'EOF'
# The worker the actor ran on is deleted, so the resume lands on another.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: substrate-check
  namespace: ate-workers
  labels:
    app.kubernetes.io/part-of: substrate-check
rules:
  - apiGroups: [""]
    resources: ["pods"]
    # delete --wait watches the pod until it is gone.
    verbs: ["get", "list", "watch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: substrate-check
  namespace: ate-workers
  labels:
    app.kubernetes.io/part-of: substrate-check
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: substrate-check
subjects:
  - kind: ServiceAccount
    name: substrate-check
    namespace: ate-system
EOF

# shellcheck disable=SC2016 # expanded in the Job's shell, not here
script='
A=platform
ACT="${FIXED_ACT:-t-$(date -u +%Y%m%d-%H%M%S)}"
FAILS=0
check() { # check <what> <command...>
  what=$1
  shift
  if "$@"; then echo "  ok    $what"; else echo "  FAIL  $what"; FAILS=$((FAILS + 1)); fi
}
actor() { actor_ref "$A" "$ACT" | ate GetActor; }
different() { [ -n "$1" ] && [ "$1" != "$2" ]; }
hit() { # hit <n>: one POST through the router; HTTP 200 and both counters at n
  rm -f /tmp/body
  out="$(curl -s -m 120 -o /tmp/body -w "%{http_code} %{time_total}" -X POST -H "ate-target-actor: $A/$ACT" "$ROUTER/" || true)"
  code=${out%% *}
  secs=${out##* }
  mem="$(sed -n "s/.*preserved memory count: \([0-9]*\).*/\1/p" /tmp/body 2>/dev/null || true)"
  file="$(sed -n "s/.*preserved file counter: \([0-9]*\).*/\1/p" /tmp/body 2>/dev/null || true)"
  check "request $1: HTTP $code in ${secs}s, counters ${mem:-?} and ${file:-?} (want 200, $1 and $1)" [ "$code:$mem:$file" = "200:$1:$1" ]
}
# A prepared actor is kept for its resume, after a rebuild.
[ "$PHASE" = prepare ] || trap "remove_actor \"\$A\" \"\$ACT\"" EXIT

W1=""
if [ "$PHASE" != resume ]; then
echo "actor $A/$ACT, from the template counter-v1"
printf "{\"actor\":{\"metadata\":{\"atespace\":\"%s\",\"name\":\"%s\"},\"actorTemplate\":{\"atespace\":\"%s\",\"name\":\"counter-v1\"}}}" "$A" "$ACT" "$A" | ate CreateActor >/dev/null
for n in 1 2 3; do hit "$n"; done
W1="$(actor | jq -r ".status.workerAssignment.workerPod // empty")"
check "the actor runs on a worker ($W1)" [ -n "$W1" ]

echo "suspend"
t0="$(date +%s)"
actor_ref "$A" "$ACT" | ate SuspendActor >/dev/null
echo "  suspended in about $(( $(date +%s) - t0 ))s"
STATE="$(actor | jq -r ".status.state")"
check "the actor is suspended ($STATE)" [ "$STATE" = ACTOR_STATE_SUSPENDED ]
URI="$(actor | jq -r ".status.externalSnapshot.snapshotUri // empty")"
echo "  snapshot $URI"
PREFIX="$(echo "$URI" | sed -E "s#^[a-z0-9]+://[^/]+/##")"
# SeaweedFS takes path-style requests: the bucket in the path, not the name.
printf "[default]\ns3 =\n    addressing_style = path\n" >/tmp/aws-config
OBJECTS="$(AWS_CONFIG_FILE=/tmp/aws-config aws --endpoint-url "$AWS_ENDPOINT_URL" s3api list-objects-v2 \
  --bucket ate-snapshots --prefix "$PREFIX/" --query "Contents[].[Key,Size]" --output text 2>&1 || true)"
for f in manifest.json checkpoint.img.zstd pages.img.zstd; do
  check "the snapshot in the bucket ate-snapshots has $f" grep -q "/$f" <<SNAP
$OBJECTS
SNAP
done
echo "  $(echo "$OBJECTS" | awk "{s += \$2} END {print s + 0}") bytes in the bucket"
fi

if [ "$PHASE" = all ]; then
echo "delete the worker $W1, so the resume lands on another"
if [ -n "$W1" ]; then kubectl -n ate-workers delete pod "$W1" --wait=true >/dev/null; fi
fi

W2=""
if [ "$PHASE" != prepare ]; then
echo "resume"
STATE="$(actor | jq -r ".status.state")"
check "the actor is there, suspended, before its fourth request ($STATE)" [ "$STATE" = ACTOR_STATE_SUSPENDED ]
hit 4
W2="$(actor | jq -r ".status.workerAssignment.workerPod // empty")"
if [ "$PHASE" = all ]; then check "resumed on another worker ($W2, not $W1)" different "$W2" "$W1"; fi
fi

echo "RESULT {\"actor\": \"$A/$ACT\", \"worker_before\": \"$W1\", \"worker_after\": \"$W2\", \"failed_checks\": $FAILS}"
[ "$FAILS" -eq 0 ]
'

rc=0
client_job "$job" "PHASE=$PHASE
FIXED_ACT=$ACTOR
$script" || rc=$?

log "atelet's timings for this run"
for ds in $(k -n ate-system get daemonsets -l app=atelet -o name); do
  k -n ate-system logs "$ds" --since-time="$start" --all-containers 2>/dev/null |
    jq -cR --arg actor "$ACTOR" 'fromjson? | select(.msg == "Restore timing breakdown" or .msg == "Checkpoint timing breakdown")
      | select((.["ate.actor.name"] // "") | startswith("t-") or . == $actor)
      | {msg, actor: .["ate.actor.name"], snapshot: .["ate.snapshot.kind"],
         total: (.["ate.actor.restore.duration.total"] // .["ate.actor.checkpoint.duration.total"]),
         transfer: (.["ate.actor.restore.duration.download"] // .["ate.actor.checkpoint.duration.persist"])}' || true
done

if [ "$rc" -eq 0 ]; then log "PASS: the counter test ($PHASE), on $CTX"; else log "FAIL: the counter test ($PHASE), on $CTX"; fi
exit "$rc"
