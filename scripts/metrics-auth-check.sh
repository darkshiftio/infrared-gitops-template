#!/usr/bin/env bash
# =============================================================================
# metrics-auth-check.sh <kube context>: the metrics' door holds on a running
# install, at the stage the install is at (README "The metrics' door";
# infrared-docs-internal docs/home-defense.md, step 5, and ADR 0066 D11).
# =============================================================================
# The stage is the operator's INFRARED_METRICS_AUTH, the Infrared chart's
# observability.metricsAuth.stage: off (unset), door, clients or enforced,
# each holding the ones before. node-exporter's proxy is the operator's
# INFRARED_NODE_EXPORTER_AUTH, the chart's observability.nodeExporterAuth.
# This passes when, at that stage:
#
#   1. the objects are as the stage makes them: from door on, the VMAuth
#      victoria-metrics-k8s-stack operational and its Deployment ready, the
#      VMUsers grafana, infrared-api and infrared-operator operational, the
#      NetworkPolicy metrics-door, and Grafana's datasources at the door; from
#      clients on, Infrared's API and operator reading at the door with a
#      token file, and before it the store itself; at enforced, the six
#      policies that close the back doors, and before it none of them;
#      node-exporter behind kube-rbac-proxy on every node with its proxy on,
#      and alone without;
#   2. from a probe pod in a namespace of its own, which sends no credential:
#        - the door, vmauth-victoria-metrics-k8s-stack:8427, gives no answer
#          from door on, since metrics-door admits monitoring and Infrared's
#          namespace alone (the door itself answers 401: part 3); before
#          door, its name does not resolve;
#        - the stores, the vmagents, vmalert, Alertmanager, kube-state-metrics
#          and the VictoriaMetrics operator give no answer at enforced; before
#          it they answer 200, which the stage leaves open;
#        - node-exporter on each node's own address answers plain HTTP 400 and
#          HTTPS 401 with its proxy, and plain HTTP 200 without;
#   3. on GKE, through the Kubernetes API's proxy, with the rights of whoever
#      runs this (the API server strips their credential before the service
#      sees the request): the door 401 from door on; the store, vmalert and
#      Alertmanager 200 at every stage, through the konnectivity agents the
#      policies admit (scripts/observability-check.sh reads all three so).
#      Elsewhere the proxy reaches pods by paths the policies do not name, so
#      this part prints what it gets and judges nothing;
#   4. from the store's own figures, read through that proxy and kept to this
#      install's series by its vmagent's external label platform (the home's
#      store holds other installs' telemetry too): node-exporter up on every
#      node node-exporter's DaemonSet runs on (with its proxy, vmagent's
#      token gets through), and every vmauth replica up from door on. It also
#      prints the targets down and the door's requests and errors by user
#      over 15 minutes.
#
# Run it once a stage has settled: the stage's values commit Synced, the
# operator's hydration Synced, and the stack's Application Synced and Healthy.
# Runs against a cluster, never from CI. It makes a namespace,
# metrics-auth-check-<UTC stamp>, and a pod in it, so running it needs the
# owner's word for that cluster (on the hosted plane, at each stage of its
# door); both are deleted at the end unless KEEP=1. The pod runs as nobody
# under Pod Security restricted, with no token. The script keeps status codes
# and counts alone, never what a service answers, and reads no Secret.
# Needs: kubectl, jq, curl. Reads Infrared's two Deployments, the nodes'
# addresses, and in monitoring the VMAuth, the VMUsers, the NetworkPolicies,
# the Services, node-exporter's DaemonSet and Grafana's datasource ConfigMap.
# =============================================================================
set -euo pipefail
CTX="${1:?usage: scripts/metrics-auth-check.sh <kube context>}"
INFRARED_NS="${INFRARED_NS:-infrared}"
MON=monitoring
STACK=victoria-metrics-k8s-stack
DOOR="vmauth-$STACK"
DOOR_URL="http://$DOOR.$MON.svc:8427"
STORE="vmsingle-$STACK"
IMAGE=docker.io/alpine/k8s:1.37.0@sha256:b421c2e9419edb98db39b6ab641669f4db7bb2acf354f22450c6b7e7176d1ff4
BACK_DOORS="metrics-stores metrics-agents metrics-rules metrics-alerts metrics-exporters metrics-operator-webhook"

