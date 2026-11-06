#!/usr/bin/env bash
# =============================================================================
# edge-proof-check.sh <kube context> <Infrared's host>: the edge's proof holds
# on a running install (workspace TODO 473, F4; infrared-docs-internal ADR
# 0066 D2; README "The edge's proof").
# edge-proof-check.sh --kind <kind context>: the edge's own behaviour, on a
# throwaway kind cluster, with an echo server standing in for Infrared.
# =============================================================================
# On an install with the Infrared chart's api.clientAddressProof.enabled, it
# passes when:
#
#   1. read-only: the API and the operator name the same proof Secret, and the
#      API a client-address header; the Secret's key credential holds one
#      printable word with no newline (its length is printed, never its
#      value); the HTTPRouteFilter infrared-edge-proof stamps
#      X-Infrared-Edge-Proof from it over any copy; the infrared route's first
#      rule takes the API's paths alone through it, and the route is Accepted
#      with its references resolved; the ClientTrafficPolicy edge strips a
#      client's copy and is Accepted;
#   2. through the edge: https://<host>/api/v1/auth/methods answers 200, after
#      which the API says it is armed (infrared_api_edge_proof_armed 1, read
#      from one replica over a port-forward); the count of requests that named
#      an address without the proof (infrared_api_client_address_unproven_total)
#      is printed, to take again after ten minutes of normal use, when it
#      should not have moved;
#   3. with PROBE_SIGN_IN=1 alone, two refused password sign-ins of a made-up
#      address, each with a forged CF-Connecting-IP and a forged proof: one
#      through the edge, which the API counts by the address Cloudflare saw
#      and not as unproven, and one over a port-forward to the UI's Service,
#      which it counts as unproven, by the UI pod's address. Each counts
#      toward the sign-in limit of its address and shows on the root user's
#      record: run them once, at the owner's word.
#
# A Google sign-in through the edge, by a person, then logs client=<their
# address>: the script prints where to look.
#
# With --kind, on a kind cluster that runs Envoy Gateway v1.9.2, it renders
# this tree's filter, route and ClientTrafficPolicy with hack/render, puts
# them on a Gateway of its own in a namespace of its own, with an echo server
# as the Service infrared, and passes when, through Envoy (a port-forward):
#
#   a. a forged proof on /api/ and the two OpenID discovery paths arrives as
#      the Secret's value, once;
#   b. /, /mcp, /.well-known/oauth-protected-resource/, /ext/ and /apix arrive
#      with no proof, a forged one stripped;
#   c. a value changed in place arrives within 30 seconds;
#   d. with the Secret deleted, the API's paths answer 500 and / still answers
#      200; made again, they are stamped again within 30 seconds;
#   e. a filter made before its Secret answers 500, and is stamped once the
#      Secret exists;
#   f. a route that names a missing filter answers 500 on the API's paths.
#
# kind proves Envoy Gateway's behaviour, not a cloud's: neither the tunnel
# nor the fence (GKE Dataplane V2) runs there. What --kind makes is removed
# afterwards unless KEEP=1, and it refuses a context whose name does not
# start with kind-. Run it only on a kind cluster made for it.
#
# Needs: kubectl, jq, curl; with --kind also go and yq (mikefarah v4).
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

INFRARED_NS="${INFRARED_NS:-infrared}"
RELEASE="${INFRARED_RELEASE:-infrared}"
HEADER=X-Infrared-Edge-Proof
FILTER=infrared-edge-proof
# The echo server Envoy Gateway's v1.9.2 quickstart uses: it answers any path
# with the request as JSON, its headers among it.
ECHO_IMAGE=registry.k8s.io/gateway-api/echo-basic:v1.5.1@sha256:1930f87f9a037f8acadc37e79185bb217614d9674304e3c1f6074aec8ff6b8dc

