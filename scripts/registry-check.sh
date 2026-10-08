#!/usr/bin/env bash
# =============================================================================
# registry-check.sh <kube context> <organization> [source image]: the registry
# inside the cluster keeps each organization to its own path, and an image
# outlives the registry's pod.
# =============================================================================
# Runs against a cluster this template installed Zot on, never from CI:
#
#   1. as the organization's Zot user (the Secret builds/registry-push-<org>,
#      mounted into crane pods in builds, so its password never leaves the
#      cluster), a copy of the source image into <org>/registry-check is
#      accepted, and copies into platform/ and into another organization's
#      path are refused;
#   2. the copy answers by the same digest after every Zot pod is deleted and
#      replaced;
#   3. as Zot's admin user infrared, which the operator deletes an
#      organization's images with, the copy is deleted, and the source image,
#      which has the same digest and blobs, still answers with every blob. The
#      admin password goes from infrared/registry-identities to curl on stdin,
#      through a port-forward, and is never printed.
#
# The source image defaults to Substrate's counter demo in the registry, by the
# digest in scripts/substrate-images.json. Step 3 removes the copy; the crane
# pods are removed unless KEEP=1.
# Needs: kubectl, jq, curl. Writes to the namespaces builds and registry only.
# =============================================================================
set -euo pipefail
CTX="${1:?usage: scripts/registry-check.sh <kube context> <organization> [source image]}"
ORG="${2:?usage: scripts/registry-check.sh <kube context> <organization> [source image]}"
here="$(cd "$(dirname "$0")" && pwd)"
CRANE_IMAGE=gcr.io/go-containerregistry/crane:v0.22.1@sha256:1f968817b95790bed063f71175aa6b8ff879fa17064020415f3e18bb6e6a36e1
ACCEPT='application/vnd.oci.image.manifest.v1+json,application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.docker.distribution.manifest.list.v2+json'

k() { kubectl --context "$CTX" "$@"; }
log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

for t in kubectl jq curl; do command -v "$t" >/dev/null || die "missing tool: $t"; done
k get --raw /readyz >/dev/null 2>&1 || die "context $CTX does not answer"
REG="$(k -n registry get service zot -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}' 2>/dev/null)" ||
  die "no registry on $CTX (registry/zot)"
k -n builds get secret "registry-push-$ORG" >/dev/null 2>&1 || die "no builds/registry-push-$ORG on $CTX"
if [ -n "${3:-}" ]; then
  SRC="$3"
else
  ref="$(jq -r '.images.counter.ref' "$here/substrate-images.json")"
  SRC="$REG/platform/substrate/counter@${ref##*@}"
fi
case "$SRC" in *@sha256:*) ;; *) die "the source image must be named by digest: $SRC" ;; esac
digest="${SRC##*@}"
repo="${SRC#"$REG"/}"
repo="${repo%@*}"
copy="$ORG/registry-check"

pf=""
cleanup() {
  if [ -n "$pf" ]; then kill "$pf" 2>/dev/null || true; fi
  if [ "${KEEP:-}" != 1 ]; then
    k -n builds delete pod -l app.kubernetes.io/part-of=registry-check --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# crane <pod name> <args...>: runs crane once in builds as the organization's
# user, and prints "<exit code> <last line of its log>".
crane() {
  local name=$1 args
  shift
  args="$(printf '%s\n' "$@" | jq -R . | jq -sc .)"
  k -n builds delete pod "$name" --ignore-not-found --wait=true >/dev/null
  k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $name
  namespace: builds
  labels:
    app.kubernetes.io/part-of: registry-check
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: crane
      image: $CRANE_IMAGE
      args: $args
      env:
        - name: DOCKER_CONFIG
          value: /docker
      volumeMounts:
        - name: login
          mountPath: /docker
          readOnly: true
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: [ALL]
  volumes:
    - name: login
      secret:
        secretName: registry-push-$ORG
        items:
          - key: .dockerconfigjson
            path: config.json
EOF
  local phase=""
  for _ in $(seq 1 60); do
    phase="$(k -n builds get pod "$name" -o jsonpath='{.status.phase}')"
    case "$phase" in Succeeded | Failed) break ;; esac
    sleep 2
  done
  local code
  code="$(k -n builds get pod "$name" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}')"
  printf '%s %s\n' "${code:-none}" "$(k -n builds logs "$name" 2>&1 | tail -1)"
}

