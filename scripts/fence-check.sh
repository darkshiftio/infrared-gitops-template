#!/usr/bin/env bash
# =============================================================================
# fence-check.sh <kube context> <org> [another org]: the network fence holds
# on a running install (infrared-docs-internal ADR 0066 D1; README "The network
# fence").
# =============================================================================
# With the fence on (the Infrared chart's tenancy.networkPolicies.enabled),
# every namespace of an org carries the operator's NetworkPolicy
# infrared-fence, and every platform namespace this template makes its own.
# This runs a probe pod in one of <org>'s zones and passes when:
#
#   1. the control answers: the cluster's DNS, and the internet over HTTPS;
#   2. every platform service it tries is refused: SeaweedFS's filer, master
#      and S3 gateway, Postgres, VictoriaMetrics, Grafana, Infrared's API, UI
#      and Gitea, Argo CD's server, the registry, the Kubernetes API, Envoy's
#      own listeners in the cluster, and cloud metadata;
#   3. with [another org], the other org's zone refuses it, and a probe in the
#      other org's zone is refused by <org>'s zone, both ways.
#
# A refused call is a connection that never opens: the policy drops it, so it
# times out in 5 seconds. Every probe pod is removed afterwards unless KEEP=1.
# It proves what kind cannot: GKE Dataplane V2's own behaviour, NodeLocal DNS,
# and the edge behind the tunnel. Run it on the hosted plane after the
# install, before a tenant, with the owner's go-ahead.
# Needs: kubectl, jq. Applies probe pods in the orgs' zones only.
# =============================================================================
set -euo pipefail
CTX="${1:?usage: scripts/fence-check.sh <kube context> <org> [another org]}"
ORG="${2:?usage: scripts/fence-check.sh <kube context> <org> [another org]}"
OTHER="${3:-}"
IMAGE=docker.io/alpine/k8s:1.37.0@sha256:b421c2e9419edb98db39b6ab641669f4db7bb2acf354f22450c6b7e7176d1ff4
INFRARED_NS="${INFRARED_NS:-infrared}"

k() { kubectl --context "$CTX" "$@"; }
log() { printf '\n== %s\n' "$*"; }
die() {
  echo "fence-check: $*" >&2
  exit 1
}

# zone_of <org>: one of the org's zones: a namespace with the org's label and a
# zone's, which the operator stamped.
zone_of() {
  k get namespaces -l "infrared.darkshift.io/org=$1,infrared.darkshift.io/zone" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}
zone="$(zone_of "$ORG")"
[ -n "$zone" ] || die "org $ORG has no zone (a namespace labelled infrared.darkshift.io/org=$ORG and infrared.darkshift.io/zone) on $CTX"
k -n "$zone" get networkpolicy infrared-fence >/dev/null 2>&1 ||
  die "zone $zone has no NetworkPolicy infrared-fence: the fence is off (tenancy.networkPolicies.enabled), or the operator has not stamped it yet"
other_zone=""
if [ -n "$OTHER" ]; then
  other_zone="$(zone_of "$OTHER")"
  [ -n "$other_zone" ] || die "org $OTHER has no zone on $CTX"
fi

stamp="$(date -u +%Y%m%d-%H%M%S)"
probe_pods=()
cleanup() {
  local p
  for p in "${probe_pods[@]+"${probe_pods[@]}"}"; do
    k -n "${p%%/*}" delete pod "${p#*/}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
}
[ "${KEEP:-}" = 1 ] || trap cleanup EXIT

# probe <namespace> <name> <script>: runs script in a pod there, as a zone's
# app would run (Pod Security restricted), and prints its log; 0 when the
# script passed.
probe() {
  local ns=$1 name="fence-check-$2-$stamp" script=$3 phase=""
  probe_pods+=("$ns/$name")
  k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $name
  namespace: $ns
  labels:
    app.kubernetes.io/part-of: fence-check
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
      image: $IMAGE
      command: ["/bin/sh", "-c", $(jq -Rn --arg s "$script" '$s')]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
EOF
  local deadline=$((SECONDS + 300))
  while [ "$SECONDS" -lt "$deadline" ]; do
    phase="$(k -n "$ns" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "$phase" in Succeeded | Failed) break ;; esac
    sleep 3
  done
  k -n "$ns" logs "$name" 2>/dev/null || true
  [ "$phase" = Succeeded ]
}