k() { kubectl --context "$CTX" "$@"; }
log() { printf '\n== %s\n' "$*"; }
die() {
  echo "metrics-auth-check: $*" >&2
  exit 1
}
fails=0
pass() { echo "  ok    $*"; }
fail() {
  echo "  FAIL  $*"
  fails=$((fails + 1))
}
note() { echo "  note  $*"; }

for t in kubectl jq curl; do command -v "$t" >/dev/null || die "missing tool: $t"; done
k get --raw /readyz >/dev/null 2>&1 || die "context $CTX does not answer"
k -n "$INFRARED_NS" get deployment infrared-operator >/dev/null 2>&1 ||
  die "no Deployment $INFRARED_NS/infrared-operator on $CTX (INFRARED_NS names Infrared's namespace)"
k -n "$MON" get vmsingles.operator.victoriametrics.com "$STACK" >/dev/null 2>&1 ||
  die "no VMSingle $MON/$STACK on $CTX: the template's metrics stack does not run here"

# env_of <deployment> <variable>: the variable's value in the first container
# of the Deployment in Infrared's namespace; empty when it is unset.
env_of() {
  { k -n "$INFRARED_NS" get deployment "$1" -o json 2>/dev/null || true; } |
    jq -r --arg v "$2" '[.spec.template.spec.containers[0].env[]? | select(.name == $v) | .value // ""][0] // ""'
}
STAGE="$(env_of infrared-operator INFRARED_METRICS_AUTH)"
STAGE="${STAGE:-off}"
case "$STAGE" in
  off | door | clients | enforced) ;;
  *) die "the operator's INFRARED_METRICS_AUTH is '$STAGE', not door, clients or enforced" ;;
esac
NODE_AUTH=off
if [ "$(env_of infrared-operator INFRARED_NODE_EXPORTER_AUTH)" = true ]; then NODE_AUTH=on; fi
# at <stage>: the install is at that stage or past it.
rank() {
  case "$1" in
    door) echo 1 ;;
    clients) echo 2 ;;
    enforced) echo 3 ;;
    *) echo 0 ;;
  esac
}
at() { [ "$(rank "$STAGE")" -ge "$(rank "$1")" ]; }
# On GKE the Kubernetes API's proxy reaches pods through kube-system's
# konnectivity agents, which the template's policies admit (its .Cloud gcp).
GKE=false
case "$(k get nodes -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null || true)" in gce://*) GKE=true ;; esac

