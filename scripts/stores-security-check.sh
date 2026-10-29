#!/usr/bin/env bash
# =============================================================================
# stores-security-check.sh <kube context>: SeaweedFS takes no caller it cannot
# identify, on a running install (infrared-docs-internal ADR 0066 D3; README
# "The stores' own security").
# =============================================================================
# With the stores' own security on (the Infrared chart's
# tenancy.storesSecurity.enabled), this runs a probe pod in the namespace
# stores, which every fence admits, and passes when:
#
#   1. the filer's HTTP refuses a read and a write without a token (401), and
#      answers its health;
#   2. the master's HTTP API is gone (no /dir/assign), and its status answers;
#   3. a volume server refuses a write without a token (401);
#   4. the filer's, the master's and a volume server's gRPC answer neither
#      plain HTTP/2 nor TLS without a client certificate (mutual TLS);
#   5. the S3 gateway still serves the bucket registry to its identity
#      (registry's keys, from stores/seaweedfs-s3-registry, read in the pod),
#      and the registry answers.
#
# Nothing is written to the stores: every write it tries is refused. The probe
# pod is removed unless KEEP=1. Runs against a cluster, never from CI: the
# hosted plane after the install, before a tenant, with the owner's go-ahead.
# Needs: kubectl, jq. Applies one pod in stores.
# =============================================================================
set -euo pipefail
CTX="${1:?usage: scripts/stores-security-check.sh <kube context>}"
IMAGE=docker.io/alpine/k8s:1.37.0@sha256:b421c2e9419edb98db39b6ab641669f4db7bb2acf354f22450c6b7e7176d1ff4
NS=stores

k() { kubectl --context "$CTX" "$@"; }
die() {
  echo "stores-security-check: $*" >&2
  exit 1
}
for t in kubectl jq; do command -v "$t" >/dev/null || die "missing tool: $t"; done
k get --raw /readyz >/dev/null 2>&1 || die "context $CTX does not answer"
k -n "$NS" get secret seaweedfs-jwt >/dev/null 2>&1 ||
  die "stores/seaweedfs-jwt does not exist: the stores' own security is off (tenancy.storesSecurity), or SeaweedFS has not synced"
volume="$(k -n "$NS" get pods -l app.kubernetes.io/name=seaweedfs,app.kubernetes.io/component=volume -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[ -n "$volume" ] || die "no SeaweedFS volume server in $NS"

name="stores-security-check-$(date -u +%Y%m%d-%H%M%S)"
cleanup() { k -n "$NS" delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
[ "${KEEP:-}" = 1 ] || trap cleanup EXIT

svc="$NS.svc.cluster.local"
# shellcheck disable=SC2016 # expanded in the probe's shell, not here
script='
rc=0
code() { curl -s -o /dev/null -w "%{http_code}" -m 10 "$@" || true; }
want() {
  if [ "$1" = "$2" ]; then echo "  ok    $3 ($1)"; else echo "  FAIL  $3: $1, want $2"; rc=1; fi
}
want "$(code "http://seaweedfs-filer.'"$svc"':8888/")" 401 "the filer refuses a read without a token"
want "$(code -X PUT --data probe "http://seaweedfs-filer.'"$svc"':8888/stores-security-check/probe")" 401 "the filer refuses a write without a token"
want "$(code "http://seaweedfs-filer.'"$svc"':8888/healthz")" 200 "the filer answers its health"
want "$(code "http://seaweedfs-master.'"$svc"':9333/dir/assign")" 404 "the master has no HTTP API"
want "$(code "http://seaweedfs-master.'"$svc"':9333/cluster/status")" 200 "the master answers its status"
want "$(code -X POST --data probe "http://'"$volume"'.seaweedfs-volume.'"$svc"':8080/1,01deadbeef")" 401 "a volume server refuses a write without a token"
for target in seaweedfs-filer.'"$svc"':18888 seaweedfs-master.'"$svc"':19333 '"$volume"'.seaweedfs-volume.'"$svc"':18080; do
  want "$(code --http2-prior-knowledge "http://$target/")" 000 "gRPC at $target answers no plain HTTP/2"
  want "$(code -k --http2 "https://$target/")" 000 "gRPC at $target answers no TLS without a client certificate"
done
want "$(code --aws-sigv4 aws:amz:us-east-1:s3 -u "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY" \
  "http://seaweedfs-s3.'"$svc"':8333/registry?list-type=2&max-keys=1")" 200 "the S3 gateway serves the bucket registry to its identity"
zot="$(code http://zot.registry.svc.cluster.local:5000/v2/)"
case "$zot" in 200 | 401) echo "  ok    the registry answers ($zot)" ;; *) echo "  FAIL  the registry answers $zot"; rc=1 ;; esac
exit $rc
'
k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $name
  namespace: $NS
  labels:
    app.kubernetes.io/part-of: stores-security-check
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
      env:
        - name: AWS_ACCESS_KEY_ID
          valueFrom:
            secretKeyRef:
              name: seaweedfs-s3-registry
              key: AWS_ACCESS_KEY_ID
        - name: AWS_SECRET_ACCESS_KEY
          valueFrom:
            secretKeyRef:
              name: seaweedfs-s3-registry
              key: AWS_SECRET_ACCESS_KEY
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
EOF
phase=""
deadline=$((SECONDS + 300))
while [ "$SECONDS" -lt "$deadline" ]; do
  phase="$(k -n "$NS" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  case "$phase" in Succeeded | Failed) break ;; esac
  sleep 3
done
k -n "$NS" logs "$name" 2>/dev/null || true
[ "$phase" = Succeeded ] || die "FAILED: SeaweedFS takes a caller it cannot identify, or a check could not run (pod $phase)"
echo "stores-security-check: SeaweedFS takes no caller it cannot identify"