# The probe's helpers: reach, refused, answered; it exits 1 at the end if any
# check failed.
# shellcheck disable=SC2016 # expanded in the probe's shell, not here
helpers='
rc=0
refused() {
  if nc -z -w 5 "$1" "$2" 2>/dev/null; then echo "  FAIL  $3 ($1:$2) accepted a connection"; rc=1
  else echo "  ok    $3 ($1:$2) refused"; fi
}
reaches() {
  if nc -z -w 5 "$1" "$2" 2>/dev/null; then echo "  ok    $3 ($1:$2) reached"
  else echo "  FAIL  $3 ($1:$2) refused"; rc=1; fi
}
'

# shellcheck disable=SC2016 # expanded in the probe's shell, not here
checks="$helpers"'
sleep 5
if nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1; then echo "  ok    DNS answers"; else echo "  FAIL  DNS does not answer"; rc=1; fi
code="$(curl -s -m 10 -o /dev/null -w "%{http_code}" https://www.google.com/ || true)"
if [ "$code" != 000 ]; then echo "  ok    the internet answers over HTTPS ($code)"; else echo "  FAIL  the internet does not answer"; rc=1; fi
refused seaweedfs-filer.stores.svc.cluster.local 8888 "SeaweedFS filer"
refused seaweedfs-master.stores.svc.cluster.local 9333 "SeaweedFS master"
refused seaweedfs-s3.stores.svc.cluster.local 8333 "SeaweedFS S3"
refused postgres-rw.stores.svc.cluster.local 5432 "Postgres"
refused vmsingle-victoria-metrics-k8s-stack.monitoring.svc.cluster.local 8428 "VictoriaMetrics"
refused victoria-metrics-k8s-stack-grafana.monitoring.svc.cluster.local 80 "Grafana"
refused infrared-api.'"$INFRARED_NS"'.svc.cluster.local 8080 "Infrared API"
refused infrared.'"$INFRARED_NS"'.svc.cluster.local 80 "Infrared UI"
refused gitea-http.'"$INFRARED_NS"'.svc.cluster.local 3000 "Gitea"
refused argocd-server.argocd.svc.cluster.local 80 "Argo CD server"
refused zot.registry.svc.cluster.local 5000 "registry"
refused edge.envoy-gateway-system.svc.cluster.local 443 "Envoy, inside the cluster"
refused kubernetes.default.svc.cluster.local 443 "the Kubernetes API"
refused 169.254.169.254 80 "cloud metadata"
'
fails=0
log "1-2. from org $ORG's zone $zone"
probe "$zone" platform "$checks; exit \$rc" || fails=$((fails + 1))

if [ -n "$other_zone" ]; then
  log "3. between org $ORG's zone $zone and org $OTHER's zone $other_zone, both ways"
  # A server in each zone, on 8080, for the other to try.
  for z in "$zone" "$other_zone"; do
    probe_pods+=("$z/fence-check-server-$stamp")
    k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: fence-check-server-$stamp
  namespace: $z
  labels:
    app.kubernetes.io/part-of: fence-check
    fence-check: server-$stamp
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
    - name: serve
      image: $IMAGE
      command: ["/bin/sh", "-c", "while true; do echo ok | nc -l -p 8080; done"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
EOF
  done
  k -n "$zone" wait --for=condition=Ready "pod/fence-check-server-$stamp" --timeout=180s >/dev/null
  k -n "$other_zone" wait --for=condition=Ready "pod/fence-check-server-$stamp" --timeout=180s >/dev/null
  ip_here="$(k -n "$zone" get pod "fence-check-server-$stamp" -o jsonpath='{.status.podIP}')"
  ip_there="$(k -n "$other_zone" get pod "fence-check-server-$stamp" -o jsonpath='{.status.podIP}')"
  probe "$zone" to-other "$helpers
sleep 5
reaches $ip_here 8080 \"its own zone's pod\"
refused $ip_there 8080 \"org $OTHER's zone's pod\"
exit \$rc" || fails=$((fails + 1))
  probe "$other_zone" to-this "$helpers
sleep 5
refused $ip_here 8080 \"org $ORG's zone's pod\"
exit \$rc" || fails=$((fails + 1))
fi

if [ "$fails" -ne 0 ]; then
  echo "fence-check: FAILED ($fails probe(s))" >&2
  exit 1
fi
echo "fence-check: the fence holds"
