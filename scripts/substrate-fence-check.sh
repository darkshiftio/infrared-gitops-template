#!/usr/bin/env bash
# =============================================================================
# substrate-fence-check.sh <kube context> [organization namespace]: only
# Infrared's operator reaches Substrate's API and router.
# =============================================================================
# The NetworkPolicies in components/substrate/network-policies.yaml admit to the
# API and the router only Infrared's operator, Substrate's own components and
# the platform's jobs in ate-system. This calls both from three places they do
# not admit, and passes when every call is refused:
#
#   1. a pod in an organization's namespace (the first labelled
#      infrared.darkshift.io/org, or the one named), which first reaches the
#      Kubernetes API, so its network works;
#   2. a pod in ate-workers, the namespace the worker pods run in: what an actor
#      that broke out of its sandbox would have;
#   3. inside the test actor: a sandbox-v1 actor in the atespace platform runs
#      the same calls, sent to it through the router from a Job in ate-system
#      (a place the policy admits, which also shows the API and the router
#      answer). An actor's traffic leaves its sandbox only through the egress
#      gateway, and no EgressPolicy names either.
#
# A refused call is a connection that never opens: the policy drops it, so it
# times out. Every probe pod and Job, the ServiceAccount substrate-check and the
# actor are removed afterwards unless KEEP=1.
# Needs: kubectl, jq. Applies objects in that organization's namespace,
# ate-workers and ate-system only.
# =============================================================================
set -euo pipefail
CTX="${1:?usage: scripts/substrate-fence-check.sh <kube context> [organization namespace]}"
# shellcheck source-path=SCRIPTDIR source=substrate-lib.sh
. "$(dirname "$0")/substrate-lib.sh"
preflight

org_ns="${2:-$(k get namespaces -l infrared.darkshift.io/org -o jsonpath='{.items[0].metadata.name}')}"
[ -n "$org_ns" ] || die "no organization's namespace (label infrared.darkshift.io/org) on $CTX: name one"
stamp="$(date -u +%Y%m%d-%H%M%S)"
job="substrate-fence-check-$stamp"
probe_pods=()
cleanup() {
  local p
  for p in "${probe_pods[@]+"${probe_pods[@]}"}"; do
    k -n "${p%%/*}" delete pod "${p#*/}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
  cleanup_client "$job"
}
[ "${KEEP:-}" = 1 ] || trap cleanup EXIT

# The calls a probe pod makes: the control first, then the API and the router.
# It exits 0 only when the control answers and both are refused.
# shellcheck disable=SC2016 # expanded in the probe's shell, not here
probe_script='
rc=0
if nc -z -w 5 kubernetes.default.svc 443; then
  echo "  control: kubernetes.default.svc:443 answers from here"
else
  echo "  FAIL  control: this pod reaches nothing, so a refusal proves nothing"
  rc=1
fi
if nc -z -w 5 api.ate-system.svc 443; then
  echo "  FAIL  Substrate API api.ate-system.svc:443 accepted a connection"
  rc=1
else
  echo "  ok    Substrate API api.ate-system.svc:443 refused (no connection in 5s)"
fi
code="$(curl -s -m 5 -o /dev/null -w "%{http_code}" -X POST -H "ate-target-actor: platform/fence" http://atenet-router.ate-system.svc/ || true)"
if [ "$code" = 000 ]; then
  echo "  ok    Substrate router atenet-router.ate-system.svc:80 refused (no answer in 5s)"
else
  echo "  FAIL  Substrate router atenet-router.ate-system.svc:80 answered HTTP $code"
  rc=1
fi
exit "$rc"'

# probe <namespace>: runs probe_script in a pod there; 0 when it passed.
probe() {
  local ns=$1 name="substrate-fence-probe-$stamp" phase=""
  probe_pods+=("$ns/$name")
  k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $name
  namespace: $ns
  labels:
    app.kubernetes.io/part-of: substrate-check
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: probe
      image: $SUBSTRATE_K8S_IMAGE
      command: ["/bin/sh", "-c", $(jq -Rn --arg s "$probe_script" '$s')]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
EOF
  local deadline=$((SECONDS + 180))
  while [ "$SECONDS" -lt "$deadline" ]; do
    phase="$(k -n "$ns" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "$phase" in Succeeded | Failed) break ;; esac
    sleep 2
  done
  k -n "$ns" logs "$name" 2>/dev/null || true
  [ "$phase" = Succeeded ]
}

fails=0
log "1. from the organization's namespace $org_ns"
probe "$org_ns" || fails=$((fails + 1))
log "2. from ate-workers, the workers' namespace"
probe ate-workers || fails=$((fails + 1))

log "3. from inside the test actor (a sandbox-v1 actor, asked through the router from ate-system)"
client_account
# shellcheck disable=SC2016 # expanded in the Job's shell, not here
script='
A=platform
ACT="fence-$(date -u +%Y%m%d-%H%M%S)"
trap "remove_actor \"\$A\" \"\$ACT\"" EXIT
printf "{\"actor\":{\"metadata\":{\"atespace\":\"%s\",\"name\":\"%s\"},\"actorTemplate\":{\"atespace\":\"%s\",\"name\":\"sandbox-v1\"}}}" "$A" "$ACT" "$A" | ate CreateActor >/dev/null
echo "  the actor $A/$ACT, made through the API from here"
# What the actor runs: each call refused unless it got an HTTP answer. busybox
# wget says "server returned error" when one came back with an error status.
inside="for t in api.ate-system.svc.cluster.local:443 atenet-router.ate-system.svc.cluster.local:80; do
  if wget -q -T 5 -O /dev/null http://\$t/ 2>/tmp/e || grep -q \"server returned\" /tmp/e; then
    echo \"ANSWERED \$t\"
  else
    echo \"REFUSED \$t: \$(cat /tmp/e)\"
  fi
done"
body="$(jq -cn --arg c "$inside" "{command: [\"sh\", \"-c\", \$c], timeout: \"60s\"}")"
code="$(curl -s -m 120 -o /tmp/answer -w "%{http_code}" -X POST -H "ate-target-actor: $A/$ACT" \
  -H "Content-Type: application/json" --data "$body" "$ROUTER/process" || true)"
if [ "$code" != 200 ]; then
  echo "  FAIL  the router did not reach the actor (HTTP $code), so nothing ran inside it"
  exit 1
fi
echo "  the router reached the actor (HTTP 200); inside it:"
jq -r ".stdout" /tmp/answer | sed "s/^/    /"
rc=0
for t in api.ate-system.svc.cluster.local:443 atenet-router.ate-system.svc.cluster.local:80; do
  if jq -r ".stdout" /tmp/answer | grep -q "^REFUSED $t"; then
    echo "  ok    $t refused from inside the actor"
  else
    echo "  FAIL  $t was not refused from inside the actor"
    rc=1
  fi
done
exit "$rc"
'
client_job "$job" "$script" || fails=$((fails + 1))

if [ "$fails" -eq 0 ]; then
  log "PASS: Substrate's API and router refuse $org_ns, ate-workers and the inside of an actor, on $CTX"
else
  log "FAIL: $fails of 3 places were not refused, or could not be checked, on $CTX"
  exit 1
fi