usage() {
  echo "usage: scripts/edge-proof-check.sh <kube context> <Infrared's host>" >&2
  echo "       scripts/edge-proof-check.sh --kind <kind context>" >&2
  exit 2
}
log() { printf '\n== %s\n' "$*"; }
fails=0
ok() { echo "  ok    $*"; }
bad() {
  echo "  FAIL  $*"
  fails=$((fails + 1))
}
info() { echo "  info  $*"; }
die() {
  echo "edge-proof-check: $*" >&2
  exit 1
}
for tool in kubectl jq curl; do
  command -v "$tool" >/dev/null || die "missing tool: $tool"
done
[ $# -eq 2 ] || usage
stamp="$(date -u +%Y%m%d-%H%M%S)"

# Background port-forwards, stopped on exit.
pids=()
stop_forwards() {
  local p
  for p in "${pids[@]+"${pids[@]}"}"; do kill "$p" 2>/dev/null || true; done
}
# forward <context> <namespace> <target> <remote port>: a port-forward on a
# random local port, FWD_PORT, once it answers. Not in a subshell: its pid is
# kept for the cleanup.
FWD_PORT=""
forward() {
  local ctx=$1 ns=$2 target=$3 remote=$4
  FWD_PORT=$((20000 + RANDOM % 20000))
  kubectl --context "$ctx" -n "$ns" port-forward "$target" "$FWD_PORT:$remote" >/dev/null 2>&1 &
  pids+=("$!")
  for _ in $(seq 1 30); do
    curl -s -o /dev/null -m 2 "http://127.0.0.1:$FWD_PORT/" 2>/dev/null && return 0
    sleep 1
  done
  die "the port-forward to $ns/$target:$remote on $ctx does not answer"
}
# random_value: a test proof of 32 hexadecimal characters.
random_value() { head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# ---------------------------------------------------------------------------
# The live checks on an install.
# ---------------------------------------------------------------------------
live() {
  local CTX=$1 HOST=$2
  k() { kubectl --context "$CTX" "$@"; }
  env_of() {
    k -n "$INFRARED_NS" get deployment "$1" -o json 2>/dev/null |
      jq -r --arg n "$2" '[.spec.template.spec.containers[].env[]? | select(.name == $n) | .value // empty][0] // empty' || true
  }
  trap stop_forwards EXIT

  log "1. read-only, on $CTX"
  local secret header op_secret value_len value_bad
  secret="$(env_of "$RELEASE-api" INFRARED_EDGE_PROOF_SECRET)"
  [ -n "$secret" ] ||
    die "the API ($INFRARED_NS/$RELEASE-api on $CTX) has no INFRARED_EDGE_PROOF_SECRET: the chart's api.clientAddressProof.enabled is off"
  header="$(env_of "$RELEASE-api" INFRARED_CLIENT_ADDRESS_HEADER)"
  if [ -n "$header" ]; then ok "the API names the proof Secret $secret and the client-address header $header"; else
    bad "the API names the proof Secret $secret but no client-address header (api.clientAddressHeader)"
  fi
  op_secret="$(env_of "$RELEASE-operator" INFRARED_EDGE_PROOF_SECRET)"
  if [ "$op_secret" = "$secret" ]; then ok "the operator names the same Secret"; else
    bad "the operator names '$op_secret', the API $secret"
  fi
  # The value is never printed: its length, and the count of characters that
  # are not printable or are blank, a newline among them.
  value_len="$({ k -n "$INFRARED_NS" get secret "$secret" -o jsonpath='{.data.credential}' 2>/dev/null || true; } |
    { base64 -d 2>/dev/null || true; } | wc -c | tr -d ' ')"
  value_bad="$({ k -n "$INFRARED_NS" get secret "$secret" -o jsonpath='{.data.credential}' 2>/dev/null || true; } |
    { base64 -d 2>/dev/null || true; } | LC_ALL=C tr -d '!-~' | wc -c | tr -d ' ')"
  if [ "${value_len:-0}" -gt 0 ] && [ "$value_bad" = 0 ]; then
    ok "the Secret $INFRARED_NS/$secret holds a proof of $value_len characters, no newline (Infrared makes 43)"
  else
    bad "the Secret $INFRARED_NS/$secret's key credential is missing, empty or holds blanks or a newline ($value_len characters, $value_bad of them not printable): replace the value in place, never delete the Secret"
  fi
  local filter
  filter="$(k -n "$INFRARED_NS" get httproutefilter "$FILTER" -o json 2>/dev/null |
    jq -r '.spec.credentialInjection | .header + " " + (.overwrite | tostring) + " " + .credential.valueRef.name' 2>/dev/null || true)"
  if [ "$filter" = "$HEADER true $secret" ]; then ok "the HTTPRouteFilter $FILTER stamps $HEADER from $secret over any copy"; else
    bad "the HTTPRouteFilter $INFRARED_NS/$FILTER is '$filter', want '$HEADER true $secret'"
  fi
  local route rule conds
  route="$(k -n "$INFRARED_NS" get httproute infrared -o json 2>/dev/null || true)"
  rule="$(jq -r '.spec.rules[0] | ([.matches[].path | .type + ":" + .value] | join(",")) + " " + ([.filters[]? | .extensionRef.name // .type] | join(","))' <<<"${route:-null}" 2>/dev/null || true)"
  if [ "$rule" = "PathPrefix:/api,Exact:/.well-known/oauth-authorization-server/api/v1/oidc,Exact:/.well-known/openid-configuration/api/v1/oidc $FILTER" ]; then
    ok "the infrared route's first rule takes the API's paths alone through the filter"
  else
    bad "the infrared route's first rule is '$rule'"
  fi
  conds="$(jq -r '[.status.parents[]? | select(.parentRef.name == "edge") | .conditions[] | select(.type == "Accepted" or .type == "ResolvedRefs") | .type + "=" + .status] | sort | join(" ")' <<<"${route:-null}" 2>/dev/null || true)"
  if [ "$conds" = "Accepted=True ResolvedRefs=True" ]; then ok "the infrared route is Accepted, its references resolved"; else
    bad "the infrared route's conditions are '$conds': a missing Secret or key gives Accepted=False, a missing filter ResolvedRefs=False"
  fi
  local policy
  policy="$(k -n envoy-gateway-system get clienttrafficpolicy edge -o json 2>/dev/null |
    jq -r '(.spec.headers.earlyRequestHeaders.remove // [] | map(ascii_downcase) | index("x-infrared-edge-proof") != null | tostring) + " " + ([.status.ancestors[]?.conditions[]? | select(.type == "Accepted") | .status] | unique | join(","))' 2>/dev/null || true)"
  if [ "$policy" = "true True" ]; then ok "the ClientTrafficPolicy edge strips a client's $HEADER, and is Accepted"; else
    bad "the ClientTrafficPolicy envoy-gateway-system/edge is '$policy', want it to remove $HEADER and be Accepted"
  fi

  log "2. through the edge, https://$HOST"
  local code metrics_port replicas mport
  code="$(curl -s -m 15 -o /dev/null -w '%{http_code}' "https://$HOST/api/v1/auth/methods" || true)"
  if [ "$code" = 200 ]; then ok "GET https://$HOST/api/v1/auth/methods answers 200"; else
    bad "GET https://$HOST/api/v1/auth/methods answers $code: a missing Secret or key answers 500"
  fi
  replicas="$(k -n "$INFRARED_NS" get deployment "$RELEASE-api" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
  [ "${replicas:-1}" = 1 ] || info "the API runs $replicas replicas, each armed on its own: the port-forward reads one"
  metrics_port="$(k -n "$INFRARED_NS" get deployment "$RELEASE-api" -o json |
    jq -r '[.spec.template.spec.containers[].ports[]? | select(.name == "metrics") | .containerPort][0] // empty' || true)"
  [ -n "$metrics_port" ] || die "the API's Deployment has no port named metrics"
  forward "$CTX" "$INFRARED_NS" "deployment/$RELEASE-api" "$metrics_port"
  mport=$FWD_PORT
  metric() { { curl -s -m 5 "http://127.0.0.1:$mport/metrics" || true; } | awk -v m="$1" '$1 == m { print $2 }'; }
  local armed unproven
  armed="$(metric infrared_api_edge_proof_armed)"
  if [ "$armed" = 1 ]; then ok "the API is armed: a request through the edge carried the proof"; else
    bad "the API is not armed (infrared_api_edge_proof_armed '$armed'): no request through the edge has carried the proof"
  fi
  unproven="$(metric infrared_api_client_address_unproven_total)"
  info "infrared_api_client_address_unproven_total $unproven: take it again after ten minutes of use, when it should not have moved"

  if [ "${PROBE_SIGN_IN:-}" = 1 ]; then
    log "3. two refused sign-ins with a forged address and a forged proof"
    local body before after client uiport ui_ips
    body="{\"email\":\"edge-proof-check-$stamp@example.invalid\",\"password\":\"edge-proof-check-not-a-password\"}"
    refused_client() {
      { k -n "$INFRARED_NS" logs "deployment/$RELEASE-api" --since=2m 2>/dev/null || true; } |
        jq -rR 'fromjson? | select(.msg == "sign-in" and .outcome == "refused") | .client' | tail -1
    }
    before="$(metric infrared_api_client_address_unproven_total)"
    code="$(curl -s -m 15 -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
      -H 'CF-Connecting-IP: 192.0.2.10' -H "$HEADER: forged" --data "$body" "https://$HOST/api/v1/auth/login" || true)"
    sleep 3
    after="$(metric infrared_api_client_address_unproven_total)"
    client="$(refused_client)"
    if { [ "$code" = 401 ] || [ "$code" = 403 ]; } && [ "$after" = "$before" ] && [ -n "$client" ] && [ "$client" != 192.0.2.10 ]; then
      ok "through the edge: refused ($code), counted by $client, the address Cloudflare saw, not as unproven"
    else
      bad "through the edge: answered $code, unproven $before -> $after, the log's client '$client' (want 401 or 403, no change, not 192.0.2.10)"
    fi
    forward "$CTX" "$INFRARED_NS" "svc/$RELEASE" 80
    uiport=$FWD_PORT
    before="$after"
    code="$(curl -s -m 15 -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
      -H 'CF-Connecting-IP: 192.0.2.11' -H "$HEADER: forged" --data "$body" "http://127.0.0.1:$uiport/api/v1/auth/login" || true)"
    sleep 3
    after="$(metric infrared_api_client_address_unproven_total)"
    client="$(refused_client)"
    ui_ips="$(k -n "$INFRARED_NS" get pods -l app.kubernetes.io/component=ui -o jsonpath='{.items[*].status.podIP}' 2>/dev/null || true)"
    if { [ "$code" = 401 ] || [ "$code" = 403 ]; } && awk -v a="${after:-0}" -v b="${before:-0}" 'BEGIN { exit !(a > b) }' \
      && [ -n "$client" ] && grep -qw -- "$client" <<<"$ui_ips"; then
      ok "inside the cluster: refused ($code), counted as unproven, by the UI pod's address $client"
    else
      bad "inside the cluster: answered $code, unproven $before -> $after, the log's client '$client', the UI's pods '$ui_ips'"
    fi
  else
    info "the refused sign-ins of step 3 run with PROBE_SIGN_IN=1 alone"
  fi
  info "a person's Google sign-in through https://$HOST then logs their own address:"
  info "  kubectl --context $CTX -n $INFRARED_NS logs deployment/$RELEASE-api --since=10m | jq -R 'fromjson? | select(.msg == \"sign-in\") | [.method, .outcome, .client]'"
}

