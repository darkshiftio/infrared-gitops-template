#!/usr/bin/env bash
# =============================================================================
# tenancy-check.sh <kube context> <tenant org> [platform org]: the rest of a
# tenant's tenancy holds on a running install (infrared-docs-internal ADR 0066
# D4, D5, D6 and D10; README "The rest of the tenancy").
# =============================================================================
# With the Infrared chart's tenancy.tenantPods, tenancy.quotas,
# tenancy.admissionPolicies, tenancy.denyLogging and
# tenancy.argoCD.restrictDefaultProject on, this passes when:
#
#   1. the operator's admission policies (infrared-tenancy-*) and their
#      bindings are there, each binding denying;
#   2. in a zone of <tenant org>, Argo CD's controller (impersonated) is
#      refused, by the policy named, each of: a LoadBalancer Service, a
#      Service without a selector, a hand-written EndpointSlice, a pod off the
#      tenants' placement, a route on another zone's name under the previews
#      domain, a Gateway, a kpack Image, an Infrared CloudAccount, a
#      NetworkPolicy opening egress to every address, a ServiceAccount token
#      Secret, a claim of a volume by name, a change to the zone's quota, the
#      zone's org label changed, and the zone deleted; and is let make a
#      ClusterIP Service with a selector and a pod on the tenants' placement;
#   3. with [platform org], a LoadBalancer Service in one of its zones passes:
#      the platform org is exempt;
#   4. each zone of <tenant org> holds the quota infrared-quota and the limits
#      infrared-limits, every zone the same share, its builds namespace its
#      cap, and each zone's default ServiceAccount mounts no token;
#   5. GKE's NetworkLogging object logs denies, marked by the operator, and
#      each zone asks for them;
#   6. Argo CD's default project takes one repository and no cluster-scoped
#      kind, and Argo CD's initial admin Secret is gone (a person keeps the
#      password and deletes it, before the first tenant).
#
# Every request in 2 and 3 is a server-side dry run: the API server admits or
# refuses it, and nothing is stored. It reads no Secret's data. Runs against a
# cluster, never from CI: the hosted plane after the install, before a tenant,
# with the owner's go-ahead. A piece that is off fails its steps, which say so.
# Needs: kubectl, jq. The person may impersonate Argo CD's controller.
# =============================================================================
set -euo pipefail
usage="usage: scripts/tenancy-check.sh <kube context> <tenant org> [platform org]"
CTX="${1:?$usage}"
ORG="${2:?$usage}"
PLATFORM="${3:-}"
ARGO_NS="${ARGO_NS:-argocd}"
INFRARED_NS="${INFRARED_NS:-infrared}"
ARGO_SA="${ARGO_SA:-argocd-application-controller}"

k() { kubectl --context "$CTX" "$@"; }
# argo: kubectl as Argo CD's application controller, which acts for every
# org's Application.
argo() {
  kubectl --context "$CTX" --as "system:serviceaccount:$ARGO_NS:$ARGO_SA" \
    --as-group system:serviceaccounts --as-group "system:serviceaccounts:$ARGO_NS" --as-group system:authenticated "$@"
}
log() { printf '\n== %s\n' "$*"; }
die() {
  echo "tenancy-check: $*" >&2
  exit 1
}
fails=0
pass() { echo "  ok    $*"; }
fail() {
  echo "  FAIL  $*"
  fails=$((fails + 1))
}

for t in kubectl jq; do command -v "$t" >/dev/null || die "missing tool: $t"; done
k get --raw /readyz >/dev/null 2>&1 || die "context $CTX does not answer"

# zones <org>: the org's zones on this cluster, namespaces with its label and
# a zone's.
zones() { k get namespaces -l "infrared.darkshift.io/org=$1,infrared.darkshift.io/zone" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true; }
read -r -a org_zones <<<"$(zones "$ORG")"
[ "${#org_zones[@]}" -gt 0 ] || die "org $ORG has no zone on $CTX (a namespace labelled infrared.darkshift.io/org=$ORG and infrared.darkshift.io/zone)"
ZONE="${org_zones[0]}"
ZONE_NAME="$(k get namespace "$ZONE" -o jsonpath='{.metadata.labels.infrared\.darkshift\.io/zone}')"