stamp="$(date -u +%Y%m%d-%H%M%S)"
ns="metrics-auth-check-$stamp"
made=""
pf=""
cleanup() {
  if [ -n "$pf" ]; then kill "$pf" 2>/dev/null || true; fi
  [ -n "$made" ] || return 0
  if [ "${KEEP:-}" = 1 ]; then
    echo "kept: the namespace $ns (kubectl --context $CTX delete namespace $ns)"
    return 0
  fi
  k delete namespace "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "0. the stage"
echo "  stage $STAGE (the operator's INFRARED_METRICS_AUTH), node-exporter's proxy $NODE_AUTH" \
  "(INFRARED_NODE_EXPORTER_AUTH), GKE $GKE"

log "1. the objects, at the stage $STAGE"
state() { k -n "$MON" get "$1" "$2" -o jsonpath='{.status.updateStatus}' 2>/dev/null || true; }
has() { k -n "$MON" get "$1" "$2" >/dev/null 2>&1; }
if at door; then
  s="$(state vmauths.operator.victoriametrics.com "$STACK")"
  if [ "$s" = operational ]; then pass "the VMAuth $STACK is operational"; else fail "the VMAuth $STACK is '${s:-missing}', not operational"; fi
  ready="$(k -n "$MON" get deployment "$DOOR" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null || true)"
  if [ -n "${ready%/*}" ] && [ "${ready%/*}" != 0 ] && [ "${ready%/*}" = "${ready#*/}" ]; then
    pass "the door's Deployment $DOOR is ready ($ready)"
  else
    fail "the door's Deployment $DOOR is not ready (${ready:-missing})"
  fi
  for u in grafana infrared-api infrared-operator; do
    s="$(state vmusers.operator.victoriametrics.com "$u")"
    if [ "$s" = operational ]; then
      pass "the VMUser $u is operational"
    elif [ "$u" != grafana ] && ! at clients; then
      note "the VMUser $u is '${s:-missing}': the operator found no issuer (its log says why), so the stage clients would leave $u without the door"
    else
      fail "the VMUser $u is '${s:-missing}', not operational"
    fi
  done
  if has networkpolicy metrics-door; then pass "the NetworkPolicy metrics-door is there"; else fail "no NetworkPolicy metrics-door"; fi
  # Grafana's provisioned datasources: every url the door's.
  urls="$({ k -n "$MON" get configmap "$STACK-grafana-ds" -o jsonpath='{.data.datasource\.yaml}' 2>/dev/null || true; } |
    sed -n -E 's/^[[:space:]]*url:[[:space:]]*//p' | tr -d "\"'" | sort -u)"
  if [ -n "$urls" ] && ! grep -qvx "$DOOR_URL" <<<"$urls"; then
    pass "Grafana's datasources read at the door alone"
  else
    fail "Grafana's datasources read at: $(tr '\n' ' ' <<<"${urls:-nothing}")"
  fi
else
  if has vmauths.operator.victoriametrics.com "$STACK"; then fail "a VMAuth $STACK is there at the stage off"; else pass "no door yet: no VMAuth $STACK"; fi
  if has networkpolicy metrics-door; then fail "the NetworkPolicy metrics-door is there at the stage off"; else pass "no NetworkPolicy metrics-door"; fi
fi
for d in infrared-api infrared-operator; do
  url="$(env_of "$d" INFRARED_METRICS_URL)"
  token="$(env_of "$d" INFRARED_METRICS_TOKEN_FILE)"
  if at clients; then
    if [ "$url" = "$DOOR_URL" ] && [ -n "$token" ]; then
      pass "$d reads at the door with its token ($token)"
    else
      fail "$d reads at '${url:-nothing}' with the token file '${token:-none}', not at the door with its token"
    fi
  elif [ "$url" = "$DOOR_URL" ]; then
    fail "$d reads at the door before the stage clients"
  else
    pass "$d reads at ${url:-no store}, not the door, as before the stage clients"
  fi
done
present=""
for p in $BACK_DOORS; do if has networkpolicy "$p"; then present="$present $p"; fi; done
if at enforced; then
  missing=""
  for p in $BACK_DOORS; do case " $present " in *" $p "*) ;; *) missing="$missing $p" ;; esac done
  if [ -z "$missing" ]; then pass "the six policies that close the back doors are there"; else fail "the stage enforced lacks:$missing"; fi
elif [ -z "$present" ]; then
  pass "no policy closes the back doors yet, as before the stage enforced"
else
  fail "before the stage enforced, already there:$present"
fi
ds="$(k -n "$MON" get daemonset "$STACK-prometheus-node-exporter" -o json 2>/dev/null || true)"
if [ -z "$ds" ]; then
  fail "no DaemonSet $MON/$STACK-prometheus-node-exporter"
