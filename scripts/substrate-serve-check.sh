#!/usr/bin/env bash
# =============================================================================
# substrate-serve-check.sh <kube context>: Agent Substrate 1.0's control plane
# serves, on an install of this template.
# =============================================================================
# The counter test it replaces ran upstream's counter demo, a test actor that
# Substrate 1.0 no longer publishes; nothing of Infrared's runs as an actor
# yet, and only Infrared's operator may make one. So this checks what serves
# without an actor, from outside and from a Job in ate-system that the
# NetworkPolicies admit (labelled infrared.darkshift.io/substrate-client):
#
#   1. the CRDs serve ate.dev/v1, and the SandboxConfig gvisor-default is the
#      gVisor class default;
#   2. every workload is ready: the pod-certificate controller, the API, the
#      identity provider, the controller, the router and the egress gateway
#      (each Deployment's replicas all ready), and atelet on every node it is
#      scheduled to;
#   3. the trust bundles are published: the pod-certificate controller's
#      three, and the egress CA's, which the controller publishes from
#      egress-mitm-ca-pool;
#   4. from the Job: the identity provider serves its discovery document for
#      the issuer https://idp.ate-system.svc and at least one key; the API
#      lists substrate.ateapi.v1.Control by reflection to a caller it
#      authenticates, and answers that caller's ListAtespaces with
#      PermissionDenied, which takes its authentication, its authorization and
#      its records in Postgres; and the router answers TLS on both its ports
#      with a certificate the service-DNS bundle verifies.
#
# What gets through, and what does not, is substrate-fence-check.sh's. The Job
# and the ServiceAccount substrate-check are removed afterwards unless KEEP=1.
# Nothing is made in Substrate.
# Needs: kubectl, jq. Applies objects in ate-system only.
# =============================================================================
set -euo pipefail
CTX="${1:?usage: scripts/substrate-serve-check.sh <kube context>}"
# shellcheck source-path=SCRIPTDIR source=substrate-lib.sh
. "$(dirname "$0")/substrate-lib.sh"
preflight

job="substrate-serve-check-$(date -u +%Y%m%d-%H%M%S)"
[ "${KEEP:-}" = 1 ] || trap 'cleanup_client "$job"' EXIT
fails=0
pass() { echo "  ok    $*"; }
fail() {
  echo "  FAIL  $*"
  fails=$((fails + 1))
}

log "1. the CRDs at ate.dev/v1, and the gVisor SandboxConfig"
for crd in workerpools.ate.dev sandboxconfigs.ate.dev csidriverconfigs.ate.dev; do
  case " $(k get crd "$crd" -o jsonpath='{.spec.versions[*].name}' 2>/dev/null) " in
    *" v1 "*) pass "$crd serves ate.dev/v1" ;;
    *) fail "$crd does not serve ate.dev/v1" ;;
  esac
done
default="$(k get sandboxconfigs.v1.ate.dev gvisor-default -o jsonpath='{.metadata.annotations.sandboxconfig\.ate\.dev/is-class-default} {.spec.sandboxClass} {.spec.defaultVersion}' 2>/dev/null || true)"
case "$default" in
  "true gvisor "?*) pass "SandboxConfig gvisor-default is the gVisor class default, version ${default##* }" ;;
  *) fail "SandboxConfig gvisor-default is missing or not the gVisor class default ($default)" ;;
esac

log "2. every workload ready"
for d in podcertificate-controller-system/podcertificate-controller ate-system/ate-api-server ate-system/ate-idp-server \
  ate-system/ate-controller ate-system/atenet-router ate-system/atenet-egress; do
  got="$(k -n "${d%%/*}" get deployment "${d#*/}" -o jsonpath='{.spec.replicas} {.status.readyReplicas} {.status.updatedReplicas}' 2>/dev/null || true)"
  read -r want ready updated <<<"$got"
  if [ -n "${want:-}" ] && [ "$want" -gt 0 ] && [ "${ready:-0}" = "$want" ] && [ "${updated:-0}" = "$want" ]; then
    pass "Deployment $d: $ready of $want ready"
  else
    fail "Deployment $d is not ready (${got:-absent}: replicas, ready, updated)"
  fi