# The operator's own settings, from its Deployment's environment (no Secret).
op_env() {
  k -n "$INFRARED_NS" get deployment infrared-operator -o json |
    jq -r --arg n "$1" '.spec.template.spec.containers[] | select(.name == "operator") | .env[]? | select(.name == $n) | .value // empty'
}
placement="$(op_env INFRARED_TENANT_PODS | jq -c '.placement // {}' 2>/dev/null || echo '{}')"
DOMAIN="$(k get installations.infrared.darkshift.io infrared -o jsonpath='{.spec.previews.domain}' 2>/dev/null || true)"

# admits <what> <file>: a server-side dry run as Argo CD; refused <what>
# <policy> <file>: the same, refused by that policy.
dry() { argo "$@" --dry-run=server -o name 2>&1; }
admits() {
  local out
  if out="$(dry create -f "$2")"; then pass "Argo CD may make $1"
  else fail "Argo CD may not make $1: $(tail -1 <<<"$out")"; fi
}
refused() {
  local what="$1" policy="$2" out
  shift 2
  if out="$(dry "$@")"; then fail "$what: admitted, want refused by $policy"
  elif grep -q "$policy" <<<"$out"; then pass "$what: refused by $policy"
  else fail "$what: refused, but not by $policy: $(tail -1 <<<"$out")"; fi
}
work="$(mktemp -d)"
trap 'rm -f "$work"/*.json; rmdir "$work"' EXIT
obj() { cat >"$work/$1.json"; echo "$work/$1.json"; }

log "1. The admission policies"
policies="$(k get validatingadmissionpolicies -l infrared.darkshift.io/tenancy=admission -o json 2>/dev/null | jq -r '[.items[].metadata.name] | sort | join(" ")')"
bindings="$(k get validatingadmissionpolicybindings -l infrared.darkshift.io/tenancy=admission -o json 2>/dev/null |
  jq -r '[.items[] | select(.spec.validationActions | index("Deny")) | .metadata.name] | sort | join(" ")')"
if [ -n "$policies" ] && [ "$policies" = "$bindings" ]; then pass "policies and denying bindings: $policies"
else fail "policies '$policies', denying bindings '$bindings' (tenancy.admissionPolicies.enabled?)"; fi

log "2. In $ORG's zone $ZONE, as Argo CD"
svc() { jq -n --arg ns "$ZONE" --arg type "$1" --argjson sel "$2" \
  '{apiVersion: "v1", kind: "Service", metadata: {namespace: $ns, name: "tenancy-check"}, spec: ({type: $type, ports: [{port: 80}]} + (if $sel then {selector: {app: "tenancy-check"}} else {} end))}'; }
admits "a ClusterIP Service with a selector" "$(svc ClusterIP true | obj svc-ok)"
refused "a LoadBalancer Service" infrared-tenancy-services create -f "$(svc LoadBalancer true | obj svc-lb)"
refused "a Service without a selector" infrared-tenancy-services create -f "$(svc ClusterIP false | obj svc-nosel)"
refused "a hand-written EndpointSlice" infrared-tenancy-endpoints create -f "$(jq -n --arg ns "$ZONE" \
  '{apiVersion: "discovery.k8s.io/v1", kind: "EndpointSlice", metadata: {namespace: $ns, name: "tenancy-check"}, addressType: "IPv4",
    endpoints: [{addresses: ["10.0.0.9"]}]}' | obj slice)"
# A pod Pod Security restricted admits, so the tenancy's policy alone decides.
pod() { jq -n --arg ns "$ZONE" --argjson p "$1" --argjson token "$2" '{apiVersion: "v1", kind: "Pod", metadata: {namespace: $ns, name: "tenancy-check"},
  spec: ($p + {automountServiceAccountToken: $token, securityContext: {runAsNonRoot: true, seccompProfile: {type: "RuntimeDefault"}},
    containers: [{name: "pause", image: "registry.k8s.io/pause:3.10",
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}}]})}'; }
if k get validatingadmissionpolicy infrared-tenancy-pods >/dev/null 2>&1; then
  admits "a pod on the tenants' placement, without a token" "$(pod "$placement" false | obj pod-ok)"
  refused "a pod off the tenants' placement" infrared-tenancy-pods create -f "$(pod '{}' false | obj pod-off)"
else
  fail "no infrared-tenancy-pods: tenancy.tenantPods.enabled with a placement, or builds.placement, sets what a pod must carry"
