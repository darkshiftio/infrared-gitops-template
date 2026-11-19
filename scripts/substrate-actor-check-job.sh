# Sourced into the Job of substrate-actor-check.sh, after substrate-lib.sh's
# client_preamble (ate): makes the check's actor as Infrared's operator, starts
# and polls its one step through the router, and deletes it all on any exit
# unless KEEP=1. With CLEANUP_ONLY=1 it deletes the atespace a run that died
# midway left, its actor and its template, and nothing else.
# shellcheck shell=sh
set -e
A="$ATESPACE"
ref="{\"atespace\":\"$A\",\"name\":\"check\"}"
step() { echo "ACTOR-CHECK-JOB $*"; }
# opts <Get method> <request key>: the uid and version a delete of it names,
# or nothing when it is gone.
opts() {
  echo "{\"$2\":$ref}" | ate "$1" 2>/dev/null | jq -c '{uid: .metadata.uid, version: .metadata.version}' 2>/dev/null || true
}
# cleanup: the actor, then its template, then the atespace, each retried while
# the one before it is still going (a delete may finish after it answers);
# "deleted true" once none of the three is left.
cleanup() {
  set +e
  for _ in $(seq 1 30); do
    m="$(opts GetActor actor)"
    [ -z "$m" ] && break
    echo "{\"actor\":$ref,\"options\":$m}" | ate DeleteActor >/dev/null 2>&1
    sleep 2
  done
  for _ in $(seq 1 30); do
    m="$(opts GetActorTemplate actorTemplate)"
    [ -z "$m" ] && break
    echo "{\"actorTemplate\":$ref,\"options\":$m}" | ate DeleteActorTemplate >/dev/null 2>&1
    sleep 2
  done
  for _ in $(seq 1 30); do
    echo "{\"atespace\":{\"name\":\"$A\"}}" | ate DeleteAtespace >/dev/null 2>&1 && break
    sleep 2
  done
  left="$(opts GetActor actor)$(opts GetActorTemplate actorTemplate)"
  echo "{\"atespace\":{\"name\":\"$A\"}}" | ate GetAtespace >/dev/null 2>&1 && left="${left}atespace"
  step deleted "$([ -z "$left" ] && echo true || echo false)"
}
if [ "$CLEANUP_ONLY" = 1 ]; then
  cleanup
  step waited
  exit 0
fi
[ "$KEEP" = 1 ] || trap cleanup EXIT
# ate_wait <method>: ate, given ten minutes: a resume returns once the actor's
# wakeup probe passes, after a worker's first pull of the runner image.
ate_wait() {
  # shellcheck disable=SC2016 # grpcurl expands ${ATE_TOKEN} itself (-expand-headers), so no command line holds it
  ATE_TOKEN="$(cat /run/ate-token/token)" /tools/grpcurl -max-time 600 \
    -cacert "$CA" -H 'authorization: Bearer ${ATE_TOKEN}' -expand-headers \
    -d @ api.ate-system.svc:443 "substrate.ateapi.v1.Control/$1"
}
router() { # router <method> <path> [curl args...]: an HTTPS request to the actor through the router
  m=$1 p=$2
  shift 2
  curl -sS -m 30 --cacert /run/router/router-ca.pem --cert /run/router/credential-bundle.pem --key /run/router/credential-bundle.pem \
    -H "ate-target-actor: $A/check" -X "$m" "$@" "https://atenet-router.ate-system.svc$p"
}
echo "{\"atespace\":{\"metadata\":{\"name\":\"$A\"}}}" | ate CreateAtespace >/dev/null
jq -n --arg a "$A" --arg img "$RUNNER_IMAGE" --arg canary "$CANARY" --rawfile js /check/selftest.js --rawfile launch /check/launch.sh '{actorTemplate: {
  metadata: {atespace: $a, name: "check"},
  workerSelector: {matchLabels: {"infrared.darkshift.io/worker-pool": "agents"}},
  containers: [
    {name: "runner", image: $img,
     command: ["/bin/sh", "-c", $launch, "launch", "node", "dist/main.js", "--serve", "--listen", "0.0.0.0:80", "--workdir", "/tmp/work",
       "--dry-run", "--local-repo", "/workspace/dist"],
     env: [{name: "HOME", value: "/tmp"}, {name: "INFRARED_WORKDIR", value: "/tmp/work"}, {name: "ACTORCHECK_CANARY", value: $canary}],
     wakeupProbe: {httpGet: {path: "/healthz", port: 80}, timeoutSeconds: 120}},
    {name: "selftest", image: $img, command: ["/bin/sh", "-c", $launch, "launch", "node", "-e", $js],
     env: [{name: "HOME", value: "/tmp"}, {name: "STEP_ID", value: "actor-check-step"}]}],
  resources: {limits: {cpuMillicores: "1000", memoryBytes: "2147483648"}},
  snapshotConfig: {preferredFidelity: "SNAPSHOT_FIDELITY_VOLUMES", goldenSnapshotConfig: {mode: "GOLDEN_SNAPSHOT_MODE_DISABLED"}}}}' |
  ate CreateActorTemplate >/dev/null
jq -n --arg a "$A" '{actor: {metadata: {atespace: $a, name: "check"}, actorTemplate: {atespace: $a, name: "check"}}}' | ate CreateActor >/dev/null
jq -n --arg a "$A" '{actor: {atespace: $a, name: "check"}, egressPolicy: {metadata: {atespace: $a, name: "default"},
  rules: [{tlsPassthrough: {hostnames: ["api.anthropic.com"], ports: {numbers: [443]}}}]}}' | ate CreateActorEgressPolicy >/dev/null
echo "{\"actor\":$ref}" | ate_wait ResumeActor >/dev/null
step resumed
jq -n --arg tok "$POLL_TOKEN" --arg secret "$SECRET" '{id: "actor-check-step", pollToken: $tok,
  spec: {run: "actor-check", step: "check", workflow: "actor-check", org: "actor-check", product: "actor-check", mode: "report",
    branch: "main", repo: {owner: "darkshiftio", name: "actor-check", defaultBranch: "main"}, pullRequest: null,
    change: {issue: null, title: "actor check", body: "", url: ""}, agentRole: {name: "actor-check", spec: {displayName: "Actor check"}},
    previousSteps: []},
  credentials: {anthropicApiKey: $secret}}' >/tmp/start.json
step start "$(router POST /steps -H 'content-type: application/json' --data-binary @/tmp/start.json -o /tmp/start.out -w '%{http_code}')"
rm -f /tmp/start.json
status=running
for _ in $(seq 1 48); do
  code="$(router GET /steps/actor-check-step -H "authorization: Bearer $POLL_TOKEN" -o /tmp/poll.json -w '%{http_code}' || true)"
  status="$(jq -r '.status // "?"' /tmp/poll.json 2>/dev/null || echo '?')"
  [ "$code" = 200 ] && [ "$status" = "done" ] && break
  sleep 5
done
step poll "$code $status $(jq -r '.result.verdict // "-"' /tmp/poll.json 2>/dev/null)"
step template-holds-secret "$(echo "{\"actorTemplate\":$ref}" | ate GetActorTemplate | grep -c "$SECRET" || true)"
step template-holds-canary "$(echo "{\"actorTemplate\":$ref}" | ate GetActorTemplate | grep -c "$CANARY" || true)"
# The self-test's rounds: 90 s after the resume, then every 20 s, three times,
# each up to 30 s of calls: done within 240 s of the resume.
sleep 240
step waited