else
  proxy="$(jq -r '[.spec.template.spec.containers[].name] | index("kube-rbac-proxy") != null' <<<"$ds")"
  read -r nready nwant nnew < <(jq -r '"\(.status.numberReady // 0) \(.status.desiredNumberScheduled // 0) \(.status.updatedNumberScheduled // 0)"' <<<"$ds")
  if [ "$NODE_AUTH" = on ]; then
    if [ "$proxy" = true ] && [ "$nwant" -gt 0 ] && [ "$nready" = "$nwant" ] && [ "$nnew" = "$nwant" ]; then
      pass "kube-rbac-proxy beside node-exporter, ready on $nready of $nwant nodes"
    else
      fail "node-exporter's proxy: kube-rbac-proxy $proxy, $nready of $nwant ready, $nnew of $nwant updated"
    fi
  elif [ "$proxy" = false ]; then
    pass "node-exporter runs alone, as without its proxy"
  else
    fail "kube-rbac-proxy is beside node-exporter while INFRARED_NODE_EXPORTER_AUTH is off"
  fi
fi

log "2. without a credential, from a namespace of its own ($ns)"
# The stack's own components: each Service of theirs in monitoring, its port
# named http, and a path that serves data there: "<service> <port> <path>".
targets="$(k -n "$MON" get services -o json | jq -r '
  {"vmsingle": "/api/v1/query?query=vector(1)", "vmagent": "/api/v1/targets", "vmalert": "/api/v1/rules",
   "vmalertmanager": "/api/v2/silences", "kube-state-metrics": "/metrics", "victoria-metrics-operator": "/metrics"} as $path
  | .items[] | ($path[.metadata.labels["app.kubernetes.io/name"] // ""] // empty) as $p
  | ([.spec.ports[] | select(.name == "http") | .port][0] // .spec.ports[0].port) as $port
  | "\(.metadata.name) \($port) \($p)"')"
[ -n "$targets" ] || die "no Service of the stack's components in $MON"
nodes="$(k get nodes -o json | jq -r '.items[] | "\(.metadata.name) \([.status.addresses[] | select(.type == "InternalIP") | .address][0] // "")"')"
# The probe prints one line per request: R <name> <HTTP status> <curl's exit>.
# A control first: the Kubernetes API answers it, so its network works and a
# silence elsewhere is a refusal.
# shellcheck disable=SC2016 # expanded in the probe's shell, not here
script='
p() {
  n=$1
  shift
  c=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "$@")
  e=$?
  echo "R $n $c $e"
}
sleep 5
p control -k https://kubernetes.default.svc/readyz
'
script="${script}p door '$DOOR_URL/api/v1/query?query=vector(1)'"$'\n'
while read -r svc port path; do
  [ -n "$svc" ] || continue
  script="${script}p svc:$svc 'http://$svc.$MON.svc:$port$path'"$'\n'
done <<<"$targets"
while read -r node ip; do
  [ -n "$ip" ] || continue
  script="${script}p http:$node 'http://$ip:9100/metrics'"$'\n'
  script="${script}p https:$node -k 'https://$ip:9100/metrics'"$'\n'
done <<<"$nodes"
made=yes
k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $ns
  labels:
    app.kubernetes.io/part-of: metrics-auth-check
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
EOF
for _ in $(seq 1 30); do
  if k -n "$ns" get serviceaccount default >/dev/null 2>&1; then break; fi
  sleep 1
done
k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: probe
  namespace: $ns
  labels:
    app.kubernetes.io/part-of: metrics-auth-check
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
      resources:
        requests:
          cpu: 10m
          memory: 32Mi
        limits:
          memory: 64Mi
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
EOF
phase=""
deadline=$((SECONDS + 300))
while [ "$SECONDS" -lt "$deadline" ]; do
  phase="$(k -n "$ns" get pod probe -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  case "$phase" in Succeeded | Failed) break ;; esac
  sleep 3
done
case "$phase" in
  Succeeded) ;;
  *)
    why="$(k -n "$ns" get pod probe -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"
    die "the probe pod ended '${phase:-nowhere}'${why:+ ($why)} within 300s: no result of it counts"
    ;;
esac
out="$(k -n "$ns" logs probe 2>/dev/null || true)"
# got <name>: the probe's status and curl's exit for that request, in C and E.
got() {
  read -r C E < <(awk -v n="$1" '$1 == "R" && $2 == n {print $3, $4}' <<<"$out") || true
  C="${C:-none}"
  E="${E:-none}"
}
got control
case "$C" in
  000 | none) die "the probe reached nothing, not even the Kubernetes API (curl exit $E): no result of it counts" ;;
  *) pass "the probe reaches the cluster: the Kubernetes API answers it ($C)" ;;