done
got="$(k -n ate-system get daemonset atelet -o jsonpath='{.status.desiredNumberScheduled} {.status.numberReady}' 2>/dev/null || true)"
read -r want ready <<<"$got"
if [ -n "${want:-}" ] && [ "$want" -gt 0 ] && [ "${ready:-0}" = "$want" ]; then
  pass "DaemonSet ate-system/atelet: ready on $ready of $want nodes"
else
  fail "DaemonSet ate-system/atelet is not ready everywhere (${got:-absent}: scheduled, ready)"
fi

log "3. the trust bundles"
for b in servicedns.podcert.ate.dev:identity:primary-bundle podidentity.podcert.ate.dev:identity:primary-bundle \
  postgres.podcert.ate.dev:identity:primary-bundle egress-mitm.ate.dev:mitm:primary-bundle; do
  if [ -n "$(k get clustertrustbundles "$b" -o jsonpath='{.spec.trustBundle}' 2>/dev/null)" ]; then
    pass "ClusterTrustBundle $b"
  else
    fail "no ClusterTrustBundle $b"
  fi
done

log "4. from ate-system: the identity provider, the API and the router answer"
client_account
# shellcheck disable=SC2016 # expanded in the Job's shell, not here
script='
rc=0
issuer=https://idp.ate-system.svc
if curl -sS -m 10 --cacert "$CA" "$issuer/.well-known/openid-configuration" -o /tmp/discovery 2>/tmp/err \
  && [ "$(jq -r .issuer /tmp/discovery)" = "$issuer" ] \
  && curl -sS -m 10 --cacert "$CA" "$(jq -r .jwks_uri /tmp/discovery)" -o /tmp/jwks 2>>/tmp/err \
  && [ "$(jq "[.keys[]?] | length" /tmp/jwks)" -ge 1 ]; then
  echo "  ok    the identity provider serves $issuer and $(jq "[.keys[]] | length" /tmp/jwks) key(s): $(jq -r "[.keys[] | .kid + \" \" + .alg] | join(\", \")" /tmp/jwks)"
else
  echo "  FAIL  the identity provider does not serve $issuer and a key: $(tail -n 1 /tmp/err)"
  rc=1
fi

if ate_list >/tmp/services 2>&1 && grep -qx substrate.ateapi.v1.Control /tmp/services; then
  echo "  ok    the API lists substrate.ateapi.v1.Control to a caller it authenticates"
else
  echo "  FAIL  the API does not list substrate.ateapi.v1.Control:"
  sed "s/^/    /" /tmp/services
  rc=1
fi
echo "{}" | ate ListAtespaces >/tmp/answer 2>&1 || true
if grep -q PermissionDenied /tmp/answer; then
  echo "  ok    the API authorizes: substrate-check, no owner, may not list atespaces (PermissionDenied)"
else
  echo "  FAIL  the API did not answer substrate-check with PermissionDenied:"
  sed "s/^/    /" /tmp/answer
  rc=1
fi

# The router serves TLS with a certificate CA verifies: a client it does not
# admit is refused in the handshake (35, 55 or 56), never unreachable (6, 7, 28)
# and never with an unverified certificate (60).
for port in 443 8444; do
  r="$(router "$port")"
  case "$r" in
    "35 000" | "55 000" | "56 000") echo "  ok    the router answers TLS on $port, with a certificate the service-DNS bundle verifies (curl $r)" ;;
    *)
      echo "  FAIL  the router on $port: curl exit and status $r: $(tail -n 1 /tmp/curl.err)"
      rc=1 ;;
  esac
done
exit "$rc"
'
client_job "$job" "$script" || fails=$((fails + 1))

if [ "$fails" -eq 0 ]; then
  log "PASS: Substrate 1.0's control plane serves on $CTX"
else
  log "FAIL: $fails check(s) did not hold on $CTX"
  exit 1
fi
