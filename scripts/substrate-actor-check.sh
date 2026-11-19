#!/usr/bin/env bash
# =============================================================================
# substrate-actor-check.sh <kube context>: one actor, as Infrared's operator
# runs an agent step's, keeps the runner's secrets from the container beside it
# (infrared-docs-internal ADR 0089 D4's gate, before any real credential enters
# an actor).
# =============================================================================
# From a Job in Infrared's namespace that runs as the operator's own
# ServiceAccount (the API's one bootstrap owner) with the operator's pod
# certificate (the router's one admitted client), and the labels the API's and
# the router's NetworkPolicies admit (never the operator Deployment's
# selector), it makes an atespace of its own, a template of two containers on
# the WorkerPool agents, and an actor of it with an egress policy that names
# api.anthropic.com alone:
#
#   runner    the runner image in its one-shot serve mode with --dry-run
#             (its own files as the step's repo, so no forge is reached), a
#             canary in its environment, started as the operator starts it:
#             through substrate-actor-launch.sh, the CNB launcher without its
#             exec.d, which gVisor's missing cgroup filesystem breaks
#   selftest  the same image, as the same user, printing what it can see and
#             reach from beside the runner (substrate-actor-check-selftest.js)
#             to the worker's log
#
# then starts one step through the router with a dummy credential in the start
# request, polls it to its end, and reads the worker's log. It passes when:
# the step was taken (202) and answered done; the self-test sees none of the
# runner's processes, no other process's environment or memory, gets 409 for a
# second step and 401 for a poll without the step's token; api.anthropic.com
# is reached and an unlisted host is not; and the dummy credential is in
# neither the template nor Substrate's database. A self-test that sees the
# runner's processes means the containers share a PID namespace: stop there.
# Everything it made is deleted afterwards, whatever the outcome, unless
# KEEP=1. CLEANUP=<atespace> deletes what a run that died midway left in that
# atespace (its actor, its template and the atespace) and checks nothing.
# Needs: kubectl, jq, openssl. The WorkerPool agents (runner.actors on).
# =============================================================================
set -euo pipefail
CTX="${1:?usage: substrate-actor-check.sh <kube context>}"
here="$(cd "$(dirname "$0")" && pwd)"
lib="${SUBSTRATE_LIB:-$here/substrate-lib.sh}"
# shellcheck source=/dev/null
. "$lib"
preflight
command -v openssl >/dev/null || die "missing tool: openssl"

ns="$(k get deploy -A -l app.kubernetes.io/component=operator,app.kubernetes.io/name=infrared -o jsonpath='{.items[0].metadata.namespace}')"
[ -n "$ns" ] || die "no Infrared operator on $CTX"
runner="$(k -n "$ns" get deploy infrared-operator -o json | jq -r '.spec.template.spec.containers[0].env[] | select(.name == "INFRARED_RUNNER_IMAGE") | .value')"
grep -qE '^[^@ ]+@sha256:[0-9a-f]{64}$' <<<"$runner" || die "the operator's runner image is not pinned by digest: $runner"
[ -n "$(k -n ate-workers get workerpools.ate.dev agents -o name 2>/dev/null)" ] || die "no WorkerPool agents on $CTX: turn the chart's runner.actors on first"

stamp="$(date -u +%Y%m%d-%H%M%S)"
atespace="${CLEANUP:-actor-check-$stamp}"
case "$atespace" in actor-check-*) ;; *) die "CLEANUP names an atespace of this check's, actor-check-<stamp>, not $atespace" ;; esac
job="substrate-actor-check-$stamp"
canary="ACTORCHECKCANARY$(openssl rand -hex 8)"
secret="ACTORCHECKSECRET$(openssl rand -hex 8)"
token="$(openssl rand -hex 32)"
log "the actor $atespace/check, its runner from $runner"

work="$(mktemp -d)"
cleanup() {
  rm -f "$work/check.sh" && rmdir "$work" 2>/dev/null || true
  k -n "$ns" delete job "$job" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  k -n "$ns" delete configmap "$job" --ignore-not-found >/dev/null 2>&1 || true
}
[ "${KEEP:-}" = 1 ] || trap cleanup EXIT