esac
got door
if at door; then
  case "$C/$E" in
    000/6) fail "the door's name does not resolve: no Service $DOOR" ;;
    000/*) pass "the door gives no answer here: metrics-door admits $MON and $INFRARED_NS alone" ;;
    401/* | 403/*) fail "the door answered $C here: it refuses, but metrics-door let the request through" ;;
    *) fail "the door answered $C without a credential" ;;
  esac
elif [ "$E" = 6 ]; then
  pass "no door: its name does not resolve"
else
  fail "the door's name resolves at the stage off (it answered $C)"
fi
while read -r svc port path; do
  [ -n "$svc" ] || continue
  got "svc:$svc"
  if at enforced; then
    case "$C/$E" in
      000/6) fail "$svc does not resolve from the probe" ;;
      000/*) pass "$svc gives no answer" ;;
      *) fail "$svc answered $C without a credential at the stage enforced" ;;
    esac
  else
    case "$C" in
      200) pass "$svc answers without a credential (200): open until the stage enforced" ;;
      000) fail "$svc gives no answer before the stage enforced (curl exit $E): a policy closes it early, or the probe cannot reach $MON" ;;
      *) note "$svc answered $C without a credential: closed some way this stage does not" ;;
    esac
  fi
done <<<"$targets"
while read -r node ip; do
  [ -n "$ip" ] || continue
  got "http:$node"
  h="$C"
  got "https:$node"
  s="$C"
  if [ "$NODE_AUTH" = on ]; then
    case "$h/$s" in
      400/401 | 400/403) pass "node-exporter on $node refuses (plain HTTP $h, HTTPS $s)" ;;
      *) fail "node-exporter on $node answers plain HTTP $h and HTTPS $s, not 400 and 401" ;;
    esac
  elif [ "$h" = 200 ]; then
    pass "node-exporter on $node answers without a credential (plain HTTP 200): its proxy is off"
  else
    fail "node-exporter on $node answers plain HTTP $h and HTTPS $s, not 200 with its proxy off"
  fi
done <<<"$nodes"

log "3. through the Kubernetes API's proxy, with your own rights"
port=$((20000 + RANDOM % 20000))
k proxy --port="$port" >/dev/null 2>&1 &
pf=$!
for _ in $(seq 1 30); do
  if curl -s -o /dev/null "http://127.0.0.1:$port/readyz"; then break; fi
  sleep 1
done
curl -s -o /dev/null "http://127.0.0.1:$port/readyz" || die "kubectl proxy did not start on 127.0.0.1:$port"
# via <service:port> <path>: the status the service's answer comes back with.
via() { curl -s -m 30 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/api/v1/namespaces/$MON/services/$1/proxy$2" || true; }
door_c="$(via "$DOOR:8427" '/api/v1/query?query=vector(1)')"
store_c="$(via "$STORE:8428" '/api/v1/query?query=vector(1)')"
rules_c="$(via "vmalert-$STACK:8080" /api/v1/rules)"
am_c="$(via "vmalertmanager-$STACK:9093" /api/v2/status)"
if [ "$GKE" != true ]; then
  note "off GKE the API's proxy reaches pods by paths the policies do not name: the door $door_c, the store $store_c, vmalert $rules_c, Alertmanager $am_c; read them through a port-forward"
else
  if at door; then
    if [ "$door_c" = 401 ]; then pass "the door refuses a request without a credential (401)"; else fail "the door answered $door_c, not 401"; fi
  elif [ "$door_c" = 404 ]; then
    pass "no door Service (404)"
  else
    fail "the door answered $door_c at the stage off"
  fi
  if [ "$store_c" = 200 ]; then pass "the store answers the API's proxy (200)"; else fail "the store answered $store_c through the API's proxy, not 200"; fi
  if [ "$rules_c" = 200 ]; then pass "vmalert answers the API's proxy (200)"; else fail "vmalert answered $rules_c through the API's proxy, not 200"; fi
  if [ "$am_c" = 200 ]; then pass "Alertmanager answers the API's proxy (200)"; else fail "Alertmanager answered $am_c through the API's proxy, not 200"; fi
fi

log "4. the figures, from the store"
if [ "$store_c" != 200 ]; then
  note "the store does not answer the API's proxy here ($store_c): no figure read"
else
  # q <promql>: the instant query's results, one "<labels> <value>" line each.
  q() {
    { curl -s -m 30 -G "http://127.0.0.1:$port/api/v1/namespaces/$MON/services/$STORE:8428/proxy/api/v1/query" \
      --data-urlencode "query=$1" || true; } |
      jq -r '.data.result[]? | "\(.metric | del(.__name__) | to_entries | map("\(.key)=\(.value)") | join(",")) \(.value[1] | tonumber + 0.5 | floor)"' 2>/dev/null || true
  }
  one() { q "$1" | awk 'NR == 1 {print $NF}'; }
  # This install's own series carry its vmagent's external label platform; a
  # store that also takes other installs' telemetry (the home's) holds theirs.
  PLATFORM="$(k -n "$MON" get vmagents.operator.victoriametrics.com "$STACK" -o jsonpath='{.spec.externalLabels.platform}' 2>/dev/null || true)"
  # sel <matchers>: the label matchers, with this install's platform.
  sel() {
    local m=$1
    if [ -n "$PLATFORM" ]; then m="${m:+$m,}platform=\"$PLATFORM\""; fi
    printf '{%s}' "$m"
  }
  n="${nwant:-}"
  [ -n "$n" ] || n="$(k get nodes -o name | wc -l | tr -d ' ')"
  up="$(one "count(up$(sel 'job=~".*node-exporter.*"') == 1)")"
  if [ "${up:-0}" = "$n" ] && [ "$NODE_AUTH" = on ]; then
    pass "node-exporter is up on $n of $n nodes, read through its proxy with vmagent's token"
  elif [ "${up:-0}" = "$n" ]; then
    pass "node-exporter is up on $n of $n nodes"
  else
    fail "node-exporter is up on ${up:-0} of $n nodes"
  fi
  if at door; then
    want="$(k -n "$MON" get deployment "$DOOR" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
    up="$(one "count(up$(sel "job=\"$DOOR\"") == 1)")"
    if [ -n "$want" ] && [ "${up:-0}" = "$want" ]; then pass "every vmauth replica is up ($up of $want)"; else fail "vmauth is up on ${up:-0} of ${want:-?} replicas"; fi
    q "sum by (username) (increase(vmauth_user_requests_total$(sel '')[15m]))" | sed 's/^/  note  the door'\''s requests, 15m: /'
    q "sum by (username) (increase(vmauth_user_request_errors_total$(sel '')[15m]))" | sed 's/^/  note  the door'\''s errors by user, 15m: /'
    q "sum by (reason) (increase(vmauth_http_request_errors_total$(sel '')[15m]))" | sed 's/^/  note  the door'\''s refusals, 15m: /'
  fi
  note "targets down: $(one "count(up$(sel '') == 0)" | grep . || echo 0)"
fi

if [ "$fails" -ne 0 ]; then
  echo "metrics-auth-check: FAILED ($fails check(s)) at the stage $STAGE" >&2
  exit 1
fi
echo "metrics-auth-check: the metrics' door holds at the stage $STAGE"