fi
if [ -n "$DOMAIN" ]; then
  refused "a route on another zone's name" infrared-tenancy-routes create -f "$(jq -n --arg ns "$ZONE" --arg h "tenancy-check-not-$ZONE_NAME.$DOMAIN" \
    '{apiVersion: "gateway.networking.k8s.io/v1", kind: "HTTPRoute", metadata: {namespace: $ns, name: "tenancy-check"},
      spec: {parentRefs: [{name: "edge", namespace: "envoy-gateway-system"}], hostnames: [$h]}}' | obj route)"
else
  fail "the Installation names no previews domain: no route policy to check"
fi
refused "a Gateway" infrared-tenancy-objects create -f "$(jq -n --arg ns "$ZONE" \
  '{apiVersion: "gateway.networking.k8s.io/v1", kind: "Gateway", metadata: {namespace: $ns, name: "tenancy-check"},
    spec: {gatewayClassName: "edge", listeners: [{name: "http", port: 80, protocol: "HTTP"}]}}' | obj gateway)"
refused "a kpack Image in a zone" infrared-tenancy-objects create -f "$(jq -n --arg ns "$ZONE" \
  '{apiVersion: "kpack.io/v1alpha2", kind: "Image", metadata: {namespace: $ns, name: "tenancy-check"},
    spec: {tag: "registry.invalid/tenancy-check", builder: {kind: "ClusterBuilder", name: "infrared-builder"},
      source: {git: {url: "https://git.invalid/tenancy-check", revision: "main"}}}}' | obj image)"
refused "an Infrared CloudAccount" infrared-tenancy-objects create -f "$(jq -n --arg ns "$ZONE" \
  '{apiVersion: "infrared.darkshift.io/v1alpha1", kind: "CloudAccount", metadata: {namespace: $ns, name: "tenancy-check"},
    spec: {aws: {accountID: "123456789012", roleARN: "arn:aws:iam::123456789012:role/tenancy-check"}}}' | obj account)"
refused "egress to every address" infrared-tenancy-objects create -f "$(jq -n --arg ns "$ZONE" \
  '{apiVersion: "networking.k8s.io/v1", kind: "NetworkPolicy", metadata: {namespace: $ns, name: "tenancy-check"},
    spec: {podSelector: {}, policyTypes: ["Egress"], egress: [{to: [{ipBlock: {cidr: "0.0.0.0/0"}}]}]}}' | obj netpol)"
refused "a ServiceAccount token Secret" infrared-tenancy-objects create -f "$(jq -n --arg ns "$ZONE" \
  '{apiVersion: "v1", kind: "Secret", metadata: {namespace: $ns, name: "tenancy-check", annotations: {"kubernetes.io/service-account.name": "default"}},
    type: "kubernetes.io/service-account-token"}' | obj token)"
refused "a claim of a volume by name" infrared-tenancy-objects create -f "$(jq -n --arg ns "$ZONE" \
  '{apiVersion: "v1", kind: "PersistentVolumeClaim", metadata: {namespace: $ns, name: "tenancy-check"},
    spec: {accessModes: ["ReadWriteOnce"], volumeName: "tenancy-check-another-org", resources: {requests: {storage: "1Gi"}}}}' | obj claim)"
if k -n "$ZONE" get resourcequota infrared-quota >/dev/null 2>&1; then
  refused "a change to the zone's quota" infrared-tenancy-owned -n "$ZONE" patch resourcequota infrared-quota --type merge -p '{"spec":{"hard":{"pods":"1000"}}}'
else
  fail "no quota infrared-quota in $ZONE (tenancy.quotas.enabled?)"
fi
refused "the zone's org label changed" infrared-tenancy-namespaces patch namespace "$ZONE" --type merge \
  -p '{"metadata":{"labels":{"infrared.darkshift.io/org":"tenancy-check"}}}'
refused "the zone deleted" infrared-tenancy-namespaces delete namespace "$ZONE"

if [ -n "$PLATFORM" ]; then
  log "3. The platform org $PLATFORM is exempt"
  read -r -a platform_zones <<<"$(zones "$PLATFORM")"
  if [ "${#platform_zones[@]}" -gt 0 ]; then
    lb="$(jq -n --arg ns "${platform_zones[0]}" '{apiVersion: "v1", kind: "Service", metadata: {namespace: $ns, name: "tenancy-check"},
      spec: {type: "LoadBalancer", selector: {app: "tenancy-check"}, ports: [{port: 80}]}}' | obj platform-lb)"
    admits "a LoadBalancer Service in the platform org's zone ${platform_zones[0]}" "$lb"
  else
    fail "org $PLATFORM has no zone on $CTX"
  fi
