#!/usr/bin/env bash
# =============================================================================
# registry-build-check.sh <kube context>: one whole kpack build is pushed to the
# registry inside the cluster over plain HTTP, and a node runs it.
# =============================================================================
# Runs against a cluster this template installed Zot and the builds component
# on, never from CI. A kpack Image in kpack builds Paketo's go/mod sample at a
# pinned commit with the ClusterBuilder infrared-builder, as kpack's
# ServiceAccount infrared-builder (the user platform), and pushes the image and
# its build cache to the registry by its address, under platform/. A pod then
# runs the image by digest: the kubelet pulls it through the node's mirror for
# that address, without a login, and the sample answers through the API
# server's proxy.
#
# The Image, its Builds and the pod are removed unless KEEP=1. The images stay
# in the registry, under platform/registry-build-check, for its retention rules.
# Needs: kubectl, jq. Writes to the namespaces kpack and builds only.
# =============================================================================
set -euo pipefail
CTX="${1:?usage: scripts/registry-build-check.sh <kube context>}"
SAMPLES=https://github.com/paketo-buildpacks/samples
SAMPLES_COMMIT=e4119f05ecb65e694d1d7deb0d15dbb435e7cf15

k() { kubectl --context "$CTX" "$@"; }
log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

for t in kubectl jq; do command -v "$t" >/dev/null || die "missing tool: $t"; done
k get --raw /readyz >/dev/null 2>&1 || die "context $CTX does not answer"
REG="$(k -n registry get service zot -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}' 2>/dev/null)" ||
  die "no registry on $CTX (registry/zot)"
[ "$(k get clusterbuilder infrared-builder -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] ||
  die "the ClusterBuilder infrared-builder is not Ready on $CTX"

name="registry-build-check-$(date -u +%Y%m%d-%H%M%S)"
cleanup() {
  if [ "${KEEP:-}" != 1 ]; then
    k -n kpack delete image "$name" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    k -n builds delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

log "1. kpack builds $SAMPLES go/mod at ${SAMPLES_COMMIT:0:7} and pushes it to $REG/platform/registry-build-check"
k apply -f - >/dev/null <<EOF
apiVersion: kpack.io/v1alpha2
kind: Image
metadata:
  name: $name
  namespace: kpack
  labels:
    app.kubernetes.io/part-of: registry-build-check
spec:
  tag: $REG/platform/registry-build-check
  serviceAccountName: infrared-builder
  builder:
    kind: ClusterBuilder
    name: infrared-builder
  source:
    git:
      url: $SAMPLES
      revision: $SAMPLES_COMMIT
    subPath: go/mod
  cache:
    registry:
      tag: $REG/platform/registry-build-check-cache
  successBuildHistoryLimit: 1
  failedBuildHistoryLimit: 1
EOF
start="$(date +%s)"
ready=""
for _ in $(seq 1 180); do
  ready="$(k -n kpack get image "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
  [ "$ready" = True ] && break
  failed="$(k -n kpack get builds -l "image.kpack.io/image=$name" \
    -o jsonpath='{.items[*].status.conditions[?(@.type=="Succeeded")].status}' 2>/dev/null)"
  case " $failed " in *" False "*) die "step 1: the build failed: k -n kpack get builds -l image.kpack.io/image=$name" ;; esac
  sleep 5
done
[ "$ready" = True ] || die "step 1: the Image is not Ready after 15 minutes"
image="$(k -n kpack get image "$name" -o jsonpath='{.status.latestImage}')"
echo "  ok    built and pushed in $(($(date +%s) - start)) s: $image"
case "$image" in "$REG"/platform/registry-build-check@sha256:*) ;; *) die "step 1: unexpected image $image" ;; esac

log "2. a node runs it by digest"
k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $name
  namespace: builds
  labels:
    app.kubernetes.io/part-of: registry-build-check
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: $image
      imagePullPolicy: Always
      env:
        - name: PORT
          value: "8080"
      ports:
        - containerPort: 8080
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: [ALL]
EOF
k -n builds wait pod "$name" --for=condition=Ready --timeout=180s >/dev/null || die "step 2: the pod is not Ready"
node="$(k -n builds get pod "$name" -o jsonpath='{.spec.nodeName}')"
pulled="$(k -n builds get events --field-selector "involvedObject.name=$name,reason=Pulled" \
  -o jsonpath='{.items[-1:].message}')"
echo "  $node: $pulled"
answer="$(k get --raw "/api/v1/namespaces/builds/pods/$name:8080/proxy/" 2>&1)"
case "$answer" in *"Paketo Buildpacks"*) ;; *) die "step 2: the sample did not answer as expected" ;; esac
echo "  ok    the sample answers on $node"

log "PASS: kpack pushed a whole build to $REG over plain HTTP, and a node ran it, on $CTX"
