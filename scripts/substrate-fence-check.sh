#!/usr/bin/env bash
# =============================================================================
# substrate-fence-check.sh <kube context> [organization namespace]: only
# Infrared's operator gets through to Substrate's API and router.
# =============================================================================
# Agent Substrate 1.0 checks its callers itself, and NetworkPolicies fence it
# beside those checks (components/substrate, network-policies.yaml and the
# patches in kustomization.yaml). This passes when each of these is refused:
#
#   1. from a pod in an organization's namespace (the first labelled
#      infrared.darkshift.io/org, or the one named), which first reaches the
#      Kubernetes API, so its network works: a connection to the API or to the
#      router, refused by the NetworkPolicies (it never opens);
#   2. the same from a pod in ate-workers, the namespace the worker pods run in:
#      what an actor that broke out of its sandbox would have;
#   3. from a Job in ate-system that the NetworkPolicies admit (labelled
#      infrared.darkshift.io/substrate-client), which also shows the API and
#      the router answer:
#        - the API, called with no credential: Unauthenticated;
#        - the API, called as the Job's ServiceAccount substrate-check, which
#          it authenticates but which is not its bootstrap owner and which no
#          access policy names, to list and to create an atespace:
#          PermissionDenied;
#        - the router, on its HTTPS port (the Service's 443) and on its CONNECT
#          port (8444), with no client certificate, and with the Job's own
#          certificate from the pod-identity signer, a SPIFFE ID not on its
#          allowlist: refused in the TLS handshake, after the router presented
#          a certificate the service-DNS bundle verifies, with no HTTP answer.
#
# Every probe pod and Job, and the ServiceAccount substrate-check, are removed
# afterwards unless KEEP=1. Nothing is made in Substrate while it refuses as it
# should; if it let substrate-check create the atespace substrate-fence-check,
# the check fails and says so, and that atespace is a person's to delete.
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

# The calls a probe pod makes: the control first, then the API and the router's
# two ports. It exits 0 only when the control answers and every other is
# refused, a connection that never opens.
# shellcheck disable=SC2016 # expanded in the probe's shell, not here
probe_script='
rc=0
if nc -z -w 5 kubernetes.default.svc 443; then
  echo "  control: kubernetes.default.svc:443 answers from here"
else
  echo "  FAIL  control: this pod reaches nothing, so a refusal proves nothing"
  rc=1
fi
for t in api.ate-system.svc:443 atenet-router.ate-system.svc:443 atenet-router.ate-system.svc:8444; do
  if nc -z -w 5 "${t%:*}" "${t##*:}"; then
    echo "  FAIL  $t accepted a connection"
    rc=1
  else
    echo "  ok    $t refused (no connection in 5s)"
  fi
done
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

log "3. from ate-system, where the NetworkPolicies admit the Job: what Substrate itself refuses"
client_account
# shellcheck disable=SC2016 # expanded in the Job's shell, not here
script='
rc=0
# refused_by_api <code> <answer file>: grpcurl named that code, and answered nothing else.
refused_by_api() { grep -q "$1" "$2" && ! grep -q "^{" "$2"; }

echo "{}" | ate_anon ListAtespaces >/tmp/anon 2>&1 || true
if refused_by_api Unauthenticated /tmp/anon; then
  echo "  ok    the API refuses a caller with no credential: Unauthenticated"
else
  echo "  FAIL  the API did not refuse a caller with no credential:"
  sed "s/^/    /" /tmp/anon
  rc=1
fi
for call in "ListAtespaces {}" "CreateAtespace {\"atespace\":{\"metadata\":{\"name\":\"substrate-fence-check\"}}}"; do
  method="${call%% *}"
  echo "${call#* }" | ate "$method" >/tmp/answer 2>&1 || true
  if refused_by_api PermissionDenied /tmp/answer; then
    echo "  ok    the API refuses $method to substrate-check, no owner: PermissionDenied"
  else
    echo "  FAIL  the API did not refuse $method to substrate-check:"
    sed "s/^/    /" /tmp/answer
    rc=1
  fi
done

# The router: refused in the handshake (35 or 56, no HTTP status), never
# unreachable (6, 7, 28), never with a certificate CA does not verify (60).
for port in 443 8444; do
  for who in none own; do
    if [ "$who" = own ]; then
      r="$(router "$port" --cert "$POD_CERT" --key "$POD_CERT")"
      words="the Job'"'"'s own certificate, spiffe://cluster.local/ns/ate-system/sa/substrate-check"
    else
      r="$(router "$port")"
      words="no client certificate"
    fi
    case "$r" in
      "35 000" | "56 000")
        echo "  ok    the router on $port refuses $words in the TLS handshake (curl $r)" ;;
      *)
        echo "  FAIL  the router on $port with $words: curl exit and status $r, want 35 or 56 and 000: $(tail -n 1 /tmp/curl.err)"
        rc=1 ;;
    esac
  done
done
exit "$rc"
'
client_job "$job" "$script" || fails=$((fails + 1))

if [ "$fails" -eq 0 ]; then
  log "PASS: Substrate's API and router refuse $org_ns and ate-workers outright, and, from ate-system, a caller who is no owner and a client not on the allowlist, on $CTX"
else
  log "FAIL: $fails of 3 places were not refused as they should be, or could not be checked, on $CTX"
  exit 1
fi