{ client_preamble; cat "$here/substrate-actor-check-job.sh"; } >"$work/check.sh"
k -n "$ns" create configmap "$job" --from-file=selftest.js="$here/substrate-actor-check-selftest.js" --from-file=check.sh="$work/check.sh" \
  --from-file=launch.sh="$here/substrate-actor-launch.sh" \
  --dry-run=client -o yaml | k apply -f - >/dev/null
k label -n "$ns" configmap "$job" app.kubernetes.io/part-of=substrate-actor-check --overwrite >/dev/null

k apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $job
  namespace: $ns
  labels:
    app.kubernetes.io/part-of: substrate-actor-check
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 1500
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app.kubernetes.io/part-of: substrate-actor-check
        # What the API's and the router's NetworkPolicies admit, without
        # app.kubernetes.io/instance: no Deployment or Service of the
        # operator's selects this pod.
        app.kubernetes.io/name: infrared
        app.kubernetes.io/component: operator
    spec:
      serviceAccountName: infrared-operator
      automountServiceAccountToken: false
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        runAsGroup: 65534
        seccompProfile:
          type: RuntimeDefault
      initContainers:
        - name: tools
          image: $SUBSTRATE_GRPCURL_IMAGE
          command: ["/bin/sh", "-ec", "cp /bin/grpcurl /tools/grpcurl"]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: [ALL]
          volumeMounts:
            - name: tools
              mountPath: /tools
      containers:
        - name: check
          image: $SUBSTRATE_K8S_IMAGE
          command: ["/bin/sh", "-e", "/check/check.sh"]
          env:
            - name: HOME
              value: /tmp
            - name: CA
              value: /run/ate-ca/trust-bundle.pem
            - name: ATESPACE
              value: "$atespace"
            - name: RUNNER_IMAGE
              value: "$runner"
            - name: CANARY
              value: "$canary"
            - name: SECRET
              value: "$secret"
            - name: POLL_TOKEN
              value: "$token"
            - name: KEEP
              value: "${KEEP:-0}"
            - name: CLEANUP_ONLY
              value: "${CLEANUP:+1}"
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: [ALL]
          volumeMounts:
            - {name: tools, mountPath: /tools, readOnly: true}
            - {name: check, mountPath: /check, readOnly: true}
            - {name: ate-ca, mountPath: /run/ate-ca, readOnly: true}
            - {name: ate-token, mountPath: /run/ate-token, readOnly: true}
            - {name: router, mountPath: /run/router, readOnly: true}
            - {name: tmp, mountPath: /tmp}
      volumes:
        - name: tools
          emptyDir: {}
        - name: check
          configMap:
            name: $job
        - name: ate-ca
          projected:
            sources:
              - clusterTrustBundle:
                  signerName: servicedns.podcert.ate.dev/identity
                  labelSelector:
                    matchLabels:
                      podcert.ate.dev/canarying: live
                  path: trust-bundle.pem
        - name: ate-token
          projected:
            sources:
              - serviceAccountToken:
                  audience: api.ate-system.svc
                  expirationSeconds: 900
                  path: token
        - name: router
          projected:
            sources:
              - podCertificate:
                  signerName: podidentity.podcert.ate.dev/identity
                  keyType: ECDSAP256
                  credentialBundlePath: credential-bundle.pem
              - clusterTrustBundle:
                  signerName: servicedns.podcert.ate.dev/identity
                  labelSelector:
                    matchLabels:
                      podcert.ate.dev/canarying: live
                  path: router-ca.pem
        - name: tmp
          emptyDir: {}
EOF

