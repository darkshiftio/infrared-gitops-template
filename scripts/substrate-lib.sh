#!/usr/bin/env bash
# =============================================================================
# Sourced by substrate-counter-test.sh and substrate-fence-check.sh.
# =============================================================================
# Both talk to Agent Substrate on a cluster this template installed it on, from
# the one place inside the cluster its NetworkPolicies admit besides Infrared's
# operator: a pod in ate-system labelled infrared.darkshift.io/substrate-client
# (components/substrate/network-policies.yaml). A port-forward would not do: it
# enters the pod without crossing any NetworkPolicy, so it proves nothing.
#
# client_job <name> <script>: runs <script> (sh) in a Job of that name in
# ate-system, as the ServiceAccount substrate-check, with:
#   ate <method>     one call to the API (gRPC, ateapi.Control/<method>), the
#                    request JSON on stdin, the answer on stdout; grpcurl exits
#                    64 plus the gRPC code
#   ROUTER           the router's URL, http://atenet-router.ate-system.svc
#   AWS_*            the S3 identity ate-snapshots's keys and SeaweedFS's S3
#                    endpoint, for aws s3api
#   kubectl          as substrate-check: the caller grants what it needs
# then prints the Job's log and returns 0 when it succeeded. Every command names
# the context, never the current one.
# =============================================================================

# The same pins as the template's hooks (verify.sh checks they stay equal).
SUBSTRATE_K8S_IMAGE=docker.io/alpine/k8s:1.37.0@sha256:b421c2e9419edb98db39b6ab641669f4db7bb2acf354f22450c6b7e7176d1ff4
SUBSTRATE_GRPCURL_IMAGE=docker.io/fullstorydev/grpcurl:v1.9.3-alpine@sha256:4614424ed58e9b9837c48b6b8eadb9ef40491d5af3499bcc8b378e9c64a9e4a9

k() { kubectl --context "$CTX" "$@"; }
log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# preflight <ActorTemplate>: the context answers, Substrate runs there, and so
# does the test actor the check needs. Substrate's test actors (counter-v1 and
# sandbox-v1) are off by default: the install turns them on with the Infrared
# chart's value substrate.testActors (true), and the template then makes them in
# the substrate-actors Application.
preflight() {
  local template=$1
  command -v kubectl >/dev/null || die "missing tool: kubectl"
  command -v jq >/dev/null || die "missing tool: jq"
  k get --raw /readyz >/dev/null 2>&1 || die "context $CTX does not answer"
  k -n ate-system get deployment ate-api-server >/dev/null 2>&1 || die "no Substrate on $CTX (ate-system/ate-api-server)"
  k -n ate-system get configmap substrate-actor-templates -o jsonpath='{.data}' 2>/dev/null | jq -e --arg f "$template.json" 'has($f)' >/dev/null 2>&1 \
    || die "no ActorTemplate $template on $CTX. This check needs Substrate's test actors, which are off by default: set the Infrared chart's value substrate.testActors to true for this install, and run it again once the substrate-actors Application has synced"
}

# The ServiceAccount the client Jobs run as; the caller adds Roles to it.
client_account() {
  k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: substrate-check
  namespace: ate-system
  labels:
    app.kubernetes.io/part-of: substrate-check
EOF
}

client_job() {
  local name=$1 script=$2 rc=0
  k -n ate-system delete job "$name" --ignore-not-found --wait=true >/dev/null
  # The script reaches the pod as a ConfigMap, so it needs no quoting here.
  k -n ate-system create configmap "$name" --from-literal=check.sh="$(client_preamble)
$script" --dry-run=client -o yaml | k apply -f - >/dev/null
  k label -n ate-system configmap "$name" app.kubernetes.io/part-of=substrate-check --overwrite >/dev/null
  k apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $name
  namespace: ate-system
  labels:
    app.kubernetes.io/part-of: substrate-check
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 900
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app.kubernetes.io/part-of: substrate-check
        # Admitted to the API and the router by their NetworkPolicies.
        infrared.darkshift.io/substrate-client: "true"
    spec:
      serviceAccountName: substrate-check
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
            - name: ROUTER
              value: http://atenet-router.ate-system.svc
            - name: AWS_REGION
              value: us-east-1
            - name: AWS_ENDPOINT_URL
              value: http://seaweedfs-s3.stores.svc:8333
          envFrom:
            - secretRef:
                name: ate-s3-credentials
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: [ALL]
          volumeMounts:
            - name: tools
              mountPath: /tools
              readOnly: true
            - name: check
              mountPath: /check
              readOnly: true
            - name: ate-ca
              mountPath: /run/ate-ca
              readOnly: true
            - name: ate-token
              mountPath: /run/ate-token
              readOnly: true
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tools
          emptyDir: {}
        - name: check
          configMap:
            name: $name
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
        - name: tmp
          emptyDir: {}
EOF
  # Wait for the Job to finish either way, then show what it said.
  local deadline=$((SECONDS + 960)) phase=""
  while [ "$SECONDS" -lt "$deadline" ]; do
    phase="$(k -n ate-system get job "$name" -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type} {end}' 2>/dev/null || true)"
    case "$phase" in *Complete* | *SuccessCriteriaMet* | *Failed*) break ;; esac
    sleep 3
  done
  k -n ate-system logs "job/$name" -c check 2>/dev/null || k -n ate-system logs "job/$name" --all-containers 2>/dev/null || true
  case "$phase" in *Complete* | *SuccessCriteriaMet*) rc=0 ;; *) rc=1 ;; esac
  return "$rc"
}

# The sh functions every client script starts with.
client_preamble() {
  cat <<'EOF'
# ate <method>: one call to Substrate's API, the request on stdin. The token is
# read at each call and never put on a command line.
ate() {
  ATE_TOKEN="$(cat /run/ate-token/token)" /tools/grpcurl -max-time 120 \
    -cacert /run/ate-ca/trust-bundle.pem -H 'authorization: Bearer ${ATE_TOKEN}' -expand-headers \
    -d @ api.ate-system.svc:443 "ateapi.Control/$1"
}
# actor_ref <atespace> <name>: the ObjectRef JSON of an actor.
actor_ref() { printf '{"actor":{"atespace":"%s","name":"%s"}}' "$1" "$2"; }
# remove_actor <atespace> <name>: Substrate deletes only a suspended actor, so
# suspend it first (nothing happens when it sleeps already).
remove_actor() {
  actor_ref "$1" "$2" | ate SuspendActor >/dev/null 2>&1 || true
  actor_ref "$1" "$2" | ate DeleteActor >/dev/null 2>&1 || echo "warning: the actor $1/$2 was not deleted" >&2
}
EOF
}

# cleanup_client <job names...>: the Jobs, their ConfigMaps and the account.
cleanup_client() {
  local name
  for name in "$@"; do
    k -n ate-system delete job "$name" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    k -n ate-system delete configmap "$name" --ignore-not-found >/dev/null 2>&1 || true
  done
  k -n ate-workers delete rolebinding,role substrate-check --ignore-not-found >/dev/null 2>&1 || true
  k -n ate-system delete serviceaccount substrate-check --ignore-not-found >/dev/null 2>&1 || true
}