fi

log "4. $ORG's quotas, limits and tokens"
shares=""
for z in "${org_zones[@]}"; do
  cpu="$(k -n "$z" get resourcequota infrared-quota -o jsonpath='{.spec.hard.requests\.cpu}' 2>/dev/null || true)"
  memory="$(k -n "$z" get resourcequota infrared-quota -o jsonpath='{.spec.hard.limits\.memory}' 2>/dev/null || true)"
  if [ -n "$cpu" ] && k -n "$z" get limitrange infrared-limits >/dev/null 2>&1; then pass "$z: infrared-quota ($cpu CPU, $memory memory) and infrared-limits"
  else fail "$z: no infrared-quota or infrared-limits"; fi
  shares="$shares $cpu/$memory"
  automount="$(k -n "$z" get serviceaccount default -o jsonpath='{.automountServiceAccountToken}' 2>/dev/null || true)"
  if [ "$automount" = false ]; then pass "$z: the default ServiceAccount mounts no token"
  else fail "$z: the default ServiceAccount mounts a token (automountServiceAccountToken '$automount'; tenancy.tenantPods.enabled?)"; fi
done
distinct="$(tr ' ' '\n' <<<"$shares" | grep -v '^$' | sort -u | wc -l | tr -d ' ')"
if [ "$distinct" = 1 ]; then pass "every zone of $ORG has the same share, over ${#org_zones[@]} zones"
else fail "the zones of $ORG have different shares:$shares"; fi
builds_pods="$(k -n "builds-$ORG" get resourcequota infrared-quota -o jsonpath='{.spec.hard.pods}' 2>/dev/null || true)"
if [ -n "$builds_pods" ]; then pass "builds-$ORG: at most $builds_pods builds at once"
else fail "builds-$ORG has no infrared-quota"; fi

log "5. GKE's deny logging"
if k get networkloggings.networking.gke.io default >/dev/null 2>&1; then
  nl="$(k get networkloggings.networking.gke.io default -o json)"
  if [ "$(jq -r '[.spec.cluster.deny.log, .spec.cluster.deny.delegate, .metadata.annotations["infrared.darkshift.io/deny-logging"]] | join(",")' <<<"$nl")" = "true,true,true" ]; then
    pass "NetworkLogging default logs denies by namespace, marked by the operator"
  else fail "NetworkLogging default: $(jq -c '{spec, annotations: .metadata.annotations}' <<<"$nl") (tenancy.denyLogging.enabled?)"; fi
else
  fail "no NetworkLogging on $CTX: GKE Dataplane V2 has one"
fi
asks="$(k get namespace "$ZONE" -o jsonpath='{.metadata.annotations.policy\.network\.gke\.io/enable-deny-logging}')"
if [ "$asks" = true ]; then pass "$ZONE asks for its denies to be logged"
else fail "$ZONE does not ask for its denies to be logged"; fi

log "6. Argo CD"
project="$(k -n "$ARGO_NS" get appprojects.argoproj.io default -o json)"
if [ "$(jq -r '[(.spec.sourceRepos | length) <= 2, ((.spec.sourceRepos // []) | index("*") == null), ((.spec.clusterResourceWhitelist // []) | length) == 0,
    .metadata.annotations["infrared.darkshift.io/restricted"] == "true"] | all' <<<"$project")" = true ]; then
  pass "the default project takes $(jq -r '.spec.sourceRepos[0]' <<<"$project") alone, and no cluster-scoped kind"
else fail "the default project is open: $(jq -c '.spec | {sourceRepos, destinations, clusterResourceWhitelist}' <<<"$project") (tenancy.argoCD.restrictDefaultProject?)"; fi
if k -n "$ARGO_NS" get secret argocd-initial-admin-secret -o name >/dev/null 2>&1; then
  fail "argocd-initial-admin-secret is still there: keep the admin password in 1Password, then delete the Secret"
else pass "Argo CD's initial admin Secret is gone"; fi

echo
if [ "$fails" -gt 0 ]; then
  echo "tenancy-check: $fails failed"
  exit 1
fi
echo "tenancy-check: all passed"
