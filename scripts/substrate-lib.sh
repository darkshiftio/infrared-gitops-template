#!/usr/bin/env bash
# =============================================================================
# Sourced by substrate-serve-check.sh and substrate-fence-check.sh.
# =============================================================================
# Both talk to Agent Substrate 1.0 on a cluster this template installed it on,
# from the one place inside the cluster its NetworkPolicies admit besides
# Infrared's operator: a pod in ate-system labelled
# infrared.darkshift.io/substrate-client (components/substrate/
# network-policies.yaml). A port-forward would not do: it enters the pod
# without crossing any NetworkPolicy, so it proves nothing.
#
# client_job <name> <script>: runs <script> (sh) in a Job of that name in
# ate-system, as the ServiceAccount substrate-check, which no access policy
# names and which is not the API's bootstrap owner, with:
#   ate <method>       one call to the API (gRPC, substrate.ateapi.v1.Control/
#                      <method>) as substrate-check, its token for the audience
#                      api.ate-system.svc; the request JSON on stdin, the answer
#                      on stdout; grpcurl exits 64 plus the gRPC code
#   ate_anon <method>  the same with no token
#   ate_list           the services the API lists by reflection (open to any
#                      caller it authenticates)
#   router <port> [curl args...]
#                      one HTTPS request to the router's Service on that port
#                      (443 or 8444), naming an actor that does not exist;
#                      prints curl's exit code and the HTTP status. The pod's
#                      own certificate from the pod-identity signer, whose
#                      SPIFFE ID is
#                      spiffe://cluster.local/ns/ate-system/sa/substrate-check,
#                      is $POD_CERT, to pass with --cert and --key
#   CA                 the service-DNS trust bundle, which every Substrate
#                      server's certificate chains to
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

# preflight: the context answers, and Substrate 1.0 runs there: its API's
# Deployment, and its WorkerPool CRD serving ate.dev/v1.
preflight() {
  command -v kubectl >/dev/null || die "missing tool: kubectl"
  command -v jq >/dev/null || die "missing tool: jq"
  k get --raw /readyz >/dev/null 2>&1 || die "context $CTX does not answer"
  k -n ate-system get deployment ate-api-server >/dev/null 2>&1 || die "no Substrate on $CTX (ate-system/ate-api-server)"
  case " $(k get crd workerpools.ate.dev -o jsonpath='{.spec.versions[*].name}' 2>/dev/null) " in
    *" v1 "*) ;;
    *) die "Substrate on $CTX is not 1.0: its WorkerPool CRD does not serve ate.dev/v1" ;;
  esac
}

# The ServiceAccount the client Jobs run as: no Kubernetes role, and nothing in
# Substrate.
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
            - name: CA
              value: /run/ate-ca/trust-bundle.pem
            - name: POD_CERT
              value: /run/pod-identity/credential-bundle.pem
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
            - name: pod-identity
              mountPath: /run/pod-identity
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
        # A client certificate the router does not admit: the pod-identity
        # signer's, for this pod's ServiceAccount.
        - name: pod-identity
          projected:
            sources:
              - podCertificate:
                  signerName: podidentity.podcert.ate.dev/identity
                  keyType: ECDSAP256
                  credentialBundlePath: credential-bundle.pem
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
# ate <method>: one call to Substrate's API as this pod's ServiceAccount, the
# request on stdin. The token is read at each call and never put on a command
# line.
ate() {
  ATE_TOKEN="$(cat /run/ate-token/token)" /tools/grpcurl -max-time 60 \
    -cacert "$CA" -H 'authorization: Bearer ${ATE_TOKEN}' -expand-headers \
    -d @ api.ate-system.svc:443 "substrate.ateapi.v1.Control/$1"
}
# ate_anon <method>: the same call, with no credential at all.
ate_anon() {
  /tools/grpcurl -max-time 60 -cacert "$CA" -d @ api.ate-system.svc:443 "substrate.ateapi.v1.Control/$1"
}
# ate_list: the services the API lists by reflection, as this pod.
ate_list() {
  ATE_TOKEN="$(cat /run/ate-token/token)" /tools/grpcurl -max-time 60 \
    -cacert "$CA" -H 'authorization: Bearer ${ATE_TOKEN}' -expand-headers \
    api.ate-system.svc:443 list
}
# router <port> [curl args...]: one HTTPS request to the router, naming an actor
# that does not exist; prints "<curl's exit code> <HTTP status>". 0 and a status
# mean the router let the client in; 35 or 56 with 000, that it refused it in
# the TLS handshake after presenting a certificate CA verifies; 6, 7 or 28,
# that nothing answered; 60, that its certificate did not verify.
router() {
  port=$1
  shift
  rc=0
  status="$(curl -sS -m 10 --cacert "$CA" "$@" -o /dev/null -w '%{http_code}' \
    -H 'ate-target-actor: substrate-check/none' "https://atenet-router.ate-system.svc:$port/" 2>/tmp/curl.err)" || rc=$?
  echo "$rc ${status:-000}"
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
  k -n ate-system delete serviceaccount substrate-check --ignore-not-found >/dev/null 2>&1 || true
}