# The Job's own lines, once it has waited out the self-test's rounds.
deadline=$((SECONDS + 1500))
until k -n "$ns" logs "job/$job" -c check 2>/dev/null | grep -q 'ACTOR-CHECK-JOB waited'; do
  phase="$(k -n "$ns" get job "$job" -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type} {end}' 2>/dev/null || true)"
  case "$phase" in *Failed*) k -n "$ns" logs "job/$job" --all-containers 2>/dev/null || true; die "the check's Job failed" ;; esac
  [ "$SECONDS" -lt "$deadline" ] || die "the check's Job did not finish in 25 minutes"
  sleep 5
done
joblog="$(k -n "$ns" logs "job/$job" -c check 2>/dev/null | grep '^ACTOR-CHECK-JOB ' | sed 's/^ACTOR-CHECK-JOB //')"
jl() { sed -n "s/^$1 //p" <<<"$joblog" | tail -n 1; }
if [ -n "${CLEANUP:-}" ]; then
  [ "$(jl deleted)" = true ] || die "$atespace: its actor, its template or the atespace is still there"
  log "deleted what $atespace held: its actor, its template and the atespace"
  exit 0
fi

# The self-test's lines, from the worker that ran the actor: its last round.
self="$(for p in $(k -n ate-workers get pods -o name); do k -n ate-workers logs "$p" --all-containers 2>/dev/null || true; done |
  grep -o 'ACTOR-CHECK [a-z-]* [^;]*;;' | sed 's/ *;;$//' || true)"
last() { grep "^ACTOR-CHECK $1 " <<<"$self" | tail -n 1 | sed "s/^ACTOR-CHECK $1 //"; }

# Substrate's database holds no credential of the step.
pg="$(k -n stores get pods -l cnpg.io/cluster=postgres,cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')"
# shellcheck disable=SC2016 # $0 is the pod's shell's, the secret passed as its argument
in_db="$(k -n stores exec "$pg" -c postgres -- sh -c 'pg_dump -U postgres -d substrate_v1 | grep -c "$0" || true' "$secret")"

fails=0
check() { # check <description> <got> <want, an extended regex>
  if grep -qxE "$3" <<<"$2"; then echo "  ok    $1: $2"; else echo "  FAIL  $1: got '$2', want /$3/"; fails=$((fails + 1)); fi
}
log "the step, through the router"
check "the runner took the step" "$(jl start)" '202'
check "its poll answered done" "$(jl poll | cut -d' ' -f1-2)" '200 done'
check "its verdict: a dry run, of the runner's own files as the repo" "$(jl poll | cut -d' ' -f3)" 'DRY-RUN'
log "beside the runner (the self-test, $(last whoami))"
procs="$(last processes)"
if [ -z "$procs" ] || [ "$(last "done")" != true ]; then
  echo "  FAIL  the self-test's last round is not in the workers' logs: nothing is known of what it sees"
  fails=$((fails + 1))
elif grep -q -- '--serve' <<<"$procs"; then
  echo "  FAIL  the self-test sees the runner's processes: the containers share a PID namespace: STOP"
  fails=$((fails + 1))
else
  echo "  ok    the self-test sees none of the runner's processes, only its own: $procs"
fi
check "no other process's environment" "$(last other-environ-readable)" '0'
check "no canary or credential in any environment it reads" "$(last canary-seen)" 'false'
check "no other process's memory" "$(last other-mem-openable)" '0'
check "a second step on the runner's port" "$(last second-step)" '409'
check "a poll without the step's token" "$(last poll-without-token)" '401'
check "a poll with another token" "$(last poll-wrong-token)" '401'
check "egress to a host the policy names" "$(last egress-listed)" 'connected:verified'
check "egress to a host it does not name" "$(last egress-unlisted)" 'error:.*'
log "where a credential must never be"
check "the dummy credential in the template" "$(jl template-holds-secret)" '0'
check "the dummy credential in Substrate's database" "$in_db" '0'
check "the canary in the template, as written (the check of the check)" "$(jl template-holds-canary)" '[1-9][0-9]*'

if [ "$fails" -eq 0 ]; then
  log "PASS: an actor keeps the runner's secrets from the container beside it on $CTX"
else
  log "FAIL: $fails check(s) did not hold on $CTX"
  exit 1
fi