stamp="$(date -u +%Y%m%d-%H%M%S)"
fail=0

log "1. pushes as the organization's user $ORG, from $SRC"
r="$(crane "registry-check-own-$stamp" copy --insecure "$SRC" "$REG/$copy:check")"
echo "  into $copy: $r"
[ "${r%% *}" = 0 ] || fail=1
for path in platform "not-$ORG"; do
  r="$(crane "registry-check-$path-$stamp" copy --insecure "$SRC" "$REG/$path/registry-check:check")"
  echo "  into $path/registry-check: $r"
  [ "${r%% *}" != 0 ] || fail=1
done
[ "$fail" = 0 ] || die "step 1: want the copy into $copy accepted and the other two refused"
echo "  ok    $ORG writes under $ORG/ only"

log "2. the copy outlives the registry's pod"
before="$(crane "registry-check-before-$stamp" digest --insecure "$REG/$copy:check")"
echo "  digest before: $before"
old="$(k -n registry get pods -l app.kubernetes.io/name=zot -o jsonpath='{.items[*].metadata.name}')"
# shellcheck disable=SC2086 # one name per pod
k -n registry delete pod $old --wait=true >/dev/null
ready=""
for _ in $(seq 1 150); do
  ready="$(k -n registry get pods -l app.kubernetes.io/name=zot \
    -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' |
    awk '$2 == "True" {print $1}')"
  [ -n "$ready" ] && break
  sleep 2
done
[ -n "$ready" ] || die "step 2: no Zot pod is Ready five minutes after the delete"
after="$(crane "registry-check-after-$stamp" digest --insecure "$REG/$copy:check")"
echo "  digest after:  $after ($old replaced by $ready)"
[ "$before" = "0 $digest" ] && [ "$after" = "0 $digest" ] || die "step 2: want $digest before and after"
echo "  ok    the same digest before and after"

log "3. the admin user deletes $ORG's copy, and the source is untouched"
pfout="$(mktemp)"
k -n registry port-forward service/zot :"${REG##*:}" >"$pfout" 2>&1 &
pf=$!
port=""
for _ in $(seq 1 30); do
  port="$(awk '/^Forwarding from 127\.0\.0\.1:/ { split($3, a, ":"); print a[2]; exit }' "$pfout")"
  [ -n "$port" ] && break
  sleep 1
done
[ -n "$port" ] || die "step 3: the port-forward to registry/zot did not start"
zot="http://127.0.0.1:$port"
code() { curl -sS -o /dev/null -w '%{http_code}' -H "Accept: $ACCEPT" "$@"; }
admin_delete() {
  {
    printf 'user = "infrared:'
    k -n infrared get secret registry-identities -o jsonpath='{.data.infrared}' | base64 -d |
      sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n'
    printf '"\n'
  } | curl -sS -K - -o /dev/null -w '%{http_code}' -X DELETE "$1"
}
del="$(admin_delete "$zot/v2/$copy/manifests/$digest")"
gone="$(code -I "$zot/v2/$copy/manifests/$digest")"
kept="$(code -I "$zot/v2/$repo/manifests/$digest")"
echo "  delete $copy@$digest as infrared: HTTP $del; then $copy $gone, $repo $kept"
[ "$del" = 202 ] && [ "$gone" = 404 ] && [ "$kept" = 200 ] || die "step 3: want 202, then 404 and 200"
n=0 bad=0
for b in $(curl -sS -H "Accept: $ACCEPT" "$zot/v2/$repo/manifests/$digest" | jq -r '.config.digest, .layers[].digest'); do
  n=$((n + 1))
  [ "$(code -I "$zot/v2/$repo/blobs/$b")" = 200 ] || bad=$((bad + 1))
done
echo "  $repo: $((n - bad)) of $n blobs answer"
[ "$bad" = 0 ] || die "step 3: a blob of $repo went with $ORG's copy"
echo "  ok    $ORG's copy is gone, and $repo answers with every blob"

log "PASS: the registry keeps $ORG to $ORG/, an image outlives the registry's pod, and deleting $ORG's image leaves the rest, on $CTX"