# ---------------------------------------------------------------------------
# The edge's own behaviour on a throwaway kind cluster.
# ---------------------------------------------------------------------------
kind_checks() {
  local CTX=$1
  case "$CTX" in kind-*) ;; *) die "--kind runs only on a kind cluster's context (kind-<name>), not $CTX" ;; esac
  for tool in go yq; do
    command -v "$tool" >/dev/null || die "missing tool: $tool"
  done
  k() { kubectl --context "$CTX" "$@"; }
  local crd
  for crd in httproutefilters.gateway.envoyproxy.io clienttrafficpolicies.gateway.envoyproxy.io gateways.gateway.networking.k8s.io; do
    k get crd "$crd" >/dev/null 2>&1 ||
      die "$CTX has no CRD $crd: install Envoy Gateway v1.9.2 first (helm --kube-context $CTX install eg oci://docker.io/envoyproxy/gateway-helm --version v1.9.2 -n envoy-gateway-system --create-namespace)"
  done
  k -n envoy-gateway-system rollout status deployment/envoy-gateway --timeout=120s >/dev/null ||
    die "Envoy Gateway is not ready on $CTX"
  local eg_image
  eg_image="$(k -n envoy-gateway-system get deployment envoy-gateway -o jsonpath='{.spec.template.spec.containers[0].image}')"
  case "$eg_image" in *:v1.9.2*) ;; *) info "Envoy Gateway runs $eg_image, not v1.9.2: the template pins v1.9.2" ;; esac

  # Not local: the EXIT trap's cleanup reads ns and made_class after this function has returned.
  ns="edge-proof-check-$stamp" class="" made_class="" host=infrared.edge-proof.test
  out="$(mktemp -d)"
  # The EXIT trap: best effort, and the checks' exit status is the script's (macOS's bash 3.2 can
  # leave a trap on a failed command despite "|| true" under set -e, and exit 1 after a pass).
  cleanup() {
    local rc=$?
    set +e
    stop_forwards
    rm -r -- "$out" 2>/dev/null
    if [ "${KEEP:-}" = 1 ]; then
      echo "KEEP=1: left the namespace $ns${made_class:+ and the GatewayClass $made_class} on $CTX"
      exit "$rc"
    fi
    k delete namespace "$ns" --ignore-not-found --wait=false >/dev/null 2>&1
    [ -z "$made_class" ] || k delete gatewayclass "$made_class" --ignore-not-found >/dev/null 2>&1
    exit "$rc"
  }
  trap cleanup EXIT

  # Envoy Gateway's GatewayClass, or one of the check's own.
  class="$(k get gatewayclass -o json | jq -r '[.items[] | select(.spec.controllerName == "gateway.envoyproxy.io/gatewayclass-controller") | .metadata.name][0] // empty')"
  if [ -z "$class" ]; then
    class="edge-proof-check-$stamp" made_class="$class"
    k apply -f - >/dev/null <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: $class
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
EOF
  fi
  k create namespace "$ns" >/dev/null
  k label namespace "$ns" app.kubernetes.io/part-of=edge-proof-check >/dev/null

  # This tree's objects, as hack/render renders them for the namespace, put
  # on the check's own Gateway: the filter and the infrared route from
  # components/edge/routes.yaml, the ClientTrafficPolicy from gateway.yaml.
  go run ./hack/render -template template -out "$out/render" -cluster kind -flavor k3s -build-registry "" -namespace "$ns" \
    -edge gateway -infrared-host "$host" -edge-proof-secret "$FILTER" >/dev/null
  yq "select(.kind == \"HTTPRouteFilter\" and .metadata.name == \"$FILTER\")" "$out/render/components/edge/routes.yaml" >"$out/filter.yaml"
  yq "select(.kind == \"HTTPRoute\" and .metadata.name == \"infrared\")
    | .spec.parentRefs = [{\"group\": \"gateway.networking.k8s.io\", \"kind\": \"Gateway\", \"name\": \"edge-proof-check\", \"namespace\": \"$ns\", \"sectionName\": \"http\"}]" \
    "$out/render/components/edge/routes.yaml" >"$out/route.yaml"
  yq "select(.kind == \"ClientTrafficPolicy\") | .metadata.namespace = \"$ns\" | .spec.targetRefs[0].name = \"edge-proof-check\"" \
    "$out/render/components/edge/gateway.yaml" >"$out/policy.yaml"
  for f in filter route policy; do [ -s "$out/$f.yaml" ] || die "hack/render rendered no $f"; done

  local value
  value="kind-$(random_value)"
  secret() { k -n "$ns" create secret generic "$FILTER" --from-literal=credential="$1" >/dev/null; }
  secret "$value"
  k apply -f - >/dev/null <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: edge-proof-check
  namespace: $ns
spec:
  gatewayClassName: $class
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      hostname: $host
      allowedRoutes:
        namespaces:
          from: Same
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: infrared
  namespace: $ns
spec:
  replicas: 1
  selector:
    matchLabels:
      app: infrared-echo
  template:
    metadata:
      labels:
        app: infrared-echo
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        # The image's user is the name nonroot, which the kubelet cannot check against
        # runAsNonRoot; 65532 is the same user by number.
        runAsUser: 65532
        runAsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: echo
          image: $ECHO_IMAGE
          ports:
            - containerPort: 3000
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: [ALL]
---
apiVersion: v1
kind: Service
metadata:
  name: infrared
  namespace: $ns
spec:
  selector:
    app: infrared-echo
  ports:
    - port: 80
      targetPort: 3000
EOF
  k apply -f "$out/policy.yaml" -f "$out/filter.yaml" -f "$out/route.yaml" >/dev/null
  k -n "$ns" rollout status deployment/infrared --timeout=180s >/dev/null || die "the echo server does not start"

  # Envoy for the check's Gateway, which Envoy Gateway makes in its own
  # namespace; kind gives its LoadBalancer Service no address, so a
  # port-forward reaches it.
  local svc=""
  for _ in $(seq 1 60); do
    svc="$(k -n envoy-gateway-system get svc -l "gateway.envoyproxy.io/owning-gateway-name=edge-proof-check,gateway.envoyproxy.io/owning-gateway-namespace=$ns" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    [ -n "$svc" ] && break
    sleep 2
  done
  [ -n "$svc" ] || die "Envoy Gateway made no Service for the check's Gateway"
  k -n envoy-gateway-system rollout status "deployment/$svc" --timeout=180s >/dev/null 2>&1 ||
    k -n envoy-gateway-system wait --for=condition=Available deployment -l "gateway.envoyproxy.io/owning-gateway-name=edge-proof-check" --timeout=180s >/dev/null
  forward "$CTX" envoy-gateway-system "svc/$svc" 80
  local port=$FWD_PORT

  # proof <path>: the proof the echo server received on path, its values
  # joined by commas, a forged one sent along; "500" when Envoy answers 500.
  proof() {
    local body code
    body="$(curl -s -m 5 -w '\n%{http_code}' -H "Host: $host" -H "$HEADER: forged" "http://127.0.0.1:$port$1" || true)"
    code="$(tail -n1 <<<"$body")"
    if [ "$code" != 200 ]; then
      echo "${code:-000}"
      return
    fi
    sed '$d' <<<"$body" | jq -r --arg h "$HEADER" '.headers[$h] // [] | join(",")' 2>/dev/null || echo "an answer that is not the echo server's"
  }
  # within <seconds> <path> <want>: proof answers want within the time.
  within() {
    local deadline=$((SECONDS + $1)) got=""
    while [ "$SECONDS" -lt "$deadline" ]; do
      got="$(proof "$2")"
      [ "$got" = "$3" ] && return 0
      sleep 2
    done
    echo "$got"
    return 1
  }
  api_paths="/api/v1/auth/methods /.well-known/oauth-authorization-server/api/v1/oidc /.well-known/openid-configuration/api/v1/oidc"
  other_paths="/ /mcp /.well-known/oauth-protected-resource/mcp/code /ext/demo/ui/entry.js /apix"

  log "a, b. the API's paths are stamped, the others are not"
  local p got
  # The first request waits for Envoy Gateway to translate everything.
  within 120 /api/v1/auth/methods "$value" >/dev/null || true
  for p in $api_paths; do
    got="$(proof "$p")"
    if [ "$got" = "$value" ]; then ok "$p: the Secret's value, once, over a forged one"; else bad "$p: '$got', want the Secret's value"; fi
  done
  for p in $other_paths; do
    got="$(proof "$p")"
    if [ -z "$got" ]; then ok "$p: no proof, a forged one stripped"; else bad "$p: '$got', want none"; fi
  done

  log "c. a value changed in place arrives within 30 seconds"
  local value2
  value2="kind-$(random_value)"
  k -n "$ns" patch secret "$FILTER" --type merge -p "{\"data\":{\"credential\":\"$(printf '%s' "$value2" | base64 | tr -d '\n')\"}}" >/dev/null
  if got="$(within 30 /api/v1/auth/methods "$value2")"; then ok "the new value arrives"; else bad "after 30 seconds: '$got'"; fi

  log "d. the Secret deleted: 500 on the API's paths, / still answers; made again, stamped again"
  k -n "$ns" delete secret "$FILTER" >/dev/null
  if got="$(within 30 /api/v1/auth/methods 500)"; then ok "/api/: 500"; else bad "/api/: '$got', want 500"; fi
  got="$(proof /)"
  if [ -z "$got" ]; then ok "/: answers, no proof"; else bad "/: '$got'"; fi
  got="$(k -n "$ns" get httproute infrared -o json | jq -r '[.status.parents[]?.conditions[]? | select(.type == "Accepted") | .status] | join(",")')"
  if [ "$got" = False ]; then ok "the route is not Accepted"; else info "the route's Accepted is '$got'"; fi
  secret "$value"
  if got="$(within 30 /api/v1/auth/methods "$value")"; then ok "made again: stamped again"; else bad "made again: '$got' after 30 seconds"; fi

  log "e. a filter made before its Secret answers 500, then is stamped once the Secret exists"
  k -n "$ns" delete -f "$out/filter.yaml" >/dev/null
  k -n "$ns" delete secret "$FILTER" >/dev/null
  k apply -f "$out/filter.yaml" >/dev/null
  if got="$(within 30 /api/v1/auth/methods 500)"; then ok "the filter without its Secret: 500"; else bad "the filter without its Secret: '$got'"; fi
  secret "$value"
  if got="$(within 30 /api/v1/auth/methods "$value")"; then ok "the Secret made: stamped"; else bad "the Secret made: '$got' after 30 seconds"; fi

  log "f. a route that names a missing filter answers 500 on the API's paths"
  k -n "$ns" delete -f "$out/filter.yaml" >/dev/null
  if got="$(within 30 /api/v1/auth/methods 500)"; then ok "no filter: 500, why it is pruned last"; else bad "no filter: '$got'"; fi
  got="$(proof /)"
  if [ -z "$got" ]; then ok "/: answers"; else bad "/: '$got'"; fi
}

case "$1" in
  --kind) kind_checks "$2" ;;
  -*) usage ;;
  *) live "$1" "$2" ;;
esac

if [ "$fails" -ne 0 ]; then
  echo "edge-proof-check: FAILED ($fails check(s))" >&2
  exit 1
fi
echo "edge-proof-check: the edge's proof holds"
